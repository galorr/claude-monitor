#!/bin/bash
# Build ClaudeMonitor.app (ad-hoc signed) into app/build/.
# SwiftPM only (no Xcode project, decisions.md D-009): build the release binary,
# then wrap it in a minimal bundle with LSUIElement so it lives in the menu bar only.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ClaudeMonitor
bin="$(swift build -c release --show-bin-path)/ClaudeMonitor"

app="build/ClaudeMonitor.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/ClaudeMonitor"

version="0.1.0"
build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.claude-monitor</string>
  <key>CFBundleName</key><string>Claude Monitor</string>
  <key>CFBundleDisplayName</key><string>Claude Monitor</string>
  <key>CFBundleExecutable</key><string>ClaudeMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "Built $(pwd)/$app"
