#!/bin/bash
# Выпуск Runie: сборка, подпись, архив, appcast для Sparkle и релиз на GitHub.
#
#   scripts/release.sh 0.1.0            — собрать, выложить релиз и обновить appcast
#   scripts/release.sh 0.1.0 --dry-run  — всё то же, но без GitHub и без коммита
#
# Переменные окружения:
#   RUNIE_SIGN_IDENTITY   — чем подписывать. По умолчанию «Runie Local Signing».
#                           Для публичной раздачи: "Developer ID Application: Имя (TEAMID)".
#   RUNIE_NOTARY_PROFILE  — профиль notarytool. Если задан, сборка уходит на нотаризацию
#                           Apple и получает staple: тогда приложение открывается
#                           двойным щелчком без предупреждений.
set -euo pipefail

VERSION="${1:-}"
DRY_RUN="${2:-}"
if [[ -z "$VERSION" ]]; then
    echo "Использование: scripts/release.sh <версия> [--dry-run]" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Версия — три числа через точку, например 0.1.0" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
ROOT="$PWD"
# Подпись: если в Связке ключей есть Developer ID — берём его, иначе локальный сертификат.
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -o 'Developer ID Application: [^"]*' | head -1)"
IDENTITY="${RUNIE_SIGN_IDENTITY:-${DEVELOPER_ID:-Runie Local Signing}}"
DIST="$ROOT/dist"
RELEASES="$DIST/releases"
APP_NAME="Runie.app"
ZIP_NAME="Runie-$VERSION.zip"
DMG_NAME="Runie-$VERSION.dmg"
TAG="v$VERSION"
REPO_URL="https://github.com/shineexxx/runie"
# Номер сборки должен расти от выпуска к выпуску: Sparkle сравнивает именно его.
BUILD_NUMBER="$(git rev-list --count HEAD)"

echo "▸ Runie $VERSION (сборка $BUILD_NUMBER), подпись: $IDENTITY"

if [[ -n "$(git status --porcelain)" && "$DRY_RUN" != "--dry-run" ]]; then
    echo "Есть несохранённые изменения — сначала закоммитьте их." >&2
    exit 1
fi

# 1. Версия в проекте
/usr/bin/sed -i '' \
    -e "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $VERSION;/" \
    -e "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/" \
    Runie.xcodeproj/project.pbxproj

# 2. Тесты и сборка
echo "▸ Тесты RunieKit"
(cd Packages/RunieKit && swift test 2>&1 | tail -1)

echo "▸ Сборка Release"
rm -rf "$DIST/build" "$DIST/$APP_NAME"
mkdir -p "$RELEASES"
xcodebuild -project Runie.xcodeproj -scheme Runie -configuration Release \
    -derivedDataPath "$DIST/build" \
    CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
    build > "$DIST/build.log" 2>&1 || { tail -30 "$DIST/build.log"; exit 1; }
cp -R "$DIST/build/Build/Products/Release/$APP_NAME" "$DIST/$APP_NAME"

# 3. Подпись: сначала вложенное, потом само приложение.
echo "▸ Подпись"
if [[ "$IDENTITY" == Developer\ ID* ]]; then
    TIMESTAMP=(--timestamp)
else
    # Локальный сертификат не знает сервер меток времени Apple.
    TIMESTAMP=(--timestamp=none)
fi
# Обратный порядок путей ставит вложенное (XPC, Updater.app) раньше родителей.
while IFS= read -r item; do
    codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY" "$item" >/dev/null
done < <(find "$DIST/$APP_NAME/Contents" \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) | sort -r)
codesign --force --options runtime "${TIMESTAMP[@]}" \
    --entitlements App/Runie.entitlements --sign "$IDENTITY" "$DIST/$APP_NAME"
codesign --verify --deep --strict "$DIST/$APP_NAME" && echo "  подпись в порядке"

# 4. Нотаризация — только с Developer ID и профилем notarytool.
if [[ -n "${RUNIE_NOTARY_PROFILE:-}" ]]; then
    echo "▸ Нотаризация у Apple"
    ditto -c -k --keepParent "$DIST/$APP_NAME" "$DIST/notarize.zip"
    xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$RUNIE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DIST/$APP_NAME"
    rm -f "$DIST/notarize.zip"
fi

# 5. Архив для Sparkle
echo "▸ Архив $ZIP_NAME"
rm -f "$RELEASES/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$DIST/$APP_NAME" "$RELEASES/$ZIP_NAME"

# 6. appcast: подписывает архив ключом из Связки ключей и пишет XML.
echo "▸ appcast"
SPARKLE_BIN="$DIST/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || SPARKLE_BIN="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
# Прошлый appcast — чтобы записи о старых версиях остались.
rm -f "$RELEASES/appcast.xml"
[[ -s "$ROOT/appcast.xml" ]] && cp -f "$ROOT/appcast.xml" "$RELEASES/appcast.xml"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "$REPO_URL/releases/download/$TAG/" \
    --link "$REPO_URL" \
    --maximum-deltas 0 \
    "$RELEASES"
# 7. Установщик для людей: DMG с нашим оформлением.
RUNIE_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/make-dmg.sh" "$DIST/$APP_NAME" "$VERSION" "$RELEASES/$DMG_NAME"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
    # Ленту обновлений сухой прогон не трогает: в ней должно быть только то, что выложено.
    echo "▸ Сухой прогон: готово. $RELEASES/$DMG_NAME и $RELEASES/$ZIP_NAME"
    exit 0
fi
cp -f "$RELEASES/appcast.xml" "$ROOT/appcast.xml"

# 8. Релиз на GitHub и коммит версии с appcast
echo "▸ Релиз $TAG"
git add Runie.xcodeproj/project.pbxproj appcast.xml
git commit -m "Runie $VERSION" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git tag -f "$TAG"
git push origin HEAD
git push -f origin "$TAG"
# Первый запуск зависит от того, чем подписано: у Developer ID без нотаризации
# macOS просит открыть через меню, у локального сертификата — снять карантин.
if [[ "$IDENTITY" == Developer\ ID* && -z "${RUNIE_NOTARY_PROFILE:-}" ]]; then
    FIRST_RUN='**Первый запуск.** Приложение подписано сертификатом Developer ID, но ещё не прошло нотаризацию Apple,
поэтому macOS в первый раз скажет, что не может проверить разработчика. Откройте его через контекстное меню:
правый клик по Runie → «Открыть» → «Открыть». Дальше оно запускается обычным двойным щелчком.'
elif [[ "$IDENTITY" == Developer\ ID* ]]; then
    FIRST_RUN='**Первый запуск.** Приложение подписано и нотаризовано — просто откройте его двойным щелчком.'
else
    FIRST_RUN='**Первый запуск.** Приложение подписано локальным сертификатом, поэтому macOS сначала не даст его открыть.
Выполните в Терминале одну команду:

```
xattr -dr com.apple.quarantine /Applications/Runie.app
```'
fi

gh release create "$TAG" "$RELEASES/$DMG_NAME" "$RELEASES/$ZIP_NAME" \
    --title "Runie $VERSION" \
    --notes-file <(cat <<NOTES
Скачайте \`$DMG_NAME\`, откройте и перетащите Runie в «Программы».

$FIRST_RUN

Дальше Runie обновляется сам: новые версии он ставит без Терминала. Архив \`$ZIP_NAME\` — тот же
выпуск для самообновления, скачивать его вручную не нужно.

**Нужен Claude Code** с подпиской Claude. Если его нет, Runie предложит установить всё сам при первом запуске.
NOTES
)
echo "▸ Готово: $REPO_URL/releases/tag/$TAG"
