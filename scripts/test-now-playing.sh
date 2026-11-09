#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-now-playing-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc Sources/NotchClip/NowPlaying.swift Sources/NotchClip/NowPlayingView.swift Tests/NowPlaying/main.swift -o "$work_dir/now-playing-tests"
"$work_dir/now-playing-tests"
