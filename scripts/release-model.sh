#!/bin/bash
# Выкладывает модель смыслового поиска по памяти в релизы GitHub.
#
#   scripts/release-model.sh
#
# Файлы готовит scripts/make-embedding-model.py. Тег отдельный от версий
# приложения: модель меняется редко, и обновление Runie не тащит за собой 55 МБ.
set -euo pipefail

cd "$(dirname "$0")/.."
TAG="model-1"
DIR="dist/model"

for file in matrix.bin vocab.txt; do
    [[ -f "$DIR/$file" ]] || { echo "Нет $DIR/$file — сначала scripts/make-embedding-model.py $DIR" >&2; exit 1; }
done

NOTES='Модель смыслового поиска по памяти Руни.

Статическая многоязычная модель [sentence-transformers/static-similarity-mrl-multilingual-v1](https://huggingface.co/sentence-transformers/static-similarity-mrl-multilingual-v1) (Apache 2.0): первые 256 измерений из 1024 и веса в fp16 — 434 МБ ужимаются до 54 МБ почти без потери качества.

Runie качает эти файлы по желанию человека и держит в `~/Library/Application Support/Runie/Model`. Всё считается на самом Mac.'

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "▸ Обновляю релиз $TAG"
    gh release upload "$TAG" "$DIR/matrix.bin" "$DIR/vocab.txt" --clobber
else
    echo "▸ Создаю релиз $TAG"
    gh release create "$TAG" "$DIR/matrix.bin" "$DIR/vocab.txt" \
        --title "Модель смыслового поиска" --notes "$NOTES"
fi
echo "▸ Готово: $(gh release view "$TAG" --json url --jq .url)"
