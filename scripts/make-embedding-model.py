#!/usr/bin/env python3
"""Готовит модель смыслового поиска для памяти Руни.

Берёт статическую многоязычную модель sentence-transformers (Apache 2.0),
оставляет первые 256 измерений (она обучена с Matryoshka-потерей, поэтому
обрезка почти не теряет качества) и переводит веса в fp16: 434 МБ → 54 МБ.

Трансформера здесь нет: эмбеддинг фразы — среднее строк матрицы по токенам.
Поэтому приложению не нужен ни Core ML, ни сторонние библиотеки — только
matrix.bin и vocab.txt.

    python3 scripts/make-embedding-model.py dist/model
"""
import json
import struct
import sys
from pathlib import Path

import numpy as np
from huggingface_hub import hf_hub_download
from safetensors.numpy import load_file

REPO = "sentence-transformers/static-similarity-mrl-multilingual-v1"
DIMS = 256
MAGIC = b"RUNIEMB1"


def main(out_dir: Path) -> None:
    weights_path = hf_hub_download(REPO, "0_StaticEmbedding/model.safetensors")
    tokenizer_path = hf_hub_download(REPO, "0_StaticEmbedding/tokenizer.json")

    weights = load_file(weights_path)
    matrix = next(iter(weights.values())).astype(np.float32)
    matrix = matrix[:, :DIMS]

    tokenizer = json.load(open(tokenizer_path))
    model = tokenizer["model"]
    assert model["type"] == "WordPiece", model["type"]
    assert model["continuing_subword_prefix"] == "##"
    normalizer = tokenizer["normalizer"]
    assert normalizer["lowercase"] and normalizer["clean_text"], normalizer

    vocab = model["vocab"]
    tokens = [""] * len(vocab)
    for token, index in vocab.items():
        tokens[index] = token
    assert matrix.shape[0] == len(tokens), (matrix.shape, len(tokens))

    out_dir.mkdir(parents=True, exist_ok=True)
    # Шапка: магия, число измерений, число строк. Дальше — матрица fp16 подряд.
    with open(out_dir / "matrix.bin", "wb") as file:
        file.write(MAGIC)
        file.write(struct.pack("<II", DIMS, len(tokens)))
        file.write(matrix.astype(np.float16).tobytes())
    # Словарь: строка на токен, номер строки — его номер в матрице.
    (out_dir / "vocab.txt").write_text("\n".join(tokens), encoding="utf-8")

    sizes = {p.name: p.stat().st_size / 1e6 for p in out_dir.iterdir()}
    print("Готово:", ", ".join(f"{name} {size:.1f} МБ" for name, size in sorted(sizes.items())))
    print(f"Токенов: {len(tokens)}, измерений: {DIMS}, unk: {model['unk_token']}")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "dist/model"))
