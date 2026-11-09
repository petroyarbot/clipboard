#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SPM_ARGS=()
if [[ "${NOTCHCLIP_NO_SPM_SANDBOX:-0}" == 1 ]]; then
  SPM_ARGS+=(--disable-sandbox -debug-info-format none --scratch-path "${NOTCHCLIP_SPM_SCRATCH:-/tmp/claude-501/nc-app-build}")
fi
swift build ${SPM_ARGS[@]+"${SPM_ARGS[@]}"} -c release --arch arm64
BIN="$(swift build ${SPM_ARGS[@]+"${SPM_ARGS[@]}"} -c release --arch arm64 --show-bin-path)/NotchClip"
APP="${1:-$PWD/build/NotchClip.app}"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NotchClip"
# Build the helper from the same source used by the development fallback.
mkdir -p "$APP/Contents/Resources"
HELPER_SOURCE="$(mktemp "${TMPDIR:-/tmp}/notchclip-nowplaying.XXXXXX.m")"
trap 'rm -f "$HELPER_SOURCE"' EXIT
python3 - "$HELPER_SOURCE" <<'PYHELPER'
import pathlib, sys
source = pathlib.Path('Sources/NotchClip/NowPlaying.swift').read_text()
source = source.split('static let source = #"""', 1)[1].split('"""#', 1)[0]
pathlib.Path(sys.argv[1]).write_text(source)
PYHELPER
clang -dynamiclib -fobjc-arc -arch arm64 -mmacosx-version-min=13.0 -framework Foundation -o "$APP/Contents/Resources/nowplaying.dylib" "$HELPER_SOURCE"
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
# Стабильная подпись локальным сертификатом сохраняет разрешения macOS между сборками.
SIGN_IDENTITY="NotchClip Local Signing"
SIGN_OUT="$(security find-identity -v -p codesigning)"
case "$SIGN_OUT" in
  *"$SIGN_IDENTITY"*)
    codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/nowplaying.dylib"
    codesign --force --deep --sign "$SIGN_IDENTITY" --identifier app.notchclip.mac "$APP"
    echo "Подпись: «${SIGN_IDENTITY}» (стабильная, разрешения macOS сохраняются)."
    ;;
  *)
    codesign --force --sign - "$APP/Contents/Resources/nowplaying.dylib"
    codesign --force --sign - "$APP"
    echo "Подпись: ad-hoc (временная)."
    echo "Подпись временная — разрешения macOS будут слетать после обновлений. Запусти ./scripts/setup-signing.sh"
    ;;
esac
echo "Built: $APP"
