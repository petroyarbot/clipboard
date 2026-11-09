#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-shelf-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc Sources/NotchClip/Shelf.swift Sources/NotchClip/ShelfView.swift Tests/Shelf/main.swift -o "$work_dir/shelf-tests"
"$work_dir/shelf-tests"
