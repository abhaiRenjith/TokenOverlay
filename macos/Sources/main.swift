// Claude Token Overlay — floating, translucent macOS overlay that tracks Claude Code
// token usage across every local client (CLI, desktop app Code tab, IDE extensions).
// Data source: the JSONL transcripts all of them write under ~/.claude/projects.

import AppKit
import SwiftUI
import ServiceManagement
import ImageIO

// MARK: - Model

enum Source: String, CaseIterable {
    case cli = "CLI", app = "App", ide = "IDE", other = "Other"

    var color: Color {
        switch self {
        case .cli: return Color(red: 0.50, green: 0.47, blue: 0.87)
        case .app: return Color(red: 0.11, green: 0.62, blue: 0.46)
        case .ide: return Color(red: 0.85, green: 0.35, blue: 0.19)
        case .other: return Color(white: 0.55)
        }
    }

    /// Maps the transcript's `entrypoint` field to a client bucket.
    static func from(_ entrypoint: String?) -> Source {
        guard let e = entrypoint?.lowercased(), !e.isEmpty else { return .cli } // old CLI builds omit it
        if e == "cli" { return .cli }
        if e.contains("desktop") { return .app }
        for ide in ["vscode", "jetbrains", "intellij", "cursor", "windsurf", "zed", "ide"] where e.contains(ide) {
            return .ide
        }
        return .other // sdk-*, headless, unknown
    }
}

enum Period: String, CaseIterable {
    case today, fiveHours, week
    var label: String {
        switch self {
        case .today: return "today"
        case .fiveHours: return "last 5h"
        case .week: return "7 days"
        }
    }
    func start(now: Date) -> Date {
        switch self {
        case .today: return Calendar.current.startOfDay(for: now)
        case .fiveHours: return now.addingTimeInterval(-5 * 3600)
        case .week: return now.addingTimeInterval(-7 * 86400)
        }
    }
}

struct Rec {
    let date: Date
    let source: Source
    let input, output, cacheWrite, cacheRead: Int
    var total: Int { input + output + cacheWrite + cacheRead }
}

struct Stats {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var bySource: [Source: Int] = [:]
    var total: Int { input + output + cacheWrite + cacheRead }
}

// MARK: - Scanner (incremental JSONL tail reader)

final class Scanner {
    private var offsets: [String: UInt64] = [:]
    private var partial: [String: Data] = [:]
    private var recs: [String: Rec] = [:]           // key: messageId:requestId (dedupes streaming + resumed sessions)
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let iso = ISO8601DateFormatter()
    private let usageNeedle = Data("\"usage\"".utf8)
    private let keepWindow: TimeInterval = 8 * 86400

    private func roots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".claude/projects"),
                    home.appendingPathComponent(".config/claude/projects")]
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            for p in env.split(separator: ",") {
                dirs.append(URL(fileURLWithPath: String(p)).appendingPathComponent("projects"))
            }
        }
        var seen = Set<String>()
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted }
    }

    func scan() -> [Period: Stats] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-keepWindow)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]

        for root in roots() {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let path = url.path
                let size = UInt64(v.fileSize ?? 0)
                var off = offsets[path] ?? 0
                if offsets[path] == nil, let m = v.contentModificationDate, m < cutoff {
                    offsets[path] = size; continue                 // untouched for 8+ days: skip
                }
                if size < off { off = 0; partial[path] = nil }     // file rewritten
                if size == off { continue }
                guard let fh = FileHandle(forReadingAtPath: path) else { continue }
                try? fh.seek(toOffset: off)
                let chunk = fh.readDataToEndOfFile()
                try? fh.close()
                offsets[path] = off + UInt64(chunk.count)

                let buf = (partial[path] ?? Data()) + chunk
                guard let nl = buf.lastIndex(of: 0x0A) else { partial[path] = buf; continue }
                partial[path] = Data(buf[buf.index(after: nl)...])
                for line in buf[..<nl].split(separator: 0x0A) where line.range(of: usageNeedle) != nil {
                    ingest(Data(line), cutoff: cutoff)
                }
            }
        }
        recs = recs.filter { $0.value.date >= cutoff }
        return aggregate(now: now)
    }

    private func ingest(_ line: Data, cutoff: Date) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let msg = o["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              (msg["model"] as? String) != "<synthetic>",
              let ts = o["timestamp"] as? String,
              let date = isoFrac.date(from: ts) ?? iso.date(from: ts),
              date >= cutoff else { return }
        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        let key = "\(msg["id"] as? String ?? UUID().uuidString):\(o["requestId"] as? String ?? "")"
        recs[key] = Rec(date: date, source: Source.from(o["entrypoint"] as? String),
                        input: n("input_tokens"), output: n("output_tokens"),
                        cacheWrite: n("cache_creation_input_tokens"), cacheRead: n("cache_read_input_tokens"))
    }

    private func aggregate(now: Date) -> [Period: Stats] {
        var out: [Period: Stats] = [:]
        for p in Period.allCases {
            let start = p.start(now: now)
            var s = Stats()
            for r in recs.values where r.date >= start {
                s.input += r.input; s.output += r.output
                s.cacheWrite += r.cacheWrite; s.cacheRead += r.cacheRead
                s.bySource[r.source, default: 0] += r.total
            }
            out[p] = s
        }
        return out
    }
}

final class Store: ObservableObject {
    @Published var stats: [Period: Stats] = [:]
    @Published var updated: Date?
    private let scanner = Scanner()
    private let queue = DispatchQueue(label: "token-overlay.scan", qos: .utility)
    private var busy = false

    func refresh() {
        guard !busy else { return }
        busy = true
        queue.async {
            let s = self.scanner.scan()
            DispatchQueue.main.async { self.stats = s; self.updated = Date(); self.busy = false }
        }
    }
}

// MARK: - Settings

final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    var persist = true   // false for screenshot rendering, so demo values never touch real prefs
    @Published var period: Period { didSet { if persist { d.set(period.rawValue, forKey: "period") } } }
    @Published var compact: Bool { didSet { if persist { d.set(compact, forKey: "compact") } } }
    @Published var idleOpacity: Double { didSet { d.set(idleOpacity, forKey: "idleOpacity") } }
    @Published var hoverOpacity: Double { didSet { d.set(hoverOpacity, forKey: "hoverOpacity") } }
    @Published var clickThrough: Bool { didSet { d.set(clickThrough, forKey: "clickThrough") } }
    @Published var visible: Bool { didSet { d.set(visible, forKey: "visible") } }
    @Published var menuBarCount: Bool { didSet { d.set(menuBarCount, forKey: "menuBarCount") } }

    init() {
        d.register(defaults: ["period": Period.today.rawValue, "compact": false, "idleOpacity": 0.85,
                              "hoverOpacity": 0.30, "clickThrough": false, "visible": true, "menuBarCount": true])
        period = Period(rawValue: d.string(forKey: "period") ?? "") ?? .today
        compact = d.bool(forKey: "compact")
        idleOpacity = d.double(forKey: "idleOpacity")
        hoverOpacity = d.double(forKey: "hoverOpacity")
        clickThrough = d.bool(forKey: "clickThrough")
        visible = d.bool(forKey: "visible")
        menuBarCount = d.bool(forKey: "menuBarCount")
    }
}

func fmt(_ n: Int) -> String {
    let x = Double(n)
    if x >= 1e9 { return String(format: "%.2fB", x / 1e9) }
    if x >= 1e8 { return String(format: "%.0fM", x / 1e6) }
    if x >= 1e6 { return String(format: "%.2fM", x / 1e6) }
    if x >= 1e5 { return String(format: "%.0fK", x / 1e3) }
    if x >= 1e3 { return String(format: "%.1fK", x / 1e3) }
    return "\(n)"
}

// MARK: - Overlay view

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct SourceBar: View {
    let stats: Stats
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(Source.allCases, id: \.self) { src in
                    let v = stats.bySource[src] ?? 0
                    if v > 0 {
                        Rectangle().fill(src.color)
                            .frame(width: g.size.width * CGFloat(v) / CGFloat(max(stats.total, 1)))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
        .background(Color.white.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct OverlayView: View {
    @ObservedObject var store: Store
    @ObservedObject var settings: Settings
    var solid = false   // flat background instead of live blur (used for rendered screenshots)

    var body: some View {
        let s = store.stats[settings.period] ?? Stats()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claude tokens · \(settings.period.label)")
                Spacer()
                Image(systemName: "line.3.horizontal").opacity(0.5)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)

            Text(store.updated == nil ? "…" : fmt(s.total))
                .font(.system(size: settings.compact ? 20 : 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .help("Click to switch period")
                .onTapGesture { cycle() }

            SourceBar(stats: s)

            if !settings.compact {
                HStack(spacing: 8) {
                    ForEach(Source.allCases, id: \.self) { src in
                        let v = s.bySource[src] ?? 0
                        if v > 0 || src != .other {
                            HStack(spacing: 4) {
                                Circle().fill(src.color).frame(width: 7, height: 7)
                                Text("\(src.rawValue) \(fmt(v))").lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)

                Divider().padding(.vertical, 2)

                ForEach(Period.allCases.filter { $0 != settings.period }, id: \.self) { p in
                    row(p.label.prefix(1).uppercased() + p.label.dropFirst(), fmt(store.stats[p]?.total ?? 0), strong: true)
                }
                row("In / out", "\(fmt(s.input)) / \(fmt(s.output))")
                row("Cache write / read", "\(fmt(s.cacheWrite)) / \(fmt(s.cacheRead))")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 240, alignment: .leading)
        .background { if solid { Color(red: 0.12, green: 0.12, blue: 0.13) } else { VisualEffect() } }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ k: String, _ v: String, strong: Bool = false) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).monospacedDigit().foregroundStyle(strong ? .primary : .secondary)
        }
        .font(.system(size: 12))
    }

    private func cycle() {
        let all = Period.allCases
        settings.period = all[(all.firstIndex(of: settings.period)! + 1) % all.count]
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    let settings = Settings()
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var timers: [Timer] = []
    var hovering = false

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        buildStatusItem()
        store.refresh()
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.store.refresh() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() })
        timers.forEach { RunLoop.main.add($0, forMode: .common) }
    }

    private func buildPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        let host = NSHostingController(rootView: OverlayView(store: store, settings: settings))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        // Saved frame missing, or on a display that is no longer connected
        if !panel.setFrameUsingName("TokenOverlay") || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            resetPosition()
        }
        panel.setFrameAutosaveName("TokenOverlay")
        panel.alphaValue = settings.idleOpacity
        applyClickThrough()
        if settings.visible { panel.orderFrontRegardless() }
    }

    private func resetPosition() {
        guard let f = NSScreen.main?.visibleFrame else { return }
        panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - 260, y: f.maxY - 20))
    }

    /// Fade on hover. Polls the cursor so it also works in click-through mode.
    private func tick() {
        guard settings.visible else { return }
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        let target = inside ? settings.hoverOpacity : settings.idleOpacity
        if abs(panel.alphaValue - target) > 0.005 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = target }
        }
        updateStatusTitle()
    }

    private func applyClickThrough() { panel.ignoresMouseEvents = settings.clickThrough }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Claude tokens")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        let t = settings.menuBarCount && store.updated != nil ? " " + fmt(store.stats[settings.period]?.total ?? 0) : ""
        if statusItem.button?.title != t { statusItem.button?.title = t }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(toggle(settings.visible ? "Hide overlay" : "Show overlay", #selector(toggleVisible), on: false))
        menu.addItem(.separator())

        let periodHeader = NSMenuItem(title: "Headline period", action: nil, keyEquivalent: ""); periodHeader.isEnabled = false
        menu.addItem(periodHeader)
        for p in Period.allCases {
            let i = toggle("  " + p.label.prefix(1).uppercased() + p.label.dropFirst(), #selector(pickPeriod(_:)), on: settings.period == p)
            i.representedObject = p.rawValue
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(sliderItem("Opacity", value: settings.idleOpacity, min: 0.15) { [weak self] v in self?.settings.idleOpacity = v })
        menu.addItem(sliderItem("Opacity on hover", value: settings.hoverOpacity, min: 0.05) { [weak self] v in self?.settings.hoverOpacity = v })
        menu.addItem(toggle("Click-through (ignore mouse)", #selector(toggleClickThrough), on: settings.clickThrough))
        menu.addItem(toggle("Compact", #selector(toggleCompact), on: settings.compact))
        menu.addItem(toggle("Show count in menu bar", #selector(toggleMenuBarCount), on: settings.menuBarCount))
        menu.addItem(toggle("Launch with Claude", #selector(toggleClaude), on: ClaudeHook.installed))
        menu.addItem(toggle("Launch at login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(toggle("Reset position", #selector(resetPos), on: false))
        menu.addItem(.separator())
        if let u = store.updated {
            let i = NSMenuItem(title: "Updated \(DateFormatter.localizedString(from: u, dateStyle: .none, timeStyle: .medium))", action: nil, keyEquivalent: "")
            i.isEnabled = false; menu.addItem(i)
        }
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func toggle(_ title: String, _ sel: Selector, on: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self; i.state = on ? .on : .off
        return i
    }

    private var sliderHandlers: [ObjectIdentifier: (Double) -> Void] = [:]

    private func sliderItem(_ title: String, value: Double, min: Double, onChange: @escaping (Double) -> Void) -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        let label = NSTextField(labelWithString: "\(title)  \(Int(value * 100))%")
        label.font = .menuFont(ofSize: 12); label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 24, width: 210, height: 16)
        let slider = NSSlider(value: value, minValue: min, maxValue: 1, target: self, action: #selector(sliderMoved(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 18, y: 4, width: 206, height: 20)
        view.addSubview(label); view.addSubview(slider)
        sliderHandlers[ObjectIdentifier(slider)] = { v in label.stringValue = "\(title)  \(Int((v * 100).rounded()))%"; onChange(v) }
        let item = NSMenuItem(); item.view = view
        return item
    }

    @objc private func sliderMoved(_ s: NSSlider) {
        sliderHandlers[ObjectIdentifier(s)]?(s.doubleValue)
        panel.alphaValue = settings.idleOpacity   // live preview while menu is open
    }

    @objc private func toggleVisible() {
        settings.visible.toggle()
        if settings.visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
    @objc private func pickPeriod(_ i: NSMenuItem) {
        if let r = i.representedObject as? String, let p = Period(rawValue: r) { settings.period = p }
    }
    @objc private func toggleClickThrough() { settings.clickThrough.toggle(); applyClickThrough() }
    @objc private func toggleCompact() { settings.compact.toggle() }
    @objc private func toggleMenuBarCount() { settings.menuBarCount.toggle(); updateStatusTitle() }
    @objc private func resetPos() { resetPosition() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't change launch at login"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }
    @objc private func toggleClaude() {
        do { try ClaudeHook.set(!ClaudeHook.installed) } catch {
            let a = NSAlert(); a.messageText = "Couldn't change launch with Claude"
            a.informativeText = "\(ClaudeHook.settingsURL.path): \(error.localizedDescription)"; a.runModal()
        }
    }
}

// MARK: - Launch with Claude
// A SessionStart hook in ~/.claude/settings.json opens the app whenever a Claude Code
// session starts (CLI, desktop app Code tab, IDE extensions). `open -g` hands the launch
// to LaunchServices, so it returns at once and never starts a second copy.

enum ClaudeHook {
    static let mark = "Claude Token Overlay.app"

    static var settingsURL: URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], let first = env.split(separator: ",").first {
            return URL(fileURLWithPath: String(first)).appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var installed: Bool {
        guard let root = try? read(), let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["SessionStart"] as? [Any] else { return false }
        return groups.contains(where: isOurs)
    }

    private static func isOurs(_ group: Any) -> Bool {
        guard let g = group as? [String: Any], let hs = g["hooks"] as? [[String: Any]] else { return false }
        return hs.contains { h in
            ([h["command"] as? String ?? ""] + (h["args"] as? [String] ?? [])).joined(separator: " ").contains(mark)
        }
    }

    /// Missing or empty file reads as {}; malformed JSON throws so it is never overwritten.
    private static func read() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "TokenOverlay", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a JSON object"])
        }
        return obj
    }

    static func set(_ on: Bool) throws {
        let app = Bundle.main.bundlePath
        if on && !app.hasSuffix(".app") {
            throw NSError(domain: "TokenOverlay", code: 2, userInfo: [NSLocalizedDescriptionKey: "run this from the app bundle (\(app))"])
        }
        var root = try read()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = (hooks["SessionStart"] as? [Any] ?? []).filter { !isOurs($0) }
        if on {
            groups.append(["matcher": "startup|resume", "hooks": [[
                "type": "command", "command": "/usr/bin/open", "args": ["-g", app], "timeout": 15]]] as [String: Any])
        }
        if groups.isEmpty { hooks.removeValue(forKey: "SessionStart") } else { hooks["SessionStart"] = groups }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = settingsURL.appendingPathExtension("before-token-overlay")
        if fm.fileExists(atPath: settingsURL.path) && !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: settingsURL, to: backup)
        }
        var out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        out.append(0x0a)
        try out.write(to: settingsURL, options: .atomic)
    }
}

// MARK: - Screenshot rendering (made-up numbers, no real usage)

func demoStats(cli: Int, app: Int, ide: Int, input: Int, output: Int, cacheWrite: Int) -> Stats {
    var s = Stats()
    s.input = input; s.output = output; s.cacheWrite = cacheWrite
    s.cacheRead = cli + app + ide - input - output - cacheWrite
    s.bySource = [.cli: cli, .app: app, .ide: ide]
    return s
}

func demoStore() -> Store {
    let st = Store()
    st.stats = [
        .today: demoStats(cli: 2_510_000, app: 1_610_000, ide: 703_000, input: 41_200, output: 212_400, cacheWrite: 608_000),
        .fiveHours: demoStats(cli: 820_000, app: 390_000, ide: 100_000, input: 9_800, output: 61_000, cacheWrite: 150_000),
        .week: demoStats(cli: 15_900_000, app: 8_300_000, ide: 4_200_000, input: 260_000, output: 1_350_000, cacheWrite: 3_100_000),
    ]
    st.updated = Date()
    return st
}

func demoSettings(compact: Bool) -> Settings {
    let s = Settings(); s.persist = false
    s.compact = compact; s.period = .today
    return s
}

struct DemoDesktop: View {
    let store: Store
    let settings: Settings
    var lines: [(String, Color)] { Self.sampleLines }
    static let sampleLines: [(String, Color)] = [
        ("$ claude", .white),
        ("> refactor the payment module and add tests", Color(white: 0.85)),
        ("", .white),
        ("● Read src/payments/charge.ts (182 lines)", Color(white: 0.6)),
        ("● Read src/payments/refund.ts (96 lines)", Color(white: 0.6)),
        ("● Update src/payments/charge.ts  +41 −27", Color(red: 0.45, green: 0.8, blue: 0.55)),
        ("● Update src/payments/refund.ts  +18 −9", Color(red: 0.45, green: 0.8, blue: 0.55)),
        ("● Write tests/payments/charge.test.ts  +120", Color(red: 0.45, green: 0.8, blue: 0.55)),
        ("● Bash npm test -- payments", Color(white: 0.6)),
        ("  ✓ 24 passed (1.8s)", Color(red: 0.45, green: 0.8, blue: 0.55)),
        ("", .white),
        ("Split charge() into validate, authorize and capture steps so each one can be tested on its own,", Color(white: 0.85)),
        ("and moved the retry logic into a shared helper used by both charge and refund.", Color(white: 0.85)),
        ("", .white),
        ("> ", .white),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.20, green: 0.15, blue: 0.38), Color(red: 0.04, green: 0.26, blue: 0.36)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            HStack(spacing: 16) {
                Image(systemName: "apple.logo")
                Text("Terminal").fontWeight(.semibold)
                Text("Shell"); Text("Edit"); Text("View"); Text("Window")
                Spacer()
                HStack(spacing: 4) { Image(systemName: "gauge.with.dots.needle.67percent"); Text("4.82M").monospacedDigit() }
                Image(systemName: "wifi"); Image(systemName: "battery.75percent")
                Text("Wed 14:32")
            }
            .font(.system(size: 13)).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(width: 1100, height: 28)
            .background(Color.black.opacity(0.3))

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                }
                .frame(width: 52, height: 12).padding(14)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        Text(l.0.isEmpty ? " " : l.0).foregroundStyle(l.1)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 18)
                Spacer()
            }
            .frame(width: 900, height: 470, alignment: .topLeading)
            .background(Color(white: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .offset(x: 50, y: 90)

            OverlayView(store: store, settings: settings, solid: true)
                .opacity(0.85)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                .offset(x: 1100 - 240 - 28, y: 48)
        }
        .frame(width: 1100, height: 620)
    }
}

func scaled(_ s: Stats, _ f: Double) -> Stats {
    func m(_ v: Int) -> Int { Int(Double(v) * f) }
    var o = Stats()
    o.input = m(s.input); o.output = m(s.output); o.cacheWrite = m(s.cacheWrite); o.cacheRead = m(s.cacheRead)
    o.bySource = s.bySource.mapValues(m)
    return o
}

let demoBackdrop = LinearGradient(colors: [Color(red: 0.20, green: 0.15, blue: 0.38), Color(red: 0.04, green: 0.26, blue: 0.36)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)

/// Small scene for animations: terminal text behind the overlay, plus an optional cursor.
struct DemoScene: View {
    let store: Store
    let settings: Settings
    var alpha = 0.85
    var cursor: CGPoint? = nil
    var ripple: Double? = nil      // 0...1 click animation progress

    var body: some View {
        ZStack(alignment: .topLeading) {
            demoBackdrop
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                }
                .frame(width: 46, height: 11).padding(.bottom, 8)
                ForEach(Array(DemoDesktop.sampleLines.prefix(11).enumerated()), id: \.offset) { _, l in
                    Text(l.0.isEmpty ? " " : l.0).foregroundStyle(l.1)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(14)
            .frame(width: 470, height: 290, alignment: .topLeading)
            .background(Color(white: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .offset(x: 20, y: 30)

            OverlayView(store: store, settings: settings, solid: true)
                .opacity(alpha)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
                .offset(x: 316, y: 20)

            if let c = cursor {
                if let r = ripple {
                    Circle().stroke(Color.white.opacity(0.8 * (1 - r)), lineWidth: 2)
                        .frame(width: 10 + 30 * r, height: 10 + 30 * r)
                        .offset(x: c.x - 5 - 15 * r, y: c.y - 5 - 15 * r)
                }
                Image(systemName: "cursorarrow")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 1.5)
                    .offset(x: c.x - 4, y: c.y - 3)
            }
        }
        .frame(width: 580, height: 340)
        .clipped()
    }
}

@MainActor func renderGIF(_ name: String, dir: String, fps: Double, frames: Int, scale: CGFloat = 2,
                          view: (Int) -> AnyView) {
    let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name))
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames, nil) else {
        print("failed: \(name)"); return
    }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                 kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
    for i in 0..<frames {
        let r = ImageRenderer(content: view(i))
        r.scale = scale
        if let cg = r.cgImage { CGImageDestinationAddImage(dest, cg, props) }
    }
    print(CGImageDestinationFinalize(dest) ? "wrote \(url.path)" : "failed: \(name)")
}

/// Hover fade, then three clicks on the number to switch period, then fade back.
@MainActor func renderInteractionGIF(dir: String) {
    let fps = 15.0
    let base = demoStore()
    // cursor keyframes: (time, x, y)
    let keys: [(Double, Double, Double)] = [
        (0.0, 150, 300), (0.8, 150, 300), (1.8, 372, 66), (3.2, 372, 66), (4.0, 200, 230),
        (4.8, 200, 230), (5.6, 372, 66), (8.4, 372, 66), (9.2, 170, 290), (10.4, 170, 290),
    ]
    let clicks: [(Double, Period)] = [(6.0, .fiveHours), (6.9, .week), (7.8, .today)]
    let duration = 10.4
    let frames = Int(duration * fps)
    let overlayRect = CGRect(x: 316, y: 20, width: 240, height: 250)

    func cursor(at t: Double) -> CGPoint {
        for k in 1..<keys.count where t <= keys[k].0 {
            let a = keys[k - 1], b = keys[k]
            var p = (t - a.0) / max(b.0 - a.0, 0.001)
            p = p * p * (3 - 2 * p)
            return CGPoint(x: a.1 + (b.1 - a.1) * p, y: a.2 + (b.2 - a.2) * p)
        }
        return CGPoint(x: keys.last!.1, y: keys.last!.2)
    }

    var alphas: [Double] = []
    var a = 0.85
    for i in 0..<frames {
        let target = overlayRect.contains(cursor(at: Double(i) / fps)) ? 0.30 : 0.85
        a += max(-0.08, min(0.08, target - a))
        alphas.append(a)
    }

    renderGIF("overlay-interaction.gif", dir: dir, fps: fps, frames: frames) { i in
        let t = Double(i) / fps
        let settings = demoSettings(compact: false)
        settings.period = clicks.last(where: { $0.0 <= t })?.1 ?? .today
        let ripple = clicks.map { t - $0.0 }.first(where: { $0 >= 0 && $0 < 0.4 }).map { $0 / 0.4 }
        return AnyView(DemoScene(store: base, settings: settings, alpha: alphas[i], cursor: cursor(at: t), ripple: ripple))
    }
}

/// The number climbing as requests come in.
@MainActor func renderCountGIF(dir: String) {
    let fps = 15.0, duration = 5.0
    let base = demoStore()
    renderGIF("overlay-live.gif", dir: dir, fps: fps, frames: Int(duration * fps)) { i in
        let step = Double(min(Int(Double(i) / fps / 0.5), 9))   // a new request every 0.5 s
        let f = 0.96 + 0.04 * step / 9
        let st = Store()
        st.stats = base.stats.mapValues { scaled($0, f) }
        st.updated = Date()
        return AnyView(
            ZStack { demoBackdrop; OverlayView(store: st, settings: demoSettings(compact: false), solid: true)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 5) }
            .frame(width: 300, height: 300))
    }
}

@MainActor func renderScreenshots(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func save<V: View>(_ view: V, _ name: String) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("failed: \(name)"); return
        }
        let path = (dir as NSString).appendingPathComponent(name)
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
    let store = demoStore()
    save(DemoDesktop(store: store, settings: demoSettings(compact: false)), "overlay-desktop.png")
    save(OverlayView(store: store, settings: demoSettings(compact: false), solid: true)
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4).padding(24), "overlay-full.png")
    save(OverlayView(store: store, settings: demoSettings(compact: true), solid: true)
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4).padding(24), "overlay-compact.png")
    renderInteractionGIF(dir: dir)
    renderCountGIF(dir: dir)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-screenshots") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "docs"
    MainActor.assumeIsolated { renderScreenshots(to: dir) }
    exit(0)
}

if CommandLine.arguments.contains("--install-hook") || CommandLine.arguments.contains("--uninstall-hook") {
    let on = CommandLine.arguments.contains("--install-hook")
    do {
        try ClaudeHook.set(on)
        print("\(on ? "Added" : "Removed") the SessionStart hook in \(ClaudeHook.settingsURL.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Couldn't update \(ClaudeHook.settingsURL.path) (left unchanged): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--dump") {   // headless check: print totals and exit
    let s = Scanner().scan()
    for p in Period.allCases {
        let st = s[p] ?? Stats()
        let parts = Source.allCases.map { "\($0.rawValue)=\(st.bySource[$0] ?? 0)" }.joined(separator: " ")
        print("\(p.label): \(st.total)  \(parts)  in=\(st.input) out=\(st.output) cw=\(st.cacheWrite) cr=\(st.cacheRead)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
