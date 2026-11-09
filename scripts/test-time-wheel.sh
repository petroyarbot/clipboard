#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-time-wheel-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc Sources/NotchClip/TimeWheelPicker.swift Tests/TimeWheel/main.swift -o "$work_dir/time-wheel-tests"
"$work_dir/time-wheel-tests"
