import Foundation

/// Навыки, с которыми Руни приходит: как расширять себя самому. Записываются в
/// плагин Runie при каждом запуске — обновление приложения обновляет и их.
public enum BundledSkills {

    public static let all: [RuniePlugin.Skill] = [connectService, createSkill]

    static let connectService = RuniePlugin.Skill(
        name: "connect-service",
        description: """
        Подключить Руни к сервису или программе, с которыми он пока не умеет работать: Todoist, Trello, \
        Jira, Linear, Airtable, погода, трекер привычек и так далее. Используй, когда человек просит сделать \
        что-то в сервисе, для которого у тебя нет инструментов, или прямо говорит «подключись к …», \
        «научись работать с …». Также — чтобы отключить такой сервис.
        """,
        instructions: """
        # Подключение сервиса

        Цель — чтобы после подключения человек мог просить тебя работать с сервисом обычными словами.
        Всё, что ты подключаешь, работает только в Runie: Claude Code человека в терминале не меняется.

        ## 1. Проверь, что уже есть

        - Посмотри свои инструменты: вдруг сервис уже подключён (`mcp__…`). Вызови `mcp__runie__list_extensions`.
        - Gmail, Google Calendar, Notion, Slack, GitHub и другие крупные сервисы часто подключаются как
          коннекторы claude.ai. Если это такой сервис — скажи, что проще всего включить его на claude.ai
          в разделе «Коннекторы», и он появится в Руни сам. Подключай сам, только если человек этого хочет.

        ## 2. Найди готовый MCP-сервер

        Ищи по порядку:
        1. Официальный сервер от самого сервиса — на его сайте или в документации («<сервис> MCP server»).
        2. Реестр MCP: `https://registry.modelcontextprotocol.io/v0/servers?search=<сервис>` (WebFetch).
        3. Известные пакеты npm (`npx -y <пакет>`) или PyPI (`uvx <пакет>`).

        Выбирай так:
        - Удалённый сервер (https) с токеном в заголовке — лучший вариант: ничего не нужно устанавливать.
        - Удалённый сервер, которому нужен вход через браузер (OAuth), Руни пока подключить не может —
          ищи вариант с токеном API.
        - Пакет npx/uvx — только от самого сервиса или заметного автора с живым репозиторием.
          Заброшенное, безымянное или странное не бери.
        - Для npx нужен Node.js, для uvx — uv. Проверь: `command -v npx`, `command -v uvx`.
          Если их нет, не устанавливай без спроса: предложи человеку поставить или напиши свой сервер (шаг 3).

        ## 3. Готового нет — напиши свой

        Если у сервиса есть обычный HTTP API, небольшой сервер пишется за несколько минут.
        Как — в [custom-server.md](custom-server.md).

        ## 4. Подключи

        Вызови `mcp__runie__add_service`:
        - `name` — короткое латиницей: `todoist`, `trello`.
        - `description` — по-русски, что он умеет: «Задачи и проекты в Todoist».
        - удалённый: `transport: http`, `url`, `headers` (ключ — через `{ИМЯ_ПЕРЕМЕННОЙ}`, например
          `"Authorization": "Bearer {TODOIST_API_TOKEN}"`);
        - локальный: `transport: stdio`, `command`, `args`. Путь к папке плагина — `{root}`.
        - `secrets` — какие ключи нужны: переменная, понятное название и где его взять.

        **Ключи API никогда не проси писать в чат и не вписывай в команды и файлы.** Перечисли их в
        `secrets`: Руни сам покажет человеку защищённое поле, и ключ сохранится в Связке ключей.
        Подскажи в `hint`, где именно в сервисе взять ключ.

        ## 5. Расскажи человеку

        Коротко: что подключено и два-три примера, что теперь можно просить. Сервер заработает со
        следующего сообщения — так и скажи. Если нужен был ключ, а человек его не ввёл, объясни, что
        сервер подключится, когда ключ будет введён, — повтори `add_service`, когда человек будет готов.

        ## Отключить

        `mcp__runie__remove_service` с именем сервера. Ключи удаляются вместе с ним.
        """,
        files: ["custom-server.md": customServerGuide]
    )

    static let customServerGuide = """
    # Свой MCP-сервер

    Пиши на Python без внешних библиотек — так он запустится на любом Mac, где есть `python3`.
    Сначала проверь: `/usr/bin/python3 --version`. Если Python не установлен (macOS предложит поставить
    инструменты разработчика), скажи человеку и спроси, ставить ли.

    ## Где лежит

    `<папка плагина>/servers/<имя>/server.py`. Папку плагина вернёт `mcp__runie__list_extensions`.
    При подключении путь пиши как `{root}/servers/<имя>/server.py`:
    `transport: stdio`, `command: /usr/bin/python3`, `args: ["{root}/servers/<имя>/server.py"]`.

    ## Каркас

    ```python
    import json, os, sys, urllib.error, urllib.parse, urllib.request

    TOKEN = os.environ.get("TODOIST_API_TOKEN", "")   # имя — как в secrets
    API = "https://api.todoist.com/rest/v2"

    def api(method, path, body=None):
        request = urllib.request.Request(
            API + path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{error.code}: {error.read().decode()[:300]}")

    TOOLS = {
        "list_tasks": {
            "description": "Активные задачи. filter — фильтр Todoist, например «today».",
            "inputSchema": {"type": "object", "properties": {"filter": {"type": "string"}}},
            "run": lambda args: api("GET", "/tasks" + (f"?filter={urllib.parse.quote(args['filter'])}" if args.get("filter") else "")),
        },
    }

    def handle(message):
        method, params = message.get("method"), message.get("params") or {}
        if method == "initialize":
            return {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "todoist", "version": "1.0"}}
        if method == "tools/list":
            return {"tools": [{"name": name, "description": tool["description"], "inputSchema": tool["inputSchema"]}
                              for name, tool in TOOLS.items()]}
        if method == "tools/call":
            tool = TOOLS.get(params.get("name"))
            if not tool:
                return {"content": [{"type": "text", "text": "Нет такого инструмента"}], "isError": True}
            try:
                result = tool["run"](params.get("arguments") or {})
                return {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)[:50000]}]}
            except Exception as error:
                return {"content": [{"type": "text", "text": str(error)}], "isError": True}
        if method == "ping":
            return {}
        return None

    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        if "id" not in message:          # уведомления без ответа
            continue
        result = handle(message)
        reply = {"jsonrpc": "2.0", "id": message["id"]}
        if result is None:
            reply["error"] = {"code": -32601, "message": "Method not found"}
        else:
            reply["result"] = result
        print(json.dumps(reply, ensure_ascii=False), flush=True)
    ```

    ## Правила

    - Инструменты называй по действию: `list_tasks`, `create_task`, `complete_task`. Описания — понятные,
      с тем, что возвращается и какие поля нужны.
    - Сначала сделай то, о чём просил человек, и чтение. Удаление и массовые изменения — только если нужны.
    - Ключ бери только из переменной окружения. Не печатай его и не пиши в файлы.
    - Проверь сервер до подключения, без ключа:
      `printf '%s\\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | /usr/bin/python3 server.py`
      Должны прийти два ответа без ошибок.
    """

    static let createSkill = RuniePlugin.Skill(
        name: "create-skill",
        description: """
        Сохранить новый навык Руни — инструкцию, как выполнять повторяющуюся задачу так, как нравится \
        человеку. Используй, когда человек просит «запомни, как это делать», «сделай из этого навык», \
        «делай так всегда», или вы вместе отработали процесс, который явно пригодится снова. Также — чтобы \
        изменить или удалить сохранённый навык.
        """,
        instructions: """
        # Создание навыка

        Навык — это инструкция, которую ты сам прочитаешь в следующий раз, когда встретится такая задача.
        Пишешь её для себя, а не для человека: конкретно, по шагам, без воды.

        ## 1. Пойми, что сохранять

        - Какая задача и когда навык нужен: какими словами человек обычно просит.
        - Как именно делать: шаги, инструменты, куда класть результат, в каком виде отвечать.
        - Что человек поправлял по ходу — это самое ценное, запиши обязательно.
        Если чего-то не хватает, коротко спроси. Не придумывай предпочтений, которых человек не называл.

        ## 2. Напиши

        - `name` — латиницей через дефис, по сути задачи: `weekly-report`, `compress-for-telegram`.
        - `description` — по-русски, одно-два предложения: что делает навык и **когда его использовать**
          (перечисли типичные формулировки просьб). По описанию ты потом решаешь, звать ли навык.
        - `instructions` — Markdown: цель, шаги, правила и примеры. Коротко: до одной-двух страниц.

        Нельзя класть в навык пароли, ключи API, номера карт и другие секреты — если они нужны, навык
        должен просить их у человека каждый раз или использовать подключённый сервис.

        ## 3. Сохрани

        Вызови `mcp__runie__save_skill`. Тем же именем навык перезаписывается — так его и меняют.
        Посмотреть сохранённые — `mcp__runie__list_extensions`, удалить — `mcp__runie__remove_skill`.

        ## 4. Скажи человеку

        Одной-двумя фразами: какой навык сохранён и какой просьбой его вызвать. Навык заработает со
        следующего сообщения.
        """
    )
}
