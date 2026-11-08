#!/bin/bash
# NotchClip: установка хуков Claude Code и Codex для статуса агентов и лимитов.
# Использование: setup-agent-hooks.sh [--uninstall]
# Идемпотентно. Перед каждым изменением сохраняет копию: <файл>.notchclip-backup-<дата>.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
data_dir="${NOTCHCLIP_DATA_DIR:-$HOME/Library/Application Support/NotchClip}"
claude_settings="${NOTCHCLIP_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
codex_config="${NOTCHCLIP_CODEX_CONFIG:-$HOME/.codex/config.toml}"
statusline_script="$script_dir/notchclip-statusline.sh"
hook_script="$script_dir/notchclip-hook.sh"
codex_wrapper="$script_dir/codex-notify-wrapper.sh"
statusline_wrapper="$data_dir/notchclip-statusline-wrapper.sh"
codex_original="$data_dir/codex-notify-original.json"
stamp="$(date +%Y%m%d-%H%M%S)"

say() { printf '%s\n' "$*"; }

latest_backup() {
  ls -1 "$1".notchclip-backup-* 2>/dev/null | sort | tail -n 1
}

# Использование: replace_if_changed <файл> <новое содержимое>
# Возвращает 0, если файл изменён; 1, если содержимое уже совпадает.
replace_if_changed() {
  local file="$1" new="$2"
  if [ -f "$file" ] && cmp -s "$file" "$new"; then return 1; fi
  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ]; then
    local backup="$file.notchclip-backup-$stamp"
    if [ ! -e "$backup" ]; then
      cp -p "$file" "$backup" || { say "Не удалось создать резервную копию $backup — изменения отменены."; exit 1; }
      say "  резервная копия: $backup"
    fi
  fi
  cat "$new" > "$file"
  return 0
}

install_claude() {
  say "Claude Code: $claude_settings"
  local base='{}'
  if [ -f "$claude_settings" ]; then
    if ! jq -e 'type == "object"' "$claude_settings" >/dev/null 2>&1; then
      say "  пропущено: файл не является корректным JSON-объектом."
      return
    fi
    base="$(cat "$claude_settings")"
  fi

  local current status_cmd
  current="$(printf '%s' "$base" | jq -r '.statusLine.command // ""')"
  case "$current" in
    "")
      status_cmd="\"$statusline_script\""  # path may contain spaces
      ;;
    *notchclip-statusline*)
      status_cmd="$current" ;;
    *)
      mkdir -p "$data_dir"
      {
        printf '#!/bin/bash\n# Сгенерировано NotchClip: цепочка с прежней строкой статуса.\n'
        printf 'export NOTCHCLIP_PREV_STATUSLINE=%q\n' "$current"
        printf 'exec "%s" "$@"\n' "$statusline_script"
      } > "$statusline_wrapper"
      chmod 755 "$statusline_wrapper"
      status_cmd="\"$statusline_wrapper\""  # path contains a space
      say "  прежняя строка статуса сохранена в обёртке: $statusline_wrapper" ;;
  esac

  local events='["SessionStart","UserPromptSubmit","Notification","PostToolUse","Stop","SessionEnd"]'
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/notchclip-settings.XXXXXX")"
  printf '%s' "$base" | jq \
    --arg sl "$status_cmd" --arg hook "\"$hook_script\"" --argjson events "$events" '
    .statusLine = ((.statusLine // {}) + {type: "command", command: $sl})
    | .hooks = (.hooks // {})
    | reduce $events[] as $ev (.;
        if ((.hooks[$ev] // []) | [.[]? | .hooks[]? | (.command? // empty) | tostring]
            | any(contains("notchclip-hook")))
        then .
        else .hooks[$ev] = ((.hooks[$ev] // []) + [{hooks: [{type: "command", command: $hook}]}])
        end)' > "$tmp" || { say "  не удалось собрать settings.json"; rm -f "$tmp"; return; }

  if replace_if_changed "$claude_settings" "$tmp"; then
    say "  записано: statusLine и хуки SessionStart, UserPromptSubmit, Notification, PostToolUse, Stop, SessionEnd"
  else
    say "  уже настроено, изменений нет"
  fi
  rm -f "$tmp"
}

install_codex() {
  say "Codex: $codex_config"
  local line="notify = [\"$codex_wrapper\"]"
  local existing_line=""
  if [ -f "$codex_config" ]; then
    existing_line="$(grep -E '^[[:space:]]*notify[[:space:]]*=' "$codex_config" | head -n 1)"
  fi

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/notchclip-codex.XXXXXX")"

  if [ -z "$existing_line" ]; then
    { printf '%s\n' "$line"; [ -f "$codex_config" ] && cat "$codex_config"; } > "$tmp"
    say "  строка notify добавлена"
  elif printf '%s' "$existing_line" | grep -q 'codex-notify-wrapper'; then
    say "  уже настроено, изменений нет"
    rm -f "$tmp"; return
  else
    local value="${existing_line#*=}"
    if ! printf '%s' "$value" | jq -e 'type == "array" and all(type == "string")' >/dev/null 2>&1; then
      say "  пропущено: notify не похож на JSON-массив строк, исправьте вручную: $existing_line"
      rm -f "$tmp"; return
    fi
    mkdir -p "$data_dir"
    printf '%s' "$value" | jq -c . > "$codex_original"
    say "  исходная команда notify сохранена: $codex_original"
    NOTCHCLIP_NOTIFY_LINE="$line" awk '
      !done && /^[[:space:]]*notify[[:space:]]*=/ { print ENVIRON["NOTCHCLIP_NOTIFY_LINE"]; done = 1; next }
      { print }' "$codex_config" > "$tmp"
    say "  строка notify заменена на обёртку"
  fi

  if replace_if_changed "$codex_config" "$tmp"; then
    say "  config.toml обновлён"
  else
    say "  изменений нет"
  fi
  rm -f "$tmp"
}

# Previous status line command, decoded from the generated wrapper (empty if there is none).
prev_statusline() {
  [ -f "$statusline_wrapper" ] || return 0
  local line
  line="$(grep -m 1 '^export NOTCHCLIP_PREV_STATUSLINE=' "$statusline_wrapper" 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0
  bash -c 'eval "$1"; printf "%s" "${NOTCHCLIP_PREV_STATUSLINE:-}"' _ "$line" 2>/dev/null
}

# Removes only NotchClip entries; everything else in settings.json is kept. Backups are kept too.
uninstall_claude() {
  say "Claude Code: $claude_settings"
  if [ ! -f "$claude_settings" ]; then say "  файла нет, пропущено."; return; fi
  if ! jq -e 'type == "object"' "$claude_settings" >/dev/null 2>&1; then
    say "  пропущено: файл не является корректным JSON-объектом."; return
  fi
  local prev tmp
  prev="$(prev_statusline)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/notchclip-settings.XXXXXX")"
  if ! jq --arg prev "$prev" '
    def ours: ((.command? // "") | tostring | contains("notchclip-hook"));
    if (.hooks | type) == "object" then
      .hooks |= with_entries(
        .value |= [ .[] | (.hooks // []) as $h
          | ($h | map(select(ours | not))) as $kept
          | select(($h | length) == 0 or ($kept | length) > 0)
          | .hooks = $kept ]
      )
      | .hooks |= with_entries(select(.value | length > 0))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
    | if ((.statusLine.command? // "") | tostring | contains("notchclip-statusline")) then
        if $prev != "" then .statusLine.command = $prev else del(.statusLine) end
      else . end' "$claude_settings" > "$tmp" 2>/dev/null; then
    say "  не удалось собрать settings.json"; rm -f "$tmp"; return
  fi
  if replace_if_changed "$claude_settings" "$tmp"; then
    say "  удалены записи NotchClip (statusLine и хуки)"
  else
    say "  записей NotchClip нет, изменений нет"
  fi
  rm -f "$tmp"
}

# Puts the original notify command back, or removes our line when there was none.
uninstall_codex() {
  say "Codex: $codex_config"
  if [ ! -f "$codex_config" ]; then say "  файла нет, пропущено."; return; fi
  if ! grep -qE '^[[:space:]]*notify[[:space:]]*=.*codex-notify-wrapper' "$codex_config"; then
    say "  строки NotchClip нет, изменений нет"; return
  fi
  local restore_line="" original tmp
  if [ -f "$codex_original" ]; then
    original="$(jq -c . "$codex_original" 2>/dev/null)" || original=""
    [ -n "$original" ] && restore_line="notify = $original"
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/notchclip-codex.XXXXXX")"
  NOTCHCLIP_RESTORE_LINE="$restore_line" awk '
    !done && /^[[:space:]]*notify[[:space:]]*=/ && /codex-notify-wrapper/ {
      if (ENVIRON["NOTCHCLIP_RESTORE_LINE"] != "") print ENVIRON["NOTCHCLIP_RESTORE_LINE"]
      done = 1; next }
    { print }' "$codex_config" > "$tmp"
  if replace_if_changed "$codex_config" "$tmp"; then
    if [ -n "$restore_line" ]; then say "  notify возвращён из $codex_original"; else say "  строка notify NotchClip удалена"; fi
  else
    say "  изменений нет"
  fi
  rm -f "$tmp"
}

uninstall() {
  command -v jq >/dev/null 2>&1 || { say "Нужен jq (brew install jq)."; exit 1; }
  uninstall_claude
  uninstall_codex
  say "Резервные копии (*.notchclip-backup-*) сохранены."
}

case "${1:-}" in
  --uninstall) uninstall; exit 0 ;;
  "") ;;
  *) say "Неизвестный аргумент: $1 (допустимо только --uninstall)"; exit 1 ;;
esac

command -v jq >/dev/null 2>&1 || { say "Нужен jq (brew install jq)."; exit 1; }

chmod 755 "$statusline_script" "$hook_script" "$codex_wrapper" 2>/dev/null || true
mkdir -p "$data_dir"

install_claude
install_codex
say "Готово. Данные агентов: $data_dir"
