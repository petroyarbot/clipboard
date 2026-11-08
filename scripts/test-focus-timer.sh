#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-focus-timer-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc Sources/NotchClip/FocusTimer.swift Tests/FocusTimer/main.swift -o "$work_dir/focus-timer-tests"
"$work_dir/focus-timer-tests"
