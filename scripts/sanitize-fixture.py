#!/usr/bin/env python3
"""Очищает сырой поток Claude Code перед тем, как положить его в тесты.

Событие system/init несёт всю установку того, кто снимал фикстуру: подключённые
MCP-серверы, список навыков (в том числе рабочих, с именами заказчиков), пути
плагинов в домашней папке, пути памяти. Хуки пользователя пишут в поток свой вывод.
Ничего из этого не должно попасть в открытый репозиторий.

Санитайзер сохраняет форму событий — ключи, типы, вложенность — и заменяет
содержимое нейтральным. Тесты проверяют разбор формы, а не чужую конфигурацию.

    scripts/sanitize-fixture.py raw.jsonl > Packages/RunieKit/Tests/RunieKitTests/Fixtures/name.jsonl

Скрипт падает с ненулевым кодом, если после очистки в выводе остался маркер
личных данных. Это не формальность: так он и нашёл то, что пропустили правила.
"""

import getpass
import json
import re
import sys

FIXTURE_ROOT = "/tmp/runie-fixture"
SESSION_ID = "11111111-1111-4111-8111-111111111111"

# Пути, которые надо переписать на нейтральный корень. Порядок важен: длинные первыми.
PATH_PATTERNS = [
    re.compile(r"/private/tmp/claude-\d+/[^\s\"']*?/scratchpad/fixture-work"),
    re.compile(r"/private/tmp/claude-\d+/[^\s\"']*"),
    re.compile(r"/Users/[^/\s\"']+"),
    re.compile(r"/home/[^/\s\"']+"),
]

GENERIC_TOOLS = ["Task", "Bash", "Glob", "Grep", "Read", "Edit", "Write", "WebFetch", "WebSearch"]

# Если любой из маркеров встретился в очищенном выводе — очистка не удалась.
FORBIDDEN_MARKERS = [
    "/Users/",
    "/home/",
    "/private/tmp/claude-",
    # Так выглядят обрывки путей в потоковых кусках и в именах временных папок.
    "-Users-",
    "claude.ai ",
    "@gmail",
    "@anthropic",
]

# Имя пользователя, который снимает фикстуру. Ловит утечки, которые не похожи
# на путь целиком: обрывки из потоковых событий, упоминания в тексте.
_user = getpass.getuser()
if len(_user) >= 3:
    FORBIDDEN_MARKERS.append(_user)


def scrub_string(value: str) -> str:
    for pattern in PATH_PATTERNS:
        value = pattern.sub(FIXTURE_ROOT, value)
    return value


def scrub(value):
    if isinstance(value, str):
        return scrub_string(value)
    if isinstance(value, list):
        return [scrub(item) for item in value]
    if isinstance(value, dict):
        return {key: scrub(item) for key, item in value.items()}
    return value


def sanitize_init(event: dict) -> dict:
    tools = event.get("tools")
    if isinstance(tools, list):
        event["tools"] = [tool for tool in GENERIC_TOOLS if tool in tools] or GENERIC_TOOLS[:3]
    if "mcp_servers" in event:
        event["mcp_servers"] = [{"name": "example", "status": "connected"}]
    if "slash_commands" in event:
        event["slash_commands"] = ["example-command"]
    if "terminal_slash_commands" in event:
        event["terminal_slash_commands"] = ["doctor"]
    if "skills" in event:
        event["skills"] = ["example-skill"]
    if "agents" in event:
        event["agents"] = ["general-purpose"]
    if "plugins" in event:
        event["plugins"] = [{"name": "example-plugin", "path": f"{FIXTURE_ROOT}/plugins/example-plugin"}]
    if "memory_paths" in event:
        event["memory_paths"] = {"auto": f"{FIXTURE_ROOT}/memory"}
    if "messaging_socket_path" in event:
        event["messaging_socket_path"] = f"{FIXTURE_ROOT}/agent.sock"
    return event


def sanitize_hook(event: dict) -> dict:
    for key in ("output", "stdout", "stderr"):
        if key in event:
            event[key] = "hook output\n" if event[key] else ""
    if "hook_name" in event:
        event["hook_name"] = "SessionStart:startup"
    return event


def sanitize_blocks(blocks):
    if not isinstance(blocks, list):
        return blocks
    for block in blocks:
        if isinstance(block, dict) and block.get("type") == "thinking":
            block["signature"] = "REDACTED"
    return blocks


def sanitize_stream_event(event: dict) -> dict:
    inner = event.get("event")
    if not isinstance(inner, dict):
        return event
    delta = inner.get("delta")
    # Аргументы инструмента приходят кусками JSON, порезанными где попало: путь
    # к файлу разваливается на обрывки, которые не узнать шаблоном. Тестам они
    # не нужны — полный ввод всё равно приходит в итоговом событии assistant.
    if isinstance(delta, dict) and delta.get("type") == "input_json_delta":
        delta["partial_json"] = ""
    return event


def sanitize(event: dict) -> dict:
    kind = event.get("type")
    subtype = event.get("subtype")

    if "session_id" in event:
        event["session_id"] = SESSION_ID

    if kind == "system" and subtype == "init":
        sanitize_init(event)
    elif kind == "system" and subtype in ("hook_started", "hook_response"):
        sanitize_hook(event)
    elif kind == "stream_event":
        sanitize_stream_event(event)
    elif kind in ("assistant", "user"):
        message = event.get("message")
        if isinstance(message, dict):
            sanitize_blocks(message.get("content"))

    return scrub(event)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    output_lines = []
    with open(sys.argv[1], encoding="utf-8") as source:
        for number, line in enumerate(source, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                print(f"строка {number}: не JSON, пропущена", file=sys.stderr)
                continue
            output_lines.append(json.dumps(sanitize(event), ensure_ascii=False, separators=(",", ":")))

    text = "\n".join(output_lines) + "\n"

    leaks = [marker for marker in FORBIDDEN_MARKERS if marker in text]
    if leaks:
        print(f"очистка не удалась, в выводе остались маркеры: {leaks}", file=sys.stderr)
        return 1

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
