#!/bin/bash
# Установщик Runie: окно с нашим фоном, приложение и ярлык «Программы».
#
#   scripts/make-dmg.sh dist/Runie.app 0.2.0 dist/releases/Runie-0.2.0.dmg
#
# Подпись берётся из RUNIE_SIGN_IDENTITY (по умолчанию «Runie Local Signing»).
set -euo pipefail

APP="${1:?путь к Runie.app}"
VERSION="${2:?версия}"
OUTPUT="${3:?куда положить .dmg}"

cd "$(dirname "$0")/.."
ROOT="$PWD"
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -o 'Developer ID Application: [^"]*' | head -1)"
IDENTITY="${RUNIE_SIGN_IDENTITY:-${DEVELOPER_ID:-Runie Local Signing}}"
VOLUME="Runie $VERSION"
STAGING="$(mktemp -d)/Runie"
RAW="$(mktemp -d)/runie-raw.dmg"

mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/Runie.app"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/assets/dmg-background.png" "$STAGING/.background/background.png"

# Образ для правки: Finder разложит иконки и запомнит вид.
hdiutil create -volname "$VOLUME" -srcfolder "$STAGING" -ov -format UDRW -fs "HFS+" "$RAW" >/dev/null
MOUNT="$(hdiutil attach "$RAW" -readwrite -noverify -noautoopen | grep -Eo '/Volumes/.*$' | head -1)"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT

# Вид окна: фон, крупные иконки, приложение слева, «Программы» справа.
osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    tell disk "$(basename "$MOUNT")"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 860, 560}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 110
        set text size of viewOptions to 12
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Runie.app" of container window to {170, 232}
        set position of item "Applications" of container window to {490, 232}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" -quiet
trap - EXIT

# Готовый сжатый образ.
rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
hdiutil convert "$RAW" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT" >/dev/null
rm -f "$RAW"

codesign --force --sign "$IDENTITY" "$OUTPUT" 2>/dev/null || echo "  (образ остался без подписи)"
echo "▸ Установщик: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
