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

NOTES='Semantic search model for Runie memory.

A static multilingual model, [sentence-transformers/static-similarity-mrl-multilingual-v1](https://huggingface.co/sentence-transformers/static-similarity-mrl-multilingual-v1) (Apache 2.0): the first 256 of 1024 dimensions with fp16 weights, which shrinks 434 MB to 54 MB with almost no loss in quality.

Runie downloads these files only if the user agrees and keeps them in `~/Library/Application Support/Runie/Model`. Everything runs on the Mac itself.'

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "▸ Обновляю релиз $TAG"
    gh release upload "$TAG" "$DIR/matrix.bin" "$DIR/vocab.txt" --clobber
else
    echo "▸ Создаю релиз $TAG"
    gh release create "$TAG" "$DIR/matrix.bin" "$DIR/vocab.txt" \
        --title "Semantic search model" --notes "$NOTES"
fi
echo "▸ Готово: $(gh release view "$TAG" --json url --jq .url)"
