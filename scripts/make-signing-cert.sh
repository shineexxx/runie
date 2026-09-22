#!/bin/bash
# Создаёт в связке ключей локальный сертификат «Runie Local Signing», которым
# подписывается отладочная сборка.
#
# Зачем: без постоянной подписи сборка подписывается «на лету», и после каждой
# пересборки macOS считает Runie новым приложением — заново спрашивает доступ к
# Загрузкам, Рабочему столу, Календарю. С постоянной подписью разрешение даётся
# один раз. Сертификат годится только для этого Mac.
#
# Сертификату нужно доверие системы: без него Связка ключей не может проверить,
# что перед ней то же самое приложение, и спрашивает пароль при каждом обращении
# к ключу — «Разрешать всегда» не помогает. Доверие ставится последним шагом, и
# на нём macOS один раз спросит пароль.
set -euo pipefail

NAME="Runie Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "Сертификат «$NAME» уже есть."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

PASS=$(openssl rand -hex 12)
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/runie.p12" \
    -passout "pass:$PASS" -name "$NAME" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/runie.p12" \
    -passout "pass:$PASS" -name "$NAME"
security import "$WORK/runie.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign

# Доверие только для подписи кода и только этому сертификату.
echo "Осталось доверить сертификат — macOS спросит пароль."
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Готово: «$NAME» в связке ключей и годен для подписи."
else
    echo "Сертификат добавлен, но система пока не считает его доверенным." >&2
    echo "Откройте «Связку ключей» → «Вход» → «Мои сертификаты» → $NAME → Доверие →" >&2
    echo "«Подписание кода» → «Всегда доверять»." >&2
fi
