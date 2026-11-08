#!/bin/bash
# NotchClip: statusLine для Claude Code.
# Пишет лимиты из stdin (.rate_limits) в claude-limits.json и печатает короткую строку.
# Если задана NOTCHCLIP_PREV_STATUSLINE, строку печатает прежняя команда статуса.
# Никогда не падает и не блокирует: всегда exit 0.
set -u

data_dir="${NOTCHCLIP_DATA_DIR:-$HOME/Library/Application Support/NotchClip}"
input="$(cat 2>/dev/null || true)"
prev="${NOTCHCLIP_PREV_STATUSLINE:-}"

if command -v jq >/dev/null 2>&1 && [ -n "$input" ]; then
  if printf '%s' "$input" | jq -e '.rate_limits' >/dev/null 2>&1; then
    now="$(date +%s)"
    mkdir -p "$data_dir" 2>/dev/null || true
    tmp="$(mktemp "$data_dir/.claude-limits.XXXXXX" 2>/dev/null)" || tmp=""
    if [ -n "$tmp" ]; then
      printf '%s' "$input" | jq -c --argjson now "$now" '
        def win:
          if type == "object" and (.used_percentage | type) == "number"
          then {used_percentage: .used_percentage,
                resets_at: (if (.resets_at | type) == "number" then .resets_at else null end)}
          else null end;
        {five_hour: (.rate_limits.five_hour | win),
         seven_day: (.rate_limits.seven_day | win),
         updated_at: $now}' > "$tmp" 2>/dev/null
      if [ -s "$tmp" ]; then
        mv -f "$tmp" "$data_dir/claude-limits.json" 2>/dev/null || true
      fi
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
fi

if [ -n "$prev" ]; then
  printf '%s' "$input" | bash -c "$prev" 2>/dev/null || true
  exit 0
fi

if command -v jq >/dev/null 2>&1 && [ -n "$input" ]; then
  line="$(printf '%s' "$input" | jq -r '
    [ (.model.display_name // empty),
      (if (.rate_limits.five_hour.used_percentage | type) == "number"
       then "5ч \(.rate_limits.five_hour.used_percentage | floor)%" else empty end),
      (if (.rate_limits.seven_day.used_percentage | type) == "number"
       then "нед \(.rate_limits.seven_day.used_percentage | floor)%" else empty end)
    ] | join(" · ")' 2>/dev/null)" || line=""
  [ -n "$line" ] && printf '%s\n' "$line"
fi
exit 0
