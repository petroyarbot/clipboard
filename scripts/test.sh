#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
failures=0
run() { "$@" || { echo "FAIL: $*" >&2; failures=$((failures + 1)); }; }
compile_and_run() {
    local binary="$1"; shift
    if swiftc "$@" -o "$binary"; then
        run "$binary"
    else
        echo "FAIL: compilation of $binary" >&2
        failures=$((failures + 1))
    fi
}
compile_and_run "$work_dir/panel-tests" Sources/NotchClip/PanelBehavior.swift Tests/Behavior/main.swift
compile_and_run "$work_dir/clipboard-tests" -parse-as-library Sources/NotchClip/History.swift Sources/NotchClip/ClipboardStore.swift Tests/ClipboardIntegration/main.swift
compile_and_run "$work_dir/drop-tests" -D NOTCHCLIP_TESTING -parse-as-library Sources/NotchClip/*.swift Tests/DropIntegration/main.swift
compile_and_run "$work_dir/panel-tab-tests" Sources/NotchClip/PanelTab.swift Tests/PanelTabs/main.swift
compile_and_run "$work_dir/settings-mapping-tests" Sources/NotchClip/SettingsMapping.swift Tests/SettingsMapping/main.swift
for suite in ./scripts/test-*.sh; do
    run "$suite"
done
exit "$((failures > 0))"
