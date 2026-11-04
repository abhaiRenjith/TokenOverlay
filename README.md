# Claude Token Overlay

A small, translucent, always-on-top overlay that tracks your Claude Code token usage across every local client: the CLI, the Claude desktop app's Code tab, and IDE extensions (VS Code, JetBrains). Works on macOS and Windows.

It reads the session logs those clients write to `~/.claude/projects` (on Windows `%USERPROFILE%\.claude\projects`; also `~/.config/claude/projects` and `$CLAUDE_CONFIG_DIR`). Nothing leaves your machine.

**[Try it in your browser →](https://abhairenjith.github.io/TokenOverlay/)** drag it, hover it, click the number, change the opacity.

![The overlay floating over a terminal](docs/overlay-desktop.png)

<p>
  <img src="docs/overlay-interaction.gif" alt="Hovering fades the overlay; clicking the number switches between today, last 5h and 7 days" width="580">
</p>
<p>
  <img src="docs/overlay-live.gif" alt="The count climbing as requests come in" width="288">
  <img src="docs/overlay-compact.png" alt="Compact overlay" width="288">
</p>

<sub>Images are rendered from the app's own view with sample numbers (macOS). Regenerate with `TokenOverlay --render-screenshots docs`.</sub>

## What it shows

- Total tokens for today, the last 5 hours, or the last 7 days (click the number to switch)
- A bar split by client: CLI, App, IDE
- Input / output and cache write / cache read breakdown

## macOS

Native Swift app with a menu bar icon. Needs macOS 14+ and the Xcode command line tools (`xcode-select --install`).

```bash
git clone <repo-url>
cd TokenOverlay/macos
./build.sh --run
```

Settings live in the menu bar icon: opacity, opacity on hover, click-through, compact mode, count in the menu bar, launch at login, reset position.

## Windows

Python script with no dependencies beyond the standard library. Needs Python 3.8+ from [python.org](https://www.python.org/downloads/) (tick "Add to PATH").

```bat
git clone <repo-url>
cd TokenOverlay\windows
run.bat
```

Right-click the overlay for settings: period, opacity, compact mode, click-through, launch at login, reset position. With click-through on, hold Ctrl to drag or right-click it again.

## Both

- Drag the overlay to move it; the position is remembered.
- `--dump` prints the totals to the terminal and exits (`TokenOverlay --dump` on macOS, `python token_overlay.py --dump` on Windows).

## Notes

- Ordinary claude.ai chats (outside the Code tab) keep no local log and are not counted.
- Each request resends the conversation, so cache reads usually dominate the total. They cost about a tenth of normal input tokens.
- It counts tokens; it does not show the remaining quota on your plan.

## License

MIT

## Demo page

`docs/index.html` is the browser demo. To publish it, open the repo on GitHub → Settings → Pages, and set the source to the `main` branch, `/docs` folder.
