#!/bin/bash
# Создаёт локальный сертификат подписи «NotchClip Local Signing» в связке ключей входа.
# Стабильная подпись нужна, чтобы разрешения macOS (Полный доступ к диску) не слетали после обновлений.
# Скрипт идемпотентен: повторный запуск ничего не ломает.
set -euo pipefail

IDENTITY="NotchClip Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl

# Возвращает успех, если действующий (доверенный) identity для подписи кода уже есть.
valid_identity() {
  local out
  out="$(security find-identity -v -p codesigning)"
  case "$out" in
    *"${IDENTITY}"*) return 0 ;;
    *) return 1 ;;
  esac
}

if valid_identity; then
  echo "Сертификат «${IDENTITY}» уже есть и доверен. Ничего делать не нужно."
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/notchclip-sign.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if security find-certificate -c "${IDENTITY}" "${KEYCHAIN}" >/dev/null 2>&1; then
  echo "Сертификат «${IDENTITY}» уже есть в связке ключей, но не доверен. Добавляю доверие."
  security find-certificate -c "${IDENTITY}" -p "${KEYCHAIN}" > "$work/cert.pem"
else
  echo "Создаю самоподписанный сертификат на 10 лет..."
  cat > "$work/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no

[ dn ]
CN = NotchClip Local Signing

[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$work/openssl.cnf" -keyout "$work/key.pem" -out "$work/cert.pem"

  # OpenSSL 3 по умолчанию шифрует .p12 алгоритмами, которые macOS не понимает, поэтому нужен -legacy.
  # LibreSSL (системный openssl macOS) такого флага не знает и работает без него.
  legacy=""
  case "$("$OPENSSL" version)" in
    "OpenSSL 3"*) legacy="-legacy" ;;
  esac

  pw="$("$OPENSSL" rand -hex 16)"
  "$OPENSSL" pkcs12 -export $legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "${IDENTITY}" -out "$work/identity.p12" -passout "pass:$pw"

  echo "Импортирую в связку ключей «${KEYCHAIN}»..."
  security import "$work/identity.p12" -k "${KEYCHAIN}" -P "$pw" -T /usr/bin/codesign
fi

echo ""
echo "Сейчас macOS попросит пароль от связки ключей: это нужно, чтобы доверять сертификату для подписи кода."
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "$work/cert.pem"

echo ""
if valid_identity; then
  echo "Готово: сертификат «${IDENTITY}» установлен и доверен."
  echo "Теперь запусти ./scripts/install.sh, затем дай NotchClip Полный доступ к диску."
  echo "При первой подписи macOS может спросить доступ к ключу codesign: выбери «Всегда разрешать»."
else
  echo "Ошибка: сертификат «${IDENTITY}» не стал действительным для подписи кода." >&2
  echo "Открой «Связка ключей», удали сертификат «${IDENTITY}» и запусти скрипт снова." >&2
  exit 1
fi
