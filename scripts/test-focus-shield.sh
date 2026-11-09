#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-focus-shield-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc Sources/NotchClip/FocusShield.swift Tests/FocusShield/main.swift -o "$work_dir/focus-shield-tests"
"$work_dir/focus-shield-tests"
