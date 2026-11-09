#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-ocr-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc -module-cache-path "$work_dir/module-cache" Sources/NotchClip/ImageTextRecognizer.swift Tests/OCR/main.swift -o "$work_dir/ocr-tests"
"$work_dir/ocr-tests"
