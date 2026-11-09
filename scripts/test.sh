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
swiftc Sources/NotchClip/PanelTab.swift Tests/PanelTabs/main.swift -o "$work_dir/panel-tab-tests"
"$work_dir/panel-tab-tests"
swiftc Sources/NotchClip/SettingsMapping.swift Tests/SettingsMapping/main.swift -o "$work_dir/settings-mapping-tests"
"$work_dir/settings-mapping-tests"
./scripts/test-agents.sh
./scripts/test-focus-timer.sh
./scripts/test-time-wheel.sh
./scripts/test-island.sh
