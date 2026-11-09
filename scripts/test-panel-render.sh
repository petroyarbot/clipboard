#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-render-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc -D NOTCHCLIP_TESTING -parse-as-library Sources/NotchClip/*.swift Tests/PanelRender/main.swift -o "$work_dir/panel-render-tests"
"$work_dir/panel-render-tests"
