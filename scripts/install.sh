#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
APP_SRC="$REPO/build/NotchClip.app"
APP_DST="/Applications/NotchClip.app"
BUNDLE_ID="app.notchclip.mac"

PULL=0
LOGIN=0
for arg in "$@"; do
  case "$arg" in
    --pull) PULL=1 ;;
    --login) LOGIN=1 ;;
    *)
      echo "Неизвестный аргумент: $arg" >&2
      echo "Использование: $0 [--pull] [--login]" >&2
      echo "  --pull   подтянуть последние изменения (git pull --ff-only) перед сборкой" >&2
      echo "  --login  включить запуск NotchClip при входе в систему" >&2
      exit 1
      ;;
  esac
done

if [ "$PULL" = 1 ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "Пропускаю обновление: есть незакоммиченные изменения."
  elif ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    echo "Пропускаю обновление: у ветки нет upstream."
  else
    echo "Обновляю репозиторий (git pull --ff-only)..."
    git pull --ff-only
  fi
fi

echo "Сборка приложения..."
./scripts/build-app.sh "$APP_SRC"

echo "Закрываю запущенный NotchClip..."
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  pgrep -x NotchClip >/dev/null 2>&1 || break
  sleep 1
done
if pgrep -x NotchClip >/dev/null 2>&1; then
  echo "Принудительно завершаю оставшиеся процессы..."
  pkill -x NotchClip || true
  sleep 1
fi
if pgrep -x NotchClip >/dev/null 2>&1; then
  echo "Ошибка: NotchClip всё ещё запущен. Заверши его вручную и повтори." >&2
  exit 1
fi

if [ -d /Volumes/NotchClip ]; then
  echo "Размонтирую /Volumes/NotchClip..."
  hdiutil detach /Volumes/NotchClip >/dev/null 2>&1 || echo "Предупреждение: не удалось размонтировать /Volumes/NotchClip." >&2
fi

echo "Установка в $APP_DST..."
rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"

if [ "$LOGIN" = 1 ]; then
  open "$APP_DST" --args --enable-login-item
else
  open "$APP_DST"
fi

PLIST="$APP_DST/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :NotchClipCommit' "$PLIST")"
echo "Готово: версия $VERSION (сборка $BUILD), коммит $COMMIT"
