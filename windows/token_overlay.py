#!/usr/bin/env python3
"""Claude Token Overlay for Windows.

A translucent, always-on-top overlay that tracks Claude Code token usage across
every local client (CLI, desktop app Code tab, IDE extensions). It reads the
session logs those clients write to %USERPROFILE%\\.claude\\projects.

Pure standard library (tkinter + ctypes). Run with:  pythonw token_overlay.py
Headless check:                                      python token_overlay.py --dump
Open with every Claude Code session:                 python token_overlay.py --install-hook
                                         (undo with  python token_overlay.py --uninstall-hook)

Started from a console (python.exe, a double-click) it relaunches itself under
pythonw and lets the console close. Only one copy runs at a time.
"""

import ctypes
import datetime as dt
import json
import os
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

IS_WIN = sys.platform == "win32"

SOURCES = [("CLI", "#7F77DD"), ("App", "#1D9E75"), ("IDE", "#D85A30"), ("Other", "#8C8C8C")]
PERIODS = [("today", "today"), ("5h", "last 5h"), ("week", "7 days")]
IDE_KEYS = ("vscode", "jetbrains", "intellij", "cursor", "windsurf", "zed", "ide")


def source_of(entrypoint):
    """Map the transcript's `entrypoint` field to a client bucket."""
    e = (entrypoint or "").lower()
    if not e or e == "cli":          # old CLI builds omit the field
        return "CLI"
    if "desktop" in e:
        return "App"
    if any(k in e for k in IDE_KEYS):
        return "IDE"
    return "Other"                   # sdk-*, headless, unknown


def fmt(n):
    if n >= 1e9:
        return f"{n / 1e9:.2f}B"
    if n >= 1e8:
        return f"{n / 1e6:.0f}M"
    if n >= 1e6:
        return f"{n / 1e6:.2f}M"
    if n >= 1e5:
        return f"{n / 1e3:.0f}K"
    if n >= 1e3:
        return f"{n / 1e3:.1f}K"
    return str(n)


# ---------------------------------------------------------------- scanner

class Scanner:
    """Incremental tail reader over every *.jsonl transcript."""

    KEEP = 8 * 86400

    def __init__(self):
        self.offsets, self.partial, self.recs = {}, {}, {}

    @staticmethod
    def roots():
        home = Path.home()
        dirs = [home / ".claude" / "projects", home / ".config" / "claude" / "projects"]
        env = os.environ.get("CLAUDE_CONFIG_DIR")
        if env:
            dirs += [Path(p) / "projects" for p in env.split(",") if p]
        seen, out = set(), []
        for d in dirs:
            if d.is_dir():
                key = str(d.resolve()).lower() if IS_WIN else str(d.resolve())
                if key not in seen:
                    seen.add(key)
                    out.append(d)
        return out

    def scan(self):
        now = time.time()
        cutoff = now - self.KEEP
        for root in self.roots():
            for dirpath, _, files in os.walk(root):
                for fn in files:
                    if fn.endswith(".jsonl"):
                        self._read(os.path.join(dirpath, fn), cutoff)
        self.recs = {k: v for k, v in self.recs.items() if v[0] >= cutoff}
        return self._aggregate(now)

    def _read(self, path, cutoff):
        try:
            st = os.stat(path)
        except OSError:
            return
        off = self.offsets.get(path)
        if off is None and st.st_mtime < cutoff:     # untouched for 8+ days
            self.offsets[path] = st.st_size
            return
        off = off or 0
        if st.st_size < off:                         # file rewritten
            off = 0
            self.partial.pop(path, None)
        if st.st_size == off:
            return
        try:
            with open(path, "rb") as f:
                f.seek(off)
                chunk = f.read()
        except OSError:
            return
        self.offsets[path] = off + len(chunk)
        buf = self.partial.get(path, b"") + chunk
        nl = buf.rfind(b"\n")
        if nl < 0:
            self.partial[path] = buf
            return
        self.partial[path] = buf[nl + 1:]
        for line in buf[:nl].split(b"\n"):
            if b'"usage"' in line:
                self._ingest(line, cutoff)

    def _ingest(self, line, cutoff):
        try:
            o = json.loads(line)
            msg = o["message"]
            u = msg["usage"]
            if msg.get("model") == "<synthetic>":
                return
            t = dt.datetime.fromisoformat(o["timestamp"].replace("Z", "+00:00")).timestamp()
        except (ValueError, KeyError, TypeError, AttributeError):
            return
        if t < cutoff:
            return

        def n(k):
            v = u.get(k)
            return v if isinstance(v, int) else 0

        # messageId:requestId dedupes streamed chunks and resumed sessions
        key = f"{msg.get('id') or id(line)}:{o.get('requestId', '')}"
        self.recs[key] = (t, source_of(o.get("entrypoint")), n("input_tokens"), n("output_tokens"),
                          n("cache_creation_input_tokens"), n("cache_read_input_tokens"))

    def _aggregate(self, now):
        midnight = dt.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        starts = {"today": midnight, "5h": now - 5 * 3600, "week": now - 7 * 86400}
        out = {}
        for p, start in starts.items():
            s = {"in": 0, "out": 0, "cw": 0, "cr": 0, "src": {name: 0 for name, _ in SOURCES}}
            for t, src, i, o_, cw, cr in self.recs.values():
                if t >= start:
                    s["in"] += i; s["out"] += o_; s["cw"] += cw; s["cr"] += cr
                    s["src"][src] += i + o_ + cw + cr
            s["total"] = s["in"] + s["out"] + s["cw"] + s["cr"]
            out[p] = s
        return out


# ---------------------------------------------------------------- settings

def settings_path():
    base = Path(os.environ.get("APPDATA", Path.home())) if IS_WIN else Path.home() / ".config"
    return base / "ClaudeTokenOverlay" / "settings.json"


DEFAULTS = {"period": "today", "compact": False, "idle_opacity": 0.85, "hover_opacity": 0.30,
            "click_through": False, "x": None, "y": None}


def load_settings():
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads(settings_path().read_text()))
    except (OSError, ValueError):
        pass
    return cfg


def save_settings(cfg):
    try:
        p = settings_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(cfg, indent=2))
    except OSError:
        pass


def startup_file():
    return Path(os.environ.get("APPDATA", "")) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / "ClaudeTokenOverlay.cmd"


def log_error(text):
    """Append to error.log next to settings.json; pythonw has nowhere else to print."""
    try:
        p = settings_path().with_name("error.log")
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write(f"--- {dt.datetime.now():%Y-%m-%d %H:%M:%S}\n{text}\n")
        return p
    except OSError:
        return None


# ---------------------------------------------------------------- process

SCRIPT = Path(__file__).resolve()


def pythonw_exe():
    exe = Path(sys.executable)
    w = exe.with_name("pythonw.exe")
    return w if IS_WIN and w.exists() else exe


def has_console():
    return IS_WIN and bool(ctypes.windll.kernel32.GetConsoleWindow())


def spawn_detached():
    """Start the overlay as its own process, outside any console or job, and return."""
    args = [str(pythonw_exe()), str(SCRIPT)]
    if not IS_WIN:
        subprocess.Popen(args, start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    flags = 0x00000008 | 0x00000200   # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    for extra in (0x01000000, 0):     # CREATE_BREAKAWAY_FROM_JOB, if the job allows it
        try:
            subprocess.Popen(args, creationflags=flags | extra, close_fds=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        except OSError:
            if not extra:
                raise


_mutex = None


def already_running():
    """Hold a named mutex for the process lifetime; True if another copy holds it."""
    global _mutex
    if not IS_WIN:
        return False
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.CreateMutexW.restype = ctypes.c_void_p
    _mutex = k.CreateMutexW(None, False, "Local\\ClaudeTokenOverlay")
    return ctypes.get_last_error() == 183   # ERROR_ALREADY_EXISTS


# ---------------------------------------------------------------- Claude Code hook
# A SessionStart hook in ~/.claude/settings.json opens the overlay whenever a Claude
# Code session starts (CLI, desktop app Code tab, IDE extensions). `args` runs the
# program directly, so no bash or PowerShell quoting is involved.

HOOK_MARK = "token_overlay"


def claude_settings_path():
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(env.split(",")[0]) if env else Path.home() / ".claude"
    return base / "settings.json"


def _is_ours(group):
    return any(HOOK_MARK in json.dumps(h) for h in group.get("hooks", []) if isinstance(h, dict))


def _read_claude_settings():
    p = claude_settings_path()
    try:
        text = p.read_text(encoding="utf-8")
    except FileNotFoundError:
        return p, {}
    data = json.loads(text) if text.strip() else {}   # malformed JSON raises: never overwrite it
    if not isinstance(data, dict):
        raise ValueError(f"{p} is not a JSON object")
    return p, data


def hook_installed():
    try:
        _, data = _read_claude_settings()
    except (OSError, ValueError):
        return False
    groups = data.get("hooks", {}).get("SessionStart", [])
    return any(_is_ours(g) for g in groups if isinstance(g, dict))


def set_claude_hook(enable):
    p, data = _read_claude_settings()
    hooks = data.setdefault("hooks", {})
    groups = [g for g in hooks.get("SessionStart", []) if not (isinstance(g, dict) and _is_ours(g))]
    if enable:
        groups.append({"matcher": "startup|resume", "hooks": [{
            "type": "command", "command": str(pythonw_exe()), "args": [str(SCRIPT), "--spawn"], "timeout": 15}]})
    if groups:
        hooks["SessionStart"] = groups
    else:
        hooks.pop("SessionStart", None)
    if not hooks:
        data.pop("hooks")
    p.parent.mkdir(parents=True, exist_ok=True)
    bak = p.with_name(p.name + ".before-token-overlay")
    if p.exists() and not bak.exists():
        bak.write_bytes(p.read_bytes())
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, p)
    return p


# ---------------------------------------------------------------- Win32 helpers

GWL_EXSTYLE, WS_EX_LAYERED, WS_EX_TRANSPARENT, WS_EX_TOOLWINDOW = -20, 0x80000, 0x20, 0x80


def win_hwnd(root):
    return ctypes.windll.user32.GetParent(root.winfo_id())


def win_set_exstyle(root, add=0, remove=0):
    u = ctypes.windll.user32
    h = win_hwnd(root)
    style = u.GetWindowLongW(h, GWL_EXSTYLE)
    u.SetWindowLongW(h, GWL_EXSTYLE, (style | add) & ~remove)


def ctrl_down():
    return IS_WIN and bool(ctypes.windll.user32.GetAsyncKeyState(0x11) & 0x8000)


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


def on_screen(x, y):
    """True if the window's top-left corner lands on a connected monitor."""
    if not IS_WIN:
        return True
    return bool(ctypes.windll.user32.MonitorFromPoint(POINT(int(x) + 20, int(y) + 20), 0))   # MONITOR_DEFAULTTONULL


# ---------------------------------------------------------------- UI

BG, FG, MUTED, TRACK = "#1c1c1e", "#f2f2f2", "#9a9aa0", "#3a3a3c"
FONT = "Segoe UI" if IS_WIN else "Helvetica"
WIDTH = 240


class Overlay:
    def __init__(self):
        import tkinter as tk
        self.tk = tk
        if IS_WIN:
            try:
                ctypes.windll.shcore.SetProcessDpiAwareness(1)   # crisp text on HiDPI
            except (AttributeError, OSError):
                pass

        self.cfg = load_settings()
        self.stats, self.pending, self.scanning = {}, None, False
        self.scanner = Scanner()
        self.alpha = self.cfg["idle_opacity"]
        self.transparent = False
        self.drag = None

        r = self.root = tk.Tk()
        r.report_callback_exception = lambda *exc: log_error("".join(traceback.format_exception(*exc)))
        r.title("Claude Token Overlay")
        r.overrideredirect(True)
        r.attributes("-topmost", True)
        r.attributes("-alpha", self.alpha)
        r.configure(bg=BG)

        self.frame = tk.Frame(r, bg=BG, padx=14, pady=10)
        self.frame.pack()
        self.title = tk.Label(self.frame, bg=BG, fg=MUTED, font=(FONT, 9), anchor="w")
        self.title.pack(fill="x")
        self.big = tk.Label(self.frame, text="…", bg=BG, fg=FG, anchor="w", cursor="hand2")
        self.big.pack(fill="x")
        self.bar = tk.Canvas(self.frame, width=WIDTH - 28, height=6, bg=TRACK, highlightthickness=0, bd=0)
        self.bar.pack(fill="x", pady=(2, 6))
        self.legend = tk.Frame(self.frame, bg=BG)
        self.details = tk.Frame(self.frame, bg=BG)

        self._build_menu()
        r.bind_all("<ButtonPress-1>", self._press)
        r.bind_all("<B1-Motion>", self._motion)
        r.bind_all("<ButtonRelease-1>", self._release)
        r.bind_all("<Button-3>", self._popup)
        if sys.platform == "darwin":
            r.bind_all("<Button-2>", self._popup)

        r.update_idletasks()
        x, y = self.cfg["x"], self.cfg["y"]
        if x is None or y is None or not on_screen(x, y):   # e.g. saved on a monitor that is unplugged now
            x, y = r.winfo_screenwidth() - WIDTH - 24, 40
        r.geometry(f"+{int(x)}+{int(y)}")

        if IS_WIN:
            r.update_idletasks()
            win_set_exstyle(r, add=WS_EX_TOOLWINDOW)            # keep it off Alt-Tab
            try:                                                # Windows 11 rounded corners
                pref = ctypes.c_int(2)
                ctypes.windll.dwmapi.DwmSetWindowAttribute(win_hwnd(r), 33, ctypes.byref(pref), 4)
            except (AttributeError, OSError):
                pass

        self.render()
        self.refresh()
        r.after(120, self.tick)

    # ---- data

    def refresh(self):
        if not self.scanning:
            self.scanning = True
            threading.Thread(target=self._scan_worker, daemon=True).start()
        self.root.after(5000, self.refresh)

    def _scan_worker(self):
        try:
            self.pending = self.scanner.scan()
        finally:
            self.scanning = False

    # ---- render

    def render(self):
        tk = self.tk
        p = self.cfg["period"]
        label = dict(PERIODS)[p]
        s = self.stats.get(p)
        self.title.config(text=f"Claude tokens · {label}")
        self.big.config(text=fmt(s["total"]) if s else "…",
                        font=(FONT, 16 if self.cfg["compact"] else 20, "bold"))

        self.bar.delete("all")
        if s and s["total"]:
            w, x = WIDTH - 28, 0
            for name, color in SOURCES:
                seg = w * s["src"][name] / s["total"]
                if seg > 0:
                    self.bar.create_rectangle(x, 0, x + seg, 6, fill=color, width=0)
                    x += seg

        for f in (self.legend, self.details):
            for c in f.winfo_children():
                c.destroy()
            f.pack_forget()
        if self.cfg["compact"] or not s:
            return

        self.legend.pack(fill="x")
        for name, color in SOURCES:
            v = s["src"][name]
            if v or name != "Other":
                tk.Label(self.legend, text="●", fg=color, bg=BG, font=(FONT, 8)).pack(side="left")
                tk.Label(self.legend, text=f"{name} {fmt(v)} ", fg=MUTED, bg=BG, font=(FONT, 9)).pack(side="left")

        self.details.pack(fill="x", pady=(6, 0))
        tk.Frame(self.details, bg=TRACK, height=1).pack(fill="x", pady=(0, 4))
        rows = [(lbl[0].upper() + lbl[1:], fmt(self.stats[k]["total"]), FG) for k, lbl in PERIODS if k != p]
        rows += [("In / out", f"{fmt(s['in'])} / {fmt(s['out'])}", MUTED),
                 ("Cache write / read", f"{fmt(s['cw'])} / {fmt(s['cr'])}", MUTED)]
        for k, v, color in rows:
            row = tk.Frame(self.details, bg=BG)
            row.pack(fill="x")
            tk.Label(row, text=k, fg=MUTED, bg=BG, font=(FONT, 9)).pack(side="left")
            tk.Label(row, text=v, fg=color, bg=BG, font=(FONT, 9)).pack(side="right")

    # ---- loop: new data, hover fade, click-through

    def tick(self):
        r = self.root
        if self.pending is not None:
            self.stats, self.pending = self.pending, None
            self.render()

        px, py = r.winfo_pointerxy()
        inside = r.winfo_rootx() <= px < r.winfo_rootx() + r.winfo_width() and \
            r.winfo_rooty() <= py < r.winfo_rooty() + r.winfo_height()
        target = self.cfg["hover_opacity"] if inside and not ctrl_down() else self.cfg["idle_opacity"]
        if abs(self.alpha - target) > 0.01:
            self.alpha += max(-0.08, min(0.08, target - self.alpha))
            r.attributes("-alpha", self.alpha)

        if IS_WIN:   # click-through, suspended while Ctrl is held so you can drag / right-click
            want = self.cfg["click_through"] and not ctrl_down()
            if want != self.transparent:
                if want:
                    win_set_exstyle(r, add=WS_EX_LAYERED | WS_EX_TRANSPARENT)
                else:
                    win_set_exstyle(r, remove=WS_EX_TRANSPARENT)
                self.transparent = want
        r.after(120, self.tick)

    # ---- mouse

    def _press(self, e):
        if e.widget.winfo_toplevel() is self.root:
            self.drag = (e.x_root, e.y_root, self.root.winfo_x(), self.root.winfo_y(), e.widget)

    def _motion(self, e):
        if self.drag:
            x0, y0, wx, wy, _ = self.drag
            self.root.geometry(f"+{wx + e.x_root - x0}+{wy + e.y_root - y0}")

    def _release(self, e):
        if not self.drag:
            return
        x0, y0, _, _, widget = self.drag
        self.drag = None
        if abs(e.x_root - x0) < 3 and abs(e.y_root - y0) < 3:
            if widget is self.big:
                self.cycle_period()
            return
        self.cfg["x"], self.cfg["y"] = self.root.winfo_x(), self.root.winfo_y()
        save_settings(self.cfg)

    # ---- menu and settings

    def _build_menu(self):
        tk = self.tk
        self.v_period = tk.StringVar(value=self.cfg["period"])
        self.v_compact = tk.BooleanVar(value=self.cfg["compact"])
        self.v_click = tk.BooleanVar(value=self.cfg["click_through"])
        self.v_login = tk.BooleanVar(value=IS_WIN and startup_file().exists())
        self.v_claude = tk.BooleanVar(value=hook_installed())
        m = self.menu = tk.Menu(self.root, tearoff=0)
        for key, lbl in PERIODS:
            m.add_radiobutton(label=lbl[0].upper() + lbl[1:], value=key, variable=self.v_period,
                              command=lambda: self.set_cfg("period", self.v_period.get()))
        m.add_separator()
        m.add_command(label="Opacity…", command=self.open_settings)
        m.add_checkbutton(label="Compact", variable=self.v_compact,
                          command=lambda: self.set_cfg("compact", self.v_compact.get()))
        if IS_WIN:
            m.add_checkbutton(label="Click-through (hold Ctrl to grab)", variable=self.v_click,
                              command=lambda: self.set_cfg("click_through", self.v_click.get()))
        m.add_checkbutton(label="Launch with Claude", variable=self.v_claude, command=self.toggle_claude)
        if IS_WIN:
            m.add_checkbutton(label="Launch at login", variable=self.v_login, command=self.toggle_login)
        m.add_command(label="Reset position", command=self.reset_position)
        m.add_separator()
        m.add_command(label="Quit", command=self.root.destroy)

    def _popup(self, e):
        if e.widget.winfo_toplevel() is self.root:
            self.menu.tk_popup(e.x_root, e.y_root)

    def set_cfg(self, key, value):
        self.cfg[key] = value
        save_settings(self.cfg)
        self.render()

    def cycle_period(self):
        keys = [k for k, _ in PERIODS]
        nxt = keys[(keys.index(self.cfg["period"]) + 1) % len(keys)]
        self.v_period.set(nxt)
        self.set_cfg("period", nxt)

    def reset_position(self):
        self.root.geometry(f"+{self.root.winfo_screenwidth() - WIDTH - 24}+40")
        self.cfg["x"] = self.cfg["y"] = None
        save_settings(self.cfg)

    def toggle_login(self):
        f = startup_file()
        try:
            if self.v_login.get():
                exe = Path(sys.executable)
                pyw = exe.with_name("pythonw.exe")
                runner = pyw if pyw.exists() else exe
                f.write_text(f'@start "" "{runner}" "{Path(__file__).resolve()}"\r\n')
            elif f.exists():
                f.unlink()
        except OSError:
            self.v_login.set(f.exists())

    def toggle_claude(self):
        try:
            set_claude_hook(self.v_claude.get())
        except (OSError, ValueError) as e:
            self.v_claude.set(hook_installed())
            from tkinter import messagebox
            messagebox.showerror("Launch with Claude", f"Couldn't update {claude_settings_path()}:\n{e}")

    def open_settings(self):
        tk = self.tk
        w = tk.Toplevel(self.root)
        w.title("Overlay opacity")
        w.attributes("-topmost", True)
        w.resizable(False, False)
        for key, label, lo in (("idle_opacity", "Opacity", 15), ("hover_opacity", "Opacity on hover", 5)):
            tk.Label(w, text=label, anchor="w").pack(fill="x", padx=14, pady=(10, 0))
            sc = tk.Scale(w, from_=lo, to=100, orient="horizontal", length=240,
                          command=lambda v, k=key: self._set_opacity(k, v))
            sc.set(int(round(self.cfg[key] * 100)))
            sc.pack(padx=14)
        tk.Button(w, text="Done", command=w.destroy).pack(pady=10)

    def _set_opacity(self, key, v):
        self.cfg[key] = int(float(v)) / 100
        save_settings(self.cfg)

    def run(self):
        self.root.mainloop()


def dump():
    s = Scanner().scan()
    for key, label in PERIODS:
        st = s[key]
        parts = " ".join(f"{name}={st['src'][name]}" for name, _ in SOURCES)
        print(f"{label}: {st['total']}  {parts}  in={st['in']} out={st['out']} cw={st['cw']} cr={st['cr']}")


def main():
    argv = sys.argv[1:]
    if "--dump" in argv:
        return dump()
    if "--install-hook" in argv or "--uninstall-hook" in argv:
        on = "--install-hook" in argv
        try:
            print(f"{'Added' if on else 'Removed'} the SessionStart hook in {set_claude_hook(on)}")
        except (OSError, ValueError) as e:
            sys.exit(f"Couldn't update {claude_settings_path()} (left unchanged): {e}")
        return
    if "--spawn" in argv or has_console():   # hand off to a console-less, detached pythonw
        return spawn_detached()
    if already_running():
        return
    try:
        Overlay().run()
    except Exception:
        where = log_error(traceback.format_exc())
        if IS_WIN:
            ctypes.windll.user32.MessageBoxW(None, f"Claude Token Overlay failed to start.\n\nDetails: {where}",
                                             "Claude Token Overlay", 0x10)
        raise


if __name__ == "__main__":
    main()
