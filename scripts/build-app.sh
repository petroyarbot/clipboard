#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/NotchClip"
APP="${1:-$PWD/build/NotchClip.app}"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NotchClip"
# Agent hook scripts: the Settings window runs setup-agent-hooks.sh from here.
HOOKS_DIR="$APP/Contents/Resources/agent-hooks"
rm -rf "$HOOKS_DIR"
mkdir -p "$HOOKS_DIR"
cp scripts/agent-hooks/*.sh "$HOOKS_DIR/"
chmod 755 "$HOOKS_DIR"/*.sh
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
if COMMIT="$(git rev-parse --short HEAD 2>/dev/null)"; then
  [ -n "$(git status --porcelain 2>/dev/null)" ] && COMMIT="$COMMIT-dirty"
else
  COMMIT="unknown"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NotchClip</string>
<key>CFBundleIdentifier</key><string>app.notchclip.mac</string>
<key>CFBundleName</key><string>NotchClip</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>$BUILD_NUM</string>
<key>NotchClipCommit</key><string>$COMMIT</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built: $APP"
