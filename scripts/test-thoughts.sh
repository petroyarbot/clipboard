#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-thought-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
# AgentMonitor needs UsageParser (UsageMonitor.swift), which needs the Claude and Codex clients.
swiftc Sources/NotchClip/ThoughtCapture.swift Sources/NotchClip/ThoughtCaptureView.swift \
  Sources/NotchClip/AgentMonitor.swift Sources/NotchClip/UsageMonitor.swift \
  Sources/NotchClip/ClaudeUsageClient.swift Sources/NotchClip/CodexUsageClient.swift \
  Tests/ThoughtCapture/main.swift -o "$work_dir/thought-tests"
"$work_dir/thought-tests"
