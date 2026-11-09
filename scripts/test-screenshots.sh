#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-screenshot-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc Sources/NotchClip/ScreenshotWatcher.swift Tests/ScreenshotWatcher/main.swift -o "$work_dir/screenshot-tests"
"$work_dir/screenshot-tests"
