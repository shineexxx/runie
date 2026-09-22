#!/usr/bin/env python3
"""Телеграм для Руни: читает личную переписку и отвечает от имени человека.

Работает через Telegram Business: человек с Premium подключает своего бота к
личному аккаунту, и бот видит переписку в тех чатах, которые человек выбрал,
и пишет в них от его имени.

Один файл, несколько режимов:

    runie-telegram.py mcp      — MCP-сервер для Руни: читает базу и отправляет
                                 ответы. Запускается на время запроса.
    runie-telegram.py daemon   — опрашивает Telegram и складывает сообщения в SQLite.
                                 Запускается launchd, работает без открытого Runie.
    runie-telegram.py install  — прописывает демон в автозапуск (это делает Руни сам).
    runie-telegram.py disable  — останавливает сбор, ничего не удаляя.
    runie-telegram.py enable   — включает обратно.
    runie-telegram.py status   — что сейчас с демоном.
    runie-telegram.py remove   — убрать демон, ключ и всю накопленную переписку.

Опрашивать Telegram имеет право только демон: два процесса с getUpdates
отбирают обновления друг у друга.

Ключ бота в файлах не хранится: демон берёт его из Связки ключей, а
MCP-серверу его передаёт сам Runie через переменную окружения.

Только стандартная библиотека: никаких pip, venv и обновлений зависимостей.
"""

import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.telegram.org/bot{token}/{method}"
# Ключ бота. MCP-серверу его передаёт сам Runie переменной окружения (её имя
# складывается из имени сервера и переменной), а демон берёт его из Связки
# ключей: установщик кладёт туда отдельную запись, к которой сразу открыт
# доступ `security` — иначе macOS спрашивал бы разрешение при каждом запуске.
SECRET_VARIABLE = "RUNIE_SECRET_TELEGRAM_BOT_TOKEN"
KEYCHAIN_SERVICE = "app.runie.telegram"
KEYCHAIN_ACCOUNT = "bot-token"
# Задел под облачную версию: в базе с самого начала несколько аккаунтов.
ACCOUNT = os.environ.get("RUNIE_TELEGRAM_ACCOUNT", "default")

HOME = os.path.expanduser("~")
# Папку можно подменить: так гоняются проверки и так же будет жить облачная версия.
ROOT = os.environ.get("RUNIE_TELEGRAM_HOME") or os.path.join(
    HOME, "Library", "Application Support", "Runie", "Telegram")
DATABASE = os.path.join(ROOT, "messages.db")
LOG = os.path.join(ROOT, "daemon.log")


# MARK: Хранилище


SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
    account       TEXT    NOT NULL,
    chat_id       INTEGER NOT NULL,
    message_id    INTEGER NOT NULL,
    connection_id TEXT    NOT NULL,
    date          INTEGER NOT NULL,
    outgoing      INTEGER NOT NULL,
    text          TEXT    NOT NULL DEFAULT '',
    kind          TEXT,
    answered      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account, chat_id, message_id)
);
CREATE INDEX IF NOT EXISTS messages_by_date ON messages (account, date);
CREATE TABLE IF NOT EXISTS chats (
    account       TEXT    NOT NULL,
    chat_id       INTEGER NOT NULL,
    title         TEXT    NOT NULL DEFAULT '',
    username      TEXT,
    connection_id TEXT    NOT NULL DEFAULT '',
    PRIMARY KEY (account, chat_id)
);
CREATE TABLE IF NOT EXISTS state (
    account TEXT NOT NULL,
    key     TEXT NOT NULL,
    value   TEXT NOT NULL,
    PRIMARY KEY (account, key)
);
"""


def connect():
    os.makedirs(ROOT, mode=0o700, exist_ok=True)
    database = sqlite3.connect(DATABASE, timeout=10)
    database.row_factory = sqlite3.Row
    database.executescript(SCHEMA)
    return database


def get_state(database, key, default=None):
    row = database.execute(
        "SELECT value FROM state WHERE account = ? AND key = ?", (ACCOUNT, key)
    ).fetchone()
    return row["value"] if row else default


def set_state(database, key, value):
    database.execute(
        "INSERT INTO state (account, key, value) VALUES (?, ?, ?) "
        "ON CONFLICT (account, key) DO UPDATE SET value = excluded.value",
        (ACCOUNT, key, str(value)),
    )
    database.commit()


# MARK: Telegram


def token_from_keychain():
    """Ключ бота из Связки ключей — так его берёт демон."""
    try:
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-w",
             "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def token():
    """Из окружения (так ключ передаёт Runie) или из Связки ключей (так живёт демон)."""
    return os.environ.get(SECRET_VARIABLE) or os.environ.get("TELEGRAM_BOT_TOKEN") or token_from_keychain()


def call(method, wait=70, **parameters):
    """Вызов Bot API. `wait` — сколько ждать ответа. Возвращает (результат, ошибка)."""
    key = token()
    if not key:
        return None, "не найден ключ бота: подключите Телеграм заново через Руни"
    payload = json.dumps({k: v for k, v in parameters.items() if v is not None}).encode()
    request = urllib.request.Request(
        API.format(token=key, method=method),
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=wait) as response:
            body = json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        try:
            body = json.loads(error.read().decode())
        except Exception:
            return None, "Telegram ответил {}".format(error.code)
        return None, body.get("description", "Telegram ответил {}".format(error.code))
    except Exception as error:  # сеть отвалилась — не падаем, попробуем снова
        return None, str(error)
    if not body.get("ok"):
        return None, body.get("description", "неизвестная ошибка")
    return body.get("result"), None


# MARK: Демон


def describe_kind(message):
    """Что пришло, если это не текст."""
    for field, name in (
        ("photo", "фото"), ("video", "видео"), ("voice", "голосовое"),
        ("video_note", "кружок"), ("audio", "аудио"), ("document", "файл"),
        ("sticker", "стикер"), ("location", "геопозиция"), ("contact", "контакт"),
        ("poll", "опрос"), ("story", "история"),
    ):
        if message.get(field):
            return name
    return None


def chat_title(chat):
    parts = [chat.get("first_name"), chat.get("last_name")]
    name = " ".join(part for part in parts if part)
    return name or chat.get("title") or chat.get("username") or str(chat.get("id"))


def store_message(database, message, connection_id, my_id):
    chat = message.get("chat") or {}
    chat_id = chat.get("id")
    if chat_id is None:
        return
    sender = (message.get("from") or {}).get("id")
    outgoing = 1 if sender == my_id else 0
    database.execute(
        "INSERT INTO chats (account, chat_id, title, username, connection_id) VALUES (?, ?, ?, ?, ?) "
        "ON CONFLICT (account, chat_id) DO UPDATE SET title = excluded.title, "
        "username = excluded.username, connection_id = excluded.connection_id",
        (ACCOUNT, chat_id, chat_title(chat), chat.get("username"), connection_id),
    )
    database.execute(
        "INSERT OR REPLACE INTO messages "
        "(account, chat_id, message_id, connection_id, date, outgoing, text, kind, answered) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)",
        (ACCOUNT, chat_id, message.get("message_id"), connection_id,
         message.get("date") or int(time.time()), outgoing,
         message.get("text") or message.get("caption") or "", describe_kind(message)),
    )
    # Ответил сам с телефона — входящие в этом чате больше не ждут ответа.
    if outgoing:
        database.execute(
            "UPDATE messages SET answered = 1 WHERE account = ? AND chat_id = ? AND outgoing = 0",
            (ACCOUNT, chat_id),
        )
    database.commit()


def handle(database, update):
    if "business_connection" in update:
        connection = update["business_connection"]
        user = connection.get("user") or {}
        set_state(database, "connection_id", connection.get("id") or "")
        set_state(database, "my_id", user.get("id") or "")
        set_state(database, "my_name", chat_title(user))
        set_state(database, "enabled", 1 if connection.get("is_enabled", True) else 0)
        rights = connection.get("rights") or {}
        set_state(database, "can_reply", 1 if rights.get("can_reply", connection.get("can_reply", False)) else 0)
        return
    for field in ("business_message", "edited_business_message"):
        message = update.get(field)
        if message:
            my_id = get_state(database, "my_id")
            store_message(
                database, message,
                message.get("business_connection_id") or get_state(database, "connection_id", ""),
                int(my_id) if my_id else None,
            )
    deleted = update.get("deleted_business_messages")
    if deleted:
        chat_id = (deleted.get("chat") or {}).get("id")
        for message_id in deleted.get("message_ids") or []:
            database.execute(
                "DELETE FROM messages WHERE account = ? AND chat_id = ? AND message_id = ?",
                (ACCOUNT, chat_id, message_id),
            )
        database.commit()


def log(text):
    line = "{} {}\n".format(time.strftime("%Y-%m-%d %H:%M:%S"), text)
    try:
        with open(LOG, "a") as file:
            file.write(line)
    except OSError:
        pass


def daemon():
    """Долгий опрос Telegram. Живёт под launchd, переживает сон и обрыв сети."""
    database = connect()
    log("демон запущен")
    if not token():
        log("нет ключа бота — жду, пока его заведут")
    failures = 0
    while True:
        offset = get_state(database, "offset")
        updates, error = call(
            "getUpdates",
            wait=70,
            # Долгий опрос: Telegram держит соединение до минуты и отдаёт сразу,
            # как только что-то пришло.
            timeout=50,
            offset=int(offset) + 1 if offset else None,
            allowed_updates=["business_connection", "business_message",
                             "edited_business_message", "deleted_business_messages"],
        )
        if error:
            failures += 1
            # Сеть или сон: ждём всё дольше, но не больше минуты.
            delay = min(60, 2 ** min(failures, 6))
            log("опрос не удался ({}), жду {} с".format(error, delay))
            time.sleep(delay)
            continue
        failures = 0
        for update in updates or []:
            try:
                handle(database, update)
            except Exception as failure:  # одно кривое обновление не роняет демон
                log("обновление пропущено: {}".format(failure))
            set_state(database, "offset", update.get("update_id"))
        set_state(database, "last_poll", int(time.time()))


# MARK: Автозапуск


LABEL = "app.runie.telegram"
AGENT = os.path.join(HOME, "Library", "LaunchAgents", LABEL + ".plist")
INSTALLED_SCRIPT = os.path.join(ROOT, "runie-telegram.py")

PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>{script}</string>
        <string>daemon</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>
"""


def launchctl(*arguments):
    try:
        result = subprocess.run(["/bin/launchctl"] + list(arguments),
                                capture_output=True, text=True, timeout=30)
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def daemon_running():
    return launchctl("print", "gui/{}/{}".format(os.getuid(), LABEL))


def install(quiet=False):
    """Кладёт ключ в Связку ключей, прописывает демон в автозапуск и поднимает его."""
    key = os.environ.get(SECRET_VARIABLE) or os.environ.get("TELEGRAM_BOT_TOKEN")
    if not key and not token_from_keychain():
        return "Нет ключа бота: сначала подключите сервис telegram через Руни."
    os.makedirs(ROOT, mode=0o700, exist_ok=True)
    os.makedirs(os.path.dirname(AGENT), exist_ok=True)
    if key:
        # Отдельная запись для демона: `-T /usr/bin/security` заранее открывает к ней
        # доступ, иначе macOS спрашивал бы разрешение при каждом запуске.
        subprocess.run(["/usr/bin/security", "add-generic-password", "-U",
                        "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w", key,
                        "-l", "Runie — Телеграм", "-T", "/usr/bin/security"],
                       capture_output=True, timeout=30)
    source = os.path.abspath(__file__)
    if source != INSTALLED_SCRIPT:
        with open(source) as file:
            body = file.read()
        with open(INSTALLED_SCRIPT, "w") as file:
            file.write(body)
        os.chmod(INSTALLED_SCRIPT, 0o755)
    with open(AGENT, "w") as file:
        file.write(PLIST.format(label=LABEL, script=INSTALLED_SCRIPT, log=LOG))
    target = "gui/{}/{}".format(os.getuid(), LABEL)
    launchctl("bootout", target)
    launchctl("bootstrap", "gui/{}".format(os.getuid()), AGENT)
    time.sleep(1.5)
    if daemon_running():
        return "Демон поставлен: переписка собирается, пока включён компьютер."
    return "Демон прописан, но не запустился — посмотрите {}.".format(LOG)


def disable():
    """Останавливает сбор переписки, но ничего не удаляет: ключ и накопленное на месте."""
    launchctl("bootout", "gui/{}/{}".format(os.getuid(), LABEL))
    try:
        os.remove(AGENT)
    except OSError:
        pass
    return "Сбор переписки выключен. Накопленное осталось на месте."


def remove():
    launchctl("bootout", "gui/{}/{}".format(os.getuid(), LABEL))
    for path in (AGENT,):
        try:
            os.remove(path)
        except OSError:
            pass
    subprocess.run(["/usr/bin/security", "delete-generic-password",
                    "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT],
                   capture_output=True, timeout=30)
    import shutil
    shutil.rmtree(ROOT, ignore_errors=True)
    return "Демон убран, ключ и накопленная переписка удалены."


# MARK: Инструменты для Руни


def find_chat(database, needle):
    """Чат по имени, @нику или номеру. Возвращает строку или None."""
    needle = (needle or "").strip().lstrip("@")
    if not needle:
        return None
    if needle.lstrip("-").isdigit():
        row = database.execute(
            "SELECT * FROM chats WHERE account = ? AND chat_id = ?", (ACCOUNT, int(needle))
        ).fetchone()
        if row:
            return row
    return database.execute(
        "SELECT * FROM chats WHERE account = ? AND (title LIKE ? OR username LIKE ?) "
        "ORDER BY length(title) LIMIT 1",
        (ACCOUNT, "%" + needle + "%", "%" + needle + "%"),
    ).fetchone()


def when(timestamp):
    now = time.time()
    if now - timestamp < 86400:
        return time.strftime("%H:%M", time.localtime(timestamp))
    return time.strftime("%d.%m %H:%M", time.localtime(timestamp))


def tool_status(database, arguments):
    # Первый вызов после подключения сервиса: ключ уже у нас в окружении, можно
    # сразу поставить демон — человеку не нужно ничего делать в терминале.
    setup = ""
    if not daemon_running() and not os.path.exists(AGENT):
        # Первый вызов после подключения: ключ уже в окружении, ставим службу сама.
        # Если человек выключил её нарочно (файла автозапуска нет, но и включать
        # не просили) — это тот же случай, поэтому включаем только пока сервер
        # вообще включён в Руни: отключённый сервер сюда не попадает.
        setup = install() + "\n"
    elif not daemon_running():
        setup = "Служба сбора не запущена — попробуйте включить её заново.\n"
    connection = get_state(database, "connection_id")
    last = get_state(database, "last_poll")
    chats = database.execute("SELECT COUNT(*) AS n FROM chats WHERE account = ?", (ACCOUNT,)).fetchone()["n"]
    messages = database.execute("SELECT COUNT(*) AS n FROM messages WHERE account = ?", (ACCOUNT,)).fetchone()["n"]
    if not connection:
        return setup + ("Бот пока не подключён к аккаунту. В Телеграме: Настройки → Телеграм для бизнеса → "
                        "Чат-боты → укажите бота и выберите чаты.")
    lines = [
        "Аккаунт: {}".format(get_state(database, "my_name", "—")),
        "Подключение: {}".format("включено" if get_state(database, "enabled") == "1" else "выключено"),
        "Право отвечать: {}".format("есть" if get_state(database, "can_reply") == "1" else "нет"),
        "Чатов: {}, сообщений: {}".format(chats, messages),
    ]
    if last:
        delta = int(time.time()) - int(last)
        lines.append("Последний опрос: {} назад".format(
            "{} с".format(delta) if delta < 90 else "{} мин".format(delta // 60)))
    else:
        lines.append("Опроса ещё не было — проверьте, запущен ли демон.")
    return setup + "\n".join(lines)


def tool_inbox(database, arguments):
    hours = int(arguments.get("hours") or 24)
    waiting = arguments.get("waiting_only", True)
    since = int(time.time()) - hours * 3600
    rows = database.execute(
        "SELECT c.chat_id, c.title, c.username, "
        "       COUNT(*) AS count, MAX(m.date) AS last, "
        "       SUM(CASE WHEN m.answered = 0 THEN 1 ELSE 0 END) AS waiting "
        "FROM messages m JOIN chats c ON c.chat_id = m.chat_id AND c.account = m.account "
        "WHERE m.account = ? AND m.outgoing = 0 AND m.date >= ? "
        "GROUP BY c.chat_id ORDER BY last DESC",
        (ACCOUNT, since),
    ).fetchall()
    if waiting:
        rows = [row for row in rows if row["waiting"]]
    if not rows:
        return "За последние {} ч новых сообщений нет.".format(hours)
    lines = []
    for row in rows:
        last = database.execute(
            "SELECT text, kind, date FROM messages WHERE account = ? AND chat_id = ? AND outgoing = 0 "
            "ORDER BY date DESC LIMIT 1", (ACCOUNT, row["chat_id"])
        ).fetchone()
        preview = (last["text"] or "").replace("\n", " ")
        if len(preview) > 120:
            preview = preview[:119] + "…"
        if not preview and last["kind"]:
            preview = "[{}]".format(last["kind"])
        name = row["title"] + (" (@{})".format(row["username"]) if row["username"] else "")
        lines.append("{} — {} сообщ., {}: {}".format(name, row["count"], when(row["last"]), preview))
    header = "Ждут ответа ({}):".format(len(lines)) if waiting else "Новое за {} ч:".format(hours)
    return header + "\n" + "\n".join("- " + line for line in lines)


def tool_thread(database, arguments):
    chat = find_chat(database, arguments.get("chat"))
    if not chat:
        return "Не нашёл такой чат. Посмотрите список в telegram_inbox."
    limit = min(int(arguments.get("limit") or 30), 200)
    rows = database.execute(
        "SELECT * FROM messages WHERE account = ? AND chat_id = ? ORDER BY date DESC LIMIT ?",
        (ACCOUNT, chat["chat_id"], limit),
    ).fetchall()
    if not rows:
        return "В этом чате пока ничего не накопилось."
    lines = []
    name = get_state(database, "my_name", "Я")
    for row in reversed(rows):
        who = name if row["outgoing"] else chat["title"]
        text = row["text"] or ("[{}]".format(row["kind"]) if row["kind"] else "")
        lines.append("[{}] {}: {}".format(when(row["date"]), who, text))
    return "Переписка с {} (последние {}):\n".format(chat["title"], len(lines)) + "\n".join(lines)


def tool_search(database, arguments):
    query = (arguments.get("query") or "").strip()
    if not query:
        return "Нечего искать."
    rows = database.execute(
        "SELECT m.*, c.title FROM messages m JOIN chats c ON c.chat_id = m.chat_id AND c.account = m.account "
        "WHERE m.account = ? AND m.text LIKE ? ORDER BY m.date DESC LIMIT 20",
        (ACCOUNT, "%" + query + "%"),
    ).fetchall()
    if not rows:
        return "По запросу «{}» в переписке ничего нет.".format(query)
    name = get_state(database, "my_name", "Я")
    lines = ["[{}] {} → {}: {}".format(
        when(row["date"]), name if row["outgoing"] else row["title"],
        "" if row["outgoing"] else name, row["text"]) for row in rows]
    return "Нашёл {}:\n".format(len(rows)) + "\n".join(lines)


def tool_reply(database, arguments):
    chat = find_chat(database, arguments.get("chat"))
    if not chat:
        return "Не нашёл такой чат. Посмотрите список в telegram_inbox."
    text = (arguments.get("text") or "").strip()
    if not text:
        return "Пустое сообщение отправлять не буду."
    connection = chat["connection_id"] or get_state(database, "connection_id", "")
    if not connection:
        return "Бот не подключён к аккаунту — отправлять не от кого."
    result, error = call(
        "sendMessage",
        business_connection_id=connection,
        chat_id=chat["chat_id"],
        text=text,
    )
    if error:
        return "Не отправилось: {}".format(error)
    # Своё же сообщение кладём в базу сразу: демон узнает о нём с задержкой,
    # а в сводке чат должен перестать ждать ответа немедленно.
    my_id = int(get_state(database, "my_id") or 0)
    store_message(database, {
        "chat": {"id": chat["chat_id"], "first_name": chat["title"], "username": chat["username"]},
        "from": {"id": my_id},
        "message_id": (result or {}).get("message_id", int(time.time())),
        "date": (result or {}).get("date", int(time.time())),
        "text": text,
    }, connection, my_id)
    return "Отправил {}: {}".format(chat["title"], text)


def tool_mark_answered(database, arguments):
    chat = find_chat(database, arguments.get("chat"))
    if not chat:
        return "Не нашёл такой чат."
    database.execute(
        "UPDATE messages SET answered = 1 WHERE account = ? AND chat_id = ? AND outgoing = 0",
        (ACCOUNT, chat["chat_id"]),
    )
    database.commit()
    return "{} больше не в списке ждущих ответа.".format(chat["title"])


TOOLS = [
    {
        "name": "telegram_status",
        "description": "Состояние связки с Телеграмом: подключён ли бот, сколько чатов и когда был последний опрос.",
        "schema": {"type": "object", "properties": {}},
        "run": tool_status,
    },
    {
        "name": "telegram_inbox",
        "description": ("Кто написал и кому человек ещё не ответил. Это первое, с чего начинать разбор "
                        "переписки: краткая сводка по чатам, а не сами сообщения."),
        "schema": {"type": "object", "properties": {
            "hours": {"type": "integer", "description": "За сколько часов смотреть, по умолчанию 24"},
            "waiting_only": {"type": "boolean", "description": "Только те, кто ждёт ответа (по умолчанию да)"},
        }},
        "run": tool_inbox,
    },
    {
        "name": "telegram_thread",
        "description": "Переписка с одним человеком: имя, @ник или номер чата. Нужна, чтобы понять контекст перед ответом.",
        "schema": {"type": "object", "properties": {
            "chat": {"type": "string", "description": "Имя, @ник или номер чата"},
            "limit": {"type": "integer", "description": "Сколько последних сообщений, по умолчанию 30"},
        }, "required": ["chat"]},
        "run": tool_thread,
    },
    {
        "name": "telegram_search",
        "description": "Поиск по накопленной переписке: где обсуждали слово или фразу.",
        "schema": {"type": "object", "properties": {
            "query": {"type": "string"},
        }, "required": ["query"]},
        "run": tool_search,
    },
    {
        "name": "telegram_reply",
        "description": ("Отправляет сообщение в чат ОТ ИМЕНИ ЧЕЛОВЕКА — собеседник увидит обычное сообщение "
                        "от него. Только после того, как человек прочитал текст и согласился."),
        "schema": {"type": "object", "properties": {
            "chat": {"type": "string", "description": "Имя, @ник или номер чата"},
            "text": {"type": "string", "description": "Текст сообщения целиком"},
        }, "required": ["chat", "text"]},
        "run": tool_reply,
    },
    {
        "name": "telegram_mark_answered",
        "description": "Убирает чат из списка ждущих ответа, когда отвечать не нужно.",
        "schema": {"type": "object", "properties": {
            "chat": {"type": "string"},
        }, "required": ["chat"]},
        "run": tool_mark_answered,
    },
]


# MARK: MCP


def mcp():
    """MCP-сервер поверх stdin/stdout: по строке JSON-RPC на сообщение."""
    database = connect()
    tools = {tool["name"]: tool for tool in TOOLS}
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method = message.get("method")
        identifier = message.get("id")
        if identifier is None:  # уведомление, ответа не ждут
            continue
        if method == "initialize":
            result = {
                "protocolVersion": (message.get("params") or {}).get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "telegram", "version": "1.0"},
            }
        elif method == "tools/list":
            result = {"tools": [{"name": tool["name"], "description": tool["description"],
                                 "inputSchema": tool["schema"]} for tool in TOOLS]}
        elif method == "tools/call":
            parameters = message.get("params") or {}
            tool = tools.get(parameters.get("name"))
            if tool:
                try:
                    text = tool["run"](database, parameters.get("arguments") or {})
                    result = {"content": [{"type": "text", "text": text}]}
                except Exception as failure:
                    result = {"content": [{"type": "text", "text": "Ошибка: {}".format(failure)}],
                              "isError": True}
            else:
                result = {"content": [{"type": "text", "text": "Нет такого инструмента"}], "isError": True}
        elif method == "ping":
            result = {}
        else:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": identifier,
                                         "error": {"code": -32601, "message": "unknown method"}}) + "\n")
            sys.stdout.flush()
            continue
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "result": result}) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "mcp"
    if mode == "daemon":
        daemon()
    elif mode == "mcp":
        mcp()
    elif mode in ("install", "enable"):
        print(install())
    elif mode == "disable":
        print(disable())
    elif mode == "remove":
        print(remove())
    elif mode == "status":
        print(tool_status(connect(), {}))
    else:
        sys.stderr.write(__doc__)
        sys.exit(2)
