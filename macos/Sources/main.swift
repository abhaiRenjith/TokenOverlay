// Claude Token Overlay — floating, translucent macOS overlay that tracks Claude Code
// token usage across every local client (CLI, desktop app Code tab, IDE extensions).
// Data source: the JSONL transcripts all of them write under ~/.claude/projects.

import AppKit
import SwiftUI
import ServiceManagement

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
    @Published var period: Period { didSet { d.set(period.rawValue, forKey: "period") } }
    @Published var compact: Bool { didSet { d.set(compact, forKey: "compact") } }
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
    if x >= 1e6 { return String(format: "%.2fM", x / 1e6) }
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
                                Text("\(src.rawValue) \(fmt(v))")
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
        .background(VisualEffect())
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
        if !panel.setFrameUsingName("TokenOverlay") { resetPosition() }
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
