#!/usr/bin/env python3
"""Проверки телеграм-расширения без настоящего Telegram.

Обновления подсовываются такие же, какие присылает Bot API; отправка
подменяется заглушкой. Запуск:

    /usr/bin/python3 Extensions/Telegram/test-telegram.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "Packages", "RunieKit", "Sources", "RunieKit", "Resources", "telegram.py")

HOME = tempfile.mkdtemp(prefix="runie-telegram-test-")
os.environ["RUNIE_TELEGRAM_HOME"] = HOME
sys.path.insert(0, HERE)

import importlib.util

spec = importlib.util.spec_from_file_location("runie_telegram", SCRIPT)
tg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tg)

FAILED = []


def check(name, condition, detail=""):
    print(("  ✔ " if condition else "  ✘ ") + name + (("  — " + str(detail)) if not condition else ""))
    if not condition:
        FAILED.append(name)


NOW = int(time.time())


def connection_update():
    return {"business_connection": {
        "id": "conn-1",
        "user": {"id": 777, "first_name": "Арсений"},
        "user_chat_id": 777,
        "date": NOW,
        "is_enabled": True,
        "rights": {"can_reply": True},
    }}


def incoming(chat_id, name, text, seconds_ago=60, message_id=None, username=None):
    return {"business_message": {
        "business_connection_id": "conn-1",
        "message_id": message_id or (chat_id * 100 + seconds_ago),
        "date": NOW - seconds_ago,
        "chat": {"id": chat_id, "first_name": name, "username": username, "type": "private"},
        "from": {"id": chat_id, "first_name": name},
        "text": text,
    }}


def outgoing(chat_id, name, text, seconds_ago=30):
    message = incoming(chat_id, name, text, seconds_ago, message_id=chat_id * 100 + 900)
    message["business_message"]["from"] = {"id": 777, "first_name": "Арсений"}
    return message


print("Хранилище и разбор обновлений")
database = tg.connect()
tg.handle(database, connection_update())
check("подключение запомнилось", tg.get_state(database, "connection_id") == "conn-1")
check("право отвечать увидено", tg.get_state(database, "can_reply") == "1")

tg.handle(database, incoming(1001, "Александр", "Привет! Когда будет отчёт по RUN365?", 3600))
tg.handle(database, incoming(1001, "Александр", "И ещё: созвон в четверг?", 1800))
tg.handle(database, incoming(1002, "Аня", "Скинь фото со съёмки", 600, username="anya"))
tg.handle(database, incoming(1003, "Валентин", "Спасибо, получил", 300))
tg.handle(database, outgoing(1003, "Валентин", "Пожалуйста!", 200))

rows = database.execute("SELECT COUNT(*) AS n FROM messages").fetchone()["n"]
check("сообщения сохранены", rows == 5, rows)
check("чаты сохранены", database.execute("SELECT COUNT(*) AS n FROM chats").fetchone()["n"] == 3)

print("Сводка входящих")
inbox = tg.tool_inbox(database, {})
check("ждут ответа только двое", inbox.count("\n- ") == 2, inbox)
check("Валентин ушёл из ждущих (ему ответили)", "Валентин" not in inbox, inbox)
check("Александр на месте", "Александр" in inbox)
check("виден текст последнего сообщения", "созвон в четверг" in inbox, inbox)
check("все чаты видны без фильтра", tg.tool_inbox(database, {"waiting_only": False}).count("\n- ") == 3)

print("Переписка и поиск")
thread = tg.tool_thread(database, {"chat": "Александр"})
check("переписка по имени", "отчёт по RUN365" in thread, thread)
check("порядок от старых к новым", thread.index("отчёт") < thread.index("созвон"), thread)
check("по @нику тоже находится", "фото со съёмки" in tg.tool_thread(database, {"chat": "@anya"}))
check("по номеру чата тоже", "Спасибо" in tg.tool_thread(database, {"chat": "1003"}))
check("чужой чат — понятный ответ", "Не нашёл" in tg.tool_thread(database, {"chat": "Пётр"}))
check("поиск по слову", "RUN365" in tg.tool_search(database, {"query": "RUN365"}))
check("поиск без находок", "ничего нет" in tg.tool_search(database, {"query": "квартира"}))

print("Отправка")
sent = {}


def fake_call(method, wait=70, **parameters):
    sent.update(parameters)
    sent["method"] = method
    return {"message_id": 5555, "date": NOW, "chat": {"id": parameters.get("chat_id")}}, None


real_call = tg.call
tg.call = fake_call
answer = tg.tool_reply(database, {"chat": "Александр", "text": "Отчёт будет завтра к обеду."})
check("ушло в нужный чат", sent.get("chat_id") == 1001, sent)
check("от имени человека", sent.get("business_connection_id") == "conn-1", sent)
check("метод Bot API", sent.get("method") == "sendMessage", sent)
check("понятный ответ", "Отправил" in answer, answer)
check("чат больше не ждёт ответа", "Александр" not in tg.tool_inbox(database, {}))
check("пустой текст не отправляется", "Пустое" in tg.tool_reply(database, {"chat": "Аня", "text": "  "}))

tg.call = lambda method, wait=70, **parameters: (None, "Bad Request: CHAT_WRITE_FORBIDDEN")
check("ошибка Telegram объясняется", "Не отправилось" in tg.tool_reply(database, {"chat": "Аня", "text": "привет"}))
tg.call = real_call

print("Автозапуск")
calls = []
tg.launchctl = lambda *arguments: (calls.append(arguments), False)[1]
tg.daemon_running = lambda: False
# Ни настоящую автозагрузку, ни Связку ключей проверка не трогает.
tg.AGENT = os.path.join(HOME, "app.runie.telegram.plist")
tg.INSTALLED_SCRIPT = os.path.join(HOME, "runie-telegram.py")
os.environ["TELEGRAM_BOT_TOKEN"] = "111:test"
real_run = tg.subprocess.run
tg.subprocess.run = lambda *a, **k: real_run(["/usr/bin/true"], capture_output=True)
report = tg.install()
check("скрипт скопирован в рабочую папку", os.path.exists(tg.INSTALLED_SCRIPT))
check("демон прописан в автозапуск", os.path.exists(tg.AGENT))
plist = open(tg.AGENT).read()
check("в автозапуске правильный режим", "<string>daemon</string>" in plist, plist)
check("демон переживает падение", "<key>KeepAlive</key><true/>" in plist)
check("launchctl звали", any("bootstrap" in call for call in calls), calls)
check("отчёт про незапустившийся демон понятен", "не запустился" in report, report)
tg.subprocess.run = real_run

print("Удаление и состояние")
tg.handle(database, {"deleted_business_messages": {"chat": {"id": 1002}, "message_ids": [1002 * 100 + 600]}})
check("удалённое исчезло", "фото со съёмки" not in tg.tool_thread(database, {"chat": "Аня"}))
status = tg.tool_status(database, {})
check("состояние показывает аккаунт", "Арсений" in status, status)
check("состояние показывает право отвечать", "Право отвечать: есть" in status, status)

print("Протокол MCP")
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
     "params": {"name": "telegram_inbox", "arguments": {"waiting_only": False}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "telegram_nope", "arguments": {}}},
]
process = subprocess.run(
    ["/usr/bin/python3", SCRIPT, "mcp"],
    input="\n".join(json.dumps(request) for request in requests) + "\n",
    capture_output=True, text=True, timeout=60,
    env=dict(os.environ, RUNIE_TELEGRAM_HOME=HOME),
)
replies = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
check("ответов ровно на запросы с id", len(replies) == 4, process.stdout + process.stderr)
check("initialize отвечает возможностями", replies[0]["result"]["capabilities"] == {"tools": {}}, replies[0])
names = [tool["name"] for tool in replies[1]["result"]["tools"]]
check("инструменты перечислены", "telegram_inbox" in names and "telegram_reply" in names, names)
check("у инструментов есть схема", all("inputSchema" in tool for tool in replies[1]["result"]["tools"]))
check("вызов вернул сводку", "Александр" in replies[2]["result"]["content"][0]["text"], replies[2])
check("неизвестный инструмент — ошибка, а не падение", replies[3]["result"].get("isError") is True, replies[3])

shutil.rmtree(HOME, ignore_errors=True)
print()
if FAILED:
    print("Не прошло: " + ", ".join(FAILED))
    sys.exit(1)
print("Всё прошло.")
