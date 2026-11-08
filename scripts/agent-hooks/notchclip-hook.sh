#!/bin/bash
# NotchClip: hook Claude Code (SessionStart, UserPromptSubmit, Notification, PostToolUse, Stop, SessionEnd).
# Добавляет одну компактную JSON-строку в agents.jsonl. Сохраняются: имя события, id сессии,
# папка проекта (cwd), тип уведомления и текст уведомления (поле message, обрезан до 200 символов).
# Промпты, ответы и пути транскриптов не сохраняются.
# PostToolUse пишется только если последнее событие этой сессии в последних 200 строках лога —
# Notification, т.е. агент продолжил работу после запроса. Иначе строка не добавляется.
# Никогда не падает и не блокирует: всегда exit 0.
set -u

data_dir="${NOTCHCLIP_DATA_DIR:-$HOME/Library/Application Support/NotchClip}"
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0
mkdir -p "$data_dir" 2>/dev/null || exit 0

line="$(printf '%s' "$input" | jq -c --argjson now "$(date +%s)" '
  {
    source: "claude",
    event: (.hook_event_name // ""),
    session: (.session_id // ""),
    cwd: (.cwd // ""),
    type: (.notification_type // null),
    message: ((.message // "") | tostring | .[0:200]),
    time: $now
  }' 2>/dev/null)" || exit 0
[ -n "$line" ] || exit 0

log="$data_dir/agents.jsonl"
lock="$data_dir/.agents.lock"

# PostToolUse fires on every tool call. Record it only when it resumes a session that is waiting after a Notification.
if [ "$(printf '%s' "$line" | jq -r '.event')" = "PostToolUse" ]; then
  session="$(printf '%s' "$line" | jq -r '.session')"
  last_event="$(tail -n 200 "$log" 2>/dev/null | jq -R -r --arg s "$session" \
    'fromjson? | select(type == "object" and .session == $s) | .event' 2>/dev/null | tail -n 1)"
  [ "$last_event" = "Notification" ] || exit 0
fi

# Снимаем зависший лок старше минуты.
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
