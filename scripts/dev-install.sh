#!/bin/bash
# Проверочная сборка: Release с подписью Developer ID — сразу в /Applications.
#
#   scripts/dev-install.sh
#
# Отладочная сборка подписана ad-hoc, и разрешения macOS (Универсальный доступ,
# запись экрана, полный доступ к диску) слетают после каждой пересборки. Эта
# ставится туда же, куда и выпуск, с той же подписью — разрешения сохраняются.
# Промежуточные копии снимаются с регистрации: иначе «Перезапустить» из
# Настроек macOS открывает не ту сборку.
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="$(security find-identity -v -p codesigning | grep -o 'Developer ID Application: [^"]*' | head -1)"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

xcodebuild -project Runie.xcodeproj -scheme Runie -configuration Release -derivedDataPath dist/build \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
    build > dist/build.log 2>&1 || { grep -E "error:" dist/build.log | grep -v DVTPlugIn | head; exit 1; }

rm -rf dist/Runie.app
cp -R dist/build/Build/Products/Release/Runie.app dist/Runie.app
find dist/Runie.app/Contents \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -name Autoupdate \) \
    | sort -r | while read -r item; do
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item" 2>/dev/null
    done
codesign --force --options runtime --timestamp --entitlements App/Runie.entitlements \
    --sign "$IDENTITY" dist/Runie.app 2>/dev/null

pkill -x Runie || true
sleep 2.5
rm -rf /Applications/Runie.app
cp -R dist/Runie.app /Applications/Runie.app
for copy in dist/Runie.app dist/build/Build/Products/Release/Runie.app; do
    "$LSR" -u "$PWD/$copy" 2>/dev/null || true
done
"$LSR" -f /Applications/Runie.app
open /Applications/Runie.app
echo "▸ Установлено в /Applications"
