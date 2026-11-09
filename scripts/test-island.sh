#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-island-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc Sources/NotchClip/FocusTimer.swift Sources/NotchClip/IslandState.swift Tests/IslandState/main.swift -o "$work_dir/island-tests"
"$work_dir/island-tests"
