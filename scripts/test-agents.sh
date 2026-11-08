#!/bin/bash
# Tests for the agent/usage data layer: Swift checks plus the hook scripts run against sample input.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-agent-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

failures=0
pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
expect() { # name, condition-result (0 = true)
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

# 1. Swift checks for UsageMonitor and AgentMonitor.
swiftc Sources/NotchClip/UsageMonitor.swift Sources/NotchClip/AgentMonitor.swift Tests/AgentData/main.swift \
  -o "$work_dir/agent-data-tests"
"$work_dir/agent-data-tests"

# 2. Hook scripts with sample stdin, writing into a temp data dir.
export NOTCHCLIP_DATA_DIR="$work_dir/data"
mkdir -p "$NOTCHCLIP_DATA_DIR"
hooks="$repo/scripts/agent-hooks"
now="$(date +%s)"

# 2a. Status line writes limits and prints a short line.
statusline_input='{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":37.4,"resets_at":'$((now + 3600))'},"seven_day":{"used_percentage":12,"resets_at":'$((now + 86400))'}}}'
out="$(printf '%s' "$statusline_input" | "$hooks/notchclip-statusline.sh")"
expect "statusline prints model and both windows" "$([ "$out" = "Opus · 5ч 37% · нед 12%" ] && echo 0 || echo 1)"
expect "statusline writes claude-limits.json" "$([ -f "$NOTCHCLIP_DATA_DIR/claude-limits.json" ] && echo 0 || echo 1)"
expect "limits file has five_hour used 37.4 and resets_at" "$(jq -e --argjson reset "$((now + 3600))" --argjson now "$now" '.five_hour.used_percentage == 37.4 and .five_hour.resets_at == $reset and .updated_at >= $now' "$NOTCHCLIP_DATA_DIR/claude-limits.json" >/dev/null 2>&1 && echo 0 || echo 1)"

# 2b. Missing windows stay null; no rate_limits leaves the file untouched.
printf '%s' '{"model":{"display_name":"Sonnet"},"rate_limits":{"seven_day":{"used_percentage":5}}}' | "$hooks/notchclip-statusline.sh" >/dev/null
expect "missing five_hour is written as null" "$(jq -e '.five_hour == null and .seven_day.used_percentage == 5 and .seven_day.resets_at == null' "$NOTCHCLIP_DATA_DIR/claude-limits.json" >/dev/null 2>&1 && echo 0 || echo 1)"
cp "$NOTCHCLIP_DATA_DIR/claude-limits.json" "$work_dir/limits-before.json"
printf '%s' '{"model":{"display_name":"Sonnet"}}' | "$hooks/notchclip-statusline.sh" >/dev/null
expect "input without rate_limits keeps the limits file" "$(cmp -s "$work_dir/limits-before.json" "$NOTCHCLIP_DATA_DIR/claude-limits.json" && echo 0 || echo 1)"

# 2c. Chaining to a previous status line command.
chained="$(printf '%s' '{"model":{"display_name":"X"}}' | NOTCHCLIP_PREV_STATUSLINE='echo previous-line' "$hooks/notchclip-statusline.sh")"
expect "previous status line command output is printed" "$([ "$chained" = "previous-line" ] && echo 0 || echo 1)"

# 2d. Claude hook appends one compact line per event, without prompt text.
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"abc","cwd":"/Users/me/projects/demo","prompt":"SECRET PROMPT"}' | "$hooks/notchclip-hook.sh"
printf '%s' '{"hook_event_name":"Notification","session_id":"abc","cwd":"/Users/me/projects/demo","notification_type":"permission_prompt","message":"'"$(printf 'x%.0s' {1..300})"'"}' | "$hooks/notchclip-hook.sh"
printf '%s' '{"hook_event_name":"Stop","session_id":"abc","cwd":"/Users/me/projects/demo","transcript_path":"/secret/path"}' | "$hooks/notchclip-hook.sh"
printf '%s' '{"hook_event_name":"SessionEnd","session_id":"abc","cwd":"/Users/me/projects/demo"}' | "$hooks/notchclip-hook.sh"
log="$NOTCHCLIP_DATA_DIR/agents.jsonl"
expect "hook writes four lines" "$([ "$(wc -l < "$log" | tr -d ' ')" -eq 4 ] && echo 0 || echo 1)"
expect "first line is claude UserPromptSubmit" "$(sed -n 1p "$log" | jq -e '.source == "claude" and .event == "UserPromptSubmit" and .session == "abc" and .cwd == "/Users/me/projects/demo" and .type == null' >/dev/null 2>&1 && echo 0 || echo 1)"
expect "long message is truncated to 200 chars" "$(sed -n 2p "$log" | jq -e '.type == "permission_prompt" and (.message | length) == 200' >/dev/null 2>&1 && echo 0 || echo 1)"
expect "prompt text and transcript path are not stored" "$(grep -qE 'SECRET|transcript' "$log" && echo 1 || echo 0)"
expect "hook line carries epoch time" "$(sed -n 1p "$log" | jq -e '.time >= '$now >/dev/null 2>&1 && echo 0 || echo 1)"

# 2d-2. PostToolUse is recorded only right after a Notification in the same session.
before_post="$(wc -l < "$log" | tr -d ' ')"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"abc","cwd":"/Users/me/projects/demo","tool_name":"Bash"}' | "$hooks/notchclip-hook.sh"
expect "PostToolUse after SessionEnd is not written" "$([ "$(wc -l < "$log" | tr -d ' ')" -eq "$before_post" ] && echo 0 || echo 1)"
printf '%s' '{"hook_event_name":"Notification","session_id":"abc","cwd":"/Users/me/projects/demo","notification_type":"permission_prompt","message":"Allow Bash?"}' | "$hooks/notchclip-hook.sh"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"abc","cwd":"/Users/me/projects/demo","tool_name":"Bash"}' | "$hooks/notchclip-hook.sh"
expect "PostToolUse right after Notification is written" "$(tail -n 1 "$log" | jq -e '.event == "PostToolUse" and .session == "abc"' >/dev/null 2>&1 && echo 0 || echo 1)"
before_second="$(wc -l < "$log" | tr -d ' ')"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"abc","cwd":"/Users/me/projects/demo","tool_name":"Read"}' | "$hooks/notchclip-hook.sh"
expect "second PostToolUse in a row is not written" "$([ "$(wc -l < "$log" | tr -d ' ')" -eq "$before_second" ] && echo 0 || echo 1)"
printf '%s' '{"hook_event_name":"Notification","session_id":"other","cwd":"/Users/me/other","notification_type":"idle_prompt"}' | "$hooks/notchclip-hook.sh"
before_other="$(wc -l < "$log" | tr -d ' ')"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"abc","cwd":"/Users/me/projects/demo","tool_name":"Bash"}' | "$hooks/notchclip-hook.sh"
expect "a Notification in another session does not unlock PostToolUse" "$([ "$(wc -l < "$log" | tr -d ' ')" -eq "$before_other" ] && echo 0 || echo 1)"

# 2e. Codex notify wrapper runs the original command and records turn-complete.
marker="$work_dir/original-ran.txt"
cat > "$work_dir/fake-original.sh" <<EOF
#!/bin/bash
printf '%s' "\$1" > "$marker"
EOF
chmod 755 "$work_dir/fake-original.sh"
printf '%s\n' "[\"$work_dir/fake-original.sh\"]" | jq -c '.' > "$NOTCHCLIP_DATA_DIR/codex-notify-original.json"
codex_json='{"type":"agent-turn-complete","thread-id":"thr-1","cwd":"/Users/me/projects/codexdemo","last-assistant-message":"Done with the refactor"}'
"$hooks/codex-notify-wrapper.sh" "$codex_json"
for _ in $(seq 1 50); do [ -s "$marker" ] && break; sleep 0.1; done
expect "codex wrapper runs the original command with the JSON argument" "$([ "$(cat "$marker" 2>/dev/null)" = "$codex_json" ] && echo 0 || echo 1)"
expect "codex wrapper records turn-complete" "$(tail -n 1 "$log" | jq -e '.source == "codex" and .event == "turn-complete" and .session == "thr-1" and .message == "Done with the refactor"' >/dev/null 2>&1 && echo 0 || echo 1)"
long_codex='{"type":"agent-turn-complete","thread-id":"thr-2","cwd":"/x","last-assistant-message":"'"$(printf 'y%.0s' {1..150})"'"}'
"$hooks/codex-notify-wrapper.sh" "$long_codex"
expect "codex message is truncated to 120 chars" "$(tail -n 1 "$log" | jq -e '.session == "thr-2" and (.message | length) == 120' >/dev/null 2>&1 && echo 0 || echo 1)"

# 2f. Hooks never fail loudly, even on garbage input or with no jq output.
expect "hook exits 0 on garbage input" "$(printf 'not json' | "$hooks/notchclip-hook.sh" >/dev/null 2>&1; [ $? -eq 0 ] && echo 0 || echo 1)"
expect "statusline exits 0 on garbage input" "$(printf 'not json' | "$hooks/notchclip-statusline.sh" >/dev/null 2>&1; [ $? -eq 0 ] && echo 0 || echo 1)"
expect "codex wrapper exits 0 on garbage argument" "$("$hooks/codex-notify-wrapper.sh" 'not json' >/dev/null 2>&1; [ $? -eq 0 ] && echo 0 || echo 1)"

# 2g. Installer in a directory with a space: quoted command paths, idempotent, uninstall keeps user settings.
space_dir="$work_dir/with space"
mkdir -p "$space_dir"
space_dir="$(cd "$space_dir" && pwd)"  # same normalized form the installer computes
cp "$hooks"/*.sh "$space_dir/"
settings="$work_dir/settings.json"
config="$work_dir/config.toml"
printf '%s\n' '{"theme":"dark","statusLine":{"type":"command","command":"echo prev-status"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user-hook"}]}]}}' > "$settings"
printf '%s\n' 'model = "o3"' 'notify = ["/usr/bin/osascript"]' > "$config"
export NOTCHCLIP_CLAUDE_SETTINGS="$settings" NOTCHCLIP_CODEX_CONFIG="$config"
"$space_dir/setup-agent-hooks.sh" >/dev/null
expect "hook command is quoted and points at the script" "$(jq -e --arg c "\"$space_dir/notchclip-hook.sh\"" '[.hooks[][]?.hooks[]?.command] | index($c) != null' "$settings" >/dev/null 2>&1 && echo 0 || echo 1)"
expect "PostToolUse hook is installed" "$(jq -e '.hooks.PostToolUse | length == 1' "$settings" >/dev/null 2>&1 && echo 0 || echo 1)"
expect "statusLine points at the quoted wrapper and keeps the previous command" "$(jq -e --arg c "\"$NOTCHCLIP_DATA_DIR/notchclip-statusline-wrapper.sh\"" '.statusLine.command == $c' "$settings" >/dev/null 2>&1 && grep -q "prev-status" "$NOTCHCLIP_DATA_DIR/notchclip-statusline-wrapper.sh" && echo 0 || echo 1)"
expect "codex notify line uses the wrapper" "$(grep -q "notify = \[\"$space_dir/codex-notify-wrapper.sh\"\]" "$config" && echo 0 || echo 1)"
expect "codex original notify is kept in the data dir" "$(jq -e '. == ["/usr/bin/osascript"]' "$NOTCHCLIP_DATA_DIR/codex-notify-original.json" >/dev/null 2>&1 && echo 0 || echo 1)"
cp "$settings" "$work_dir/settings-installed.json"
"$space_dir/setup-agent-hooks.sh" >/dev/null
expect "second install changes nothing" "$(cmp -s "$settings" "$work_dir/settings-installed.json" && echo 0 || echo 1)"
"$space_dir/setup-agent-hooks.sh" --uninstall >/dev/null
expect "uninstall restores the previous statusLine command" "$(jq -e '.statusLine.command == "echo prev-status"' "$settings" >/dev/null 2>&1 && echo 0 || echo 1)"
expect "uninstall keeps the user's own Stop hook" "$(jq -e '.hooks.Stop[0].hooks[0].command == "echo user-hook"' "$settings" >/dev/null 2>&1 && echo 0 || echo 1)"
expect "uninstall removes NotchClip hook events and empty arrays" "$(jq -e '(.hooks | keys) == ["Stop"] and .theme == "dark"' "$settings" >/dev/null 2>&1 && echo 0 || echo 1)"
expect "uninstall restores the original codex notify line" "$(grep -qx 'notify = \["/usr/bin/osascript"\]' "$config" && ! grep -q codex-notify-wrapper "$config" && echo 0 || echo 1)"

# 2h. Fresh machine: uninstall removes everything it added and leaves the files as they were.
fresh_data="$work_dir/fresh-data"
fresh_settings="$work_dir/fresh-settings.json"
fresh_config="$work_dir/fresh-config.toml"
printf '%s\n' '{}' > "$fresh_settings"
printf '%s\n' 'model = "x"' > "$fresh_config"
NOTCHCLIP_DATA_DIR="$fresh_data" NOTCHCLIP_CLAUDE_SETTINGS="$fresh_settings" NOTCHCLIP_CODEX_CONFIG="$fresh_config" "$space_dir/setup-agent-hooks.sh" >/dev/null
NOTCHCLIP_DATA_DIR="$fresh_data" NOTCHCLIP_CLAUDE_SETTINGS="$fresh_settings" NOTCHCLIP_CODEX_CONFIG="$fresh_config" "$space_dir/setup-agent-hooks.sh" --uninstall >/dev/null
expect "fresh uninstall leaves settings.json empty" "$(jq -e '. == {}' "$fresh_settings" >/dev/null 2>&1 && echo 0 || echo 1)"
expect "fresh uninstall deletes the added notify line" "$(printf 'model = "x"\n' | cmp -s - "$fresh_config" && echo 0 || echo 1)"
unset NOTCHCLIP_CLAUDE_SETTINGS NOTCHCLIP_CODEX_CONFIG

# 2i. Syntax of the installer.
expect "setup script passes bash -n" "$(bash -n "$hooks/setup-agent-hooks.sh" && echo 0 || echo 1)"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all agent tests passed"
