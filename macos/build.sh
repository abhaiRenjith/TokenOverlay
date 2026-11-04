#!/bin/zsh
# Builds Claude Token Overlay.app next to this script.
# Usage: ./build.sh [--install] [--run]
#   --install  copy the app to $APP_DIR (default ~/Applications), open it with every Claude Code
#              session (SessionStart hook in ~/.claude/settings.json), and link the binary as
#              `TokenOverlay` into $INSTALL_DIR (default ~/.local/bin)
#   --run      open the app after building
set -euo pipefail
cd "${0:A:h}"
APP="Claude Token Overlay.app"
BIN="$PWD/$APP/Contents/MacOS/TokenOverlay"
APP_DIR="${APP_DIR:-$HOME/Applications}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

do_install=0 do_run=0
for arg in "$@"; do
  case "$arg" in
    --install) do_install=1 ;;
    --run) do_run=1 ;;
    *) echo "Unknown option: $arg (use --install and/or --run)" >&2; exit 2 ;;
  esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target "$(uname -m)-apple-macos14" Sources/main.swift -o "$BIN"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Token Overlay</string>
  <key>CFBundleIdentifier</key><string>local.claude-token-overlay</string>
  <key>CFBundleExecutable</key><string>TokenOverlay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built: $PWD/$APP"

if (( do_install )); then
  INSTALLED="$APP_DIR/$APP"
  INSTALLED_BIN="$INSTALLED/Contents/MacOS/TokenOverlay"
  osascript -e 'quit app id "local.claude-token-overlay"' >/dev/null 2>&1 || true   # replace a running copy
  mkdir -p "$APP_DIR"
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  echo "Installed: $INSTALLED"

  "$INSTALLED_BIN" --install-hook        # hook points at the installed copy
  echo "It now opens with every new Claude Code session (turn off: menu bar icon > Launch with Claude)."

  mkdir -p "$INSTALL_DIR"
  ln -sf "$INSTALLED_BIN" "$INSTALL_DIR/TokenOverlay"
  echo "Linked: $INSTALL_DIR/TokenOverlay -> $INSTALLED_BIN"
  if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
    echo "Try it: TokenOverlay --dump   (run 'rehash' or open a new tab if your shell says command not found)"
  else
    echo "$INSTALL_DIR is not on your PATH. Add it, then open a new terminal tab:"
    echo "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc"
  fi
  if (( do_run )); then open "$INSTALLED"; fi
else
  echo "Print totals: \"$BIN\" --dump"
  echo "Or run ./build.sh --install to install it and open it with every Claude Code session."
  if (( do_run )); then open "$APP"; fi
fi
