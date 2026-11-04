#!/bin/zsh
# Builds Claude Token Overlay.app next to this script. Usage: ./build.sh [--run]
set -euo pipefail
cd "${0:A:h}"
APP="Claude Token Overlay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target "$(uname -m)-apple-macos14" Sources/main.swift -o "$APP/Contents/MacOS/TokenOverlay"
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
if [[ "${1:-}" == "--run" ]]; then open "$APP"; fi
