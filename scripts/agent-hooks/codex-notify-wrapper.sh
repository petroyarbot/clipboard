#!/bin/bash
# NotchClip: программа notify для Codex.
# 1) Запускает исходную команду из codex-notify-original.json в фоне, отвязанно, с тем же JSON-аргументом.
# 2) Добавляет событие turn-complete в agents.jsonl.
# Никогда не падает и не блокирует: всегда exit 0.
set -u

data_dir="${NOTCHCLIP_DATA_DIR:-$HOME/Library/Application Support/NotchClip}"
original="$data_dir/codex-notify-original.json"
[ "$#" -gt 0 ] || exit 0

payload=""
for arg; do payload="$arg"; done

if command -v jq >/dev/null 2>&1 && [ -f "$original" ]; then
  cmd=()
  while IFS= read -r item; do cmd+=("$item"); done < <(jq -r '.[]' "$original" 2>/dev/null)
  if [ "${#cmd[@]}" -gt 0 ]; then
    nohup "${cmd[@]}" "$@" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi

command -v jq >/dev/null 2>&1 || exit 0
mkdir -p "$data_dir" 2>/dev/null || exit 0

line="$(printf '%s' "$payload" | jq -c --argjson now "$(date +%s)" '
  {
    source: "codex",
    event: "turn-complete",
    session: ((."thread-id" // .session_id // "") | tostring),
    cwd: ((.cwd // "") | tostring),
    message: ((."last-assistant-message" // "") | tostring | .[0:120]),
    time: $now
  }' 2>/dev/null)" || exit 0
[ -n "$line" ] || exit 0

log="$data_dir/agents.jsonl"
lock="$data_dir/.agents.lock"

if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
  rmdir "$lock" 2>/dev/null || true
fi

got_lock=0
tries=0
while [ "$tries" -lt 40 ]; do
  if mkdir "$lock" 2>/dev/null; then got_lock=1; break; fi
  tries=$((tries + 1))
  sleep 0.05
done

printf '%s\n' "$line" >> "$log" 2>/dev/null || true

if [ "$got_lock" -eq 1 ]; then
  count="$(wc -l < "$log" 2>/dev/null | tr -d ' ')"
  if [ "${count:-0}" -gt 2000 ]; then
    tail -n 1500 "$log" > "$log.tmp" 2>/dev/null && mv -f "$log.tmp" "$log" 2>/dev/null
  fi
  rmdir "$lock" 2>/dev/null || true
fi
exit 0
