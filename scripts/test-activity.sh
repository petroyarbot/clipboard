#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-activity-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc Sources/NotchClip/ActivityTracker.swift Tests/ActivityTracker/main.swift -o "$work_dir/activity-tracker-tests"
"$work_dir/activity-tracker-tests"
