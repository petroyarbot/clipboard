#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-focus.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
app="$work_dir/FocusCheck.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FocusCheck</string>
<key>CFBundleIdentifier</key><string>app.notchclip.focustest</string>
<key>CFBundleName</key><string>NotchClip Focus Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -parse-as-library -D NOTCHCLIP_TESTING \
  Sources/NotchClip/*.swift Tests/PanelFocus/main.swift \
  -o "$app/Contents/MacOS/FocusCheck"
"$app/Contents/MacOS/FocusCheck"
