#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc Sources/NotchClip/PanelBehavior.swift Tests/Behavior/main.swift -o "$work_dir/panel-tests"
"$work_dir/panel-tests"
swiftc -parse-as-library Sources/NotchClip/History.swift Sources/NotchClip/ClipboardStore.swift Tests/ClipboardIntegration/main.swift -o "$work_dir/clipboard-tests"
"$work_dir/clipboard-tests"
swiftc -D NOTCHCLIP_TESTING -parse-as-library Sources/NotchClip/*.swift Tests/DropIntegration/main.swift -o "$work_dir/drop-tests"
"$work_dir/drop-tests"
