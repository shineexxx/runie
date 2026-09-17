import AppKit
import RunieKit

// Safari и Chrome через AppleScript: вкладки, текст страницы, открыть ссылку,
// нажать, заполнить. Первое обращение к браузеру macOS спросит разрешение
// «Runie хочет управлять Safari/Chrome». Читать страницу и действовать на ней
// можно, только если в браузере разрешён JavaScript из Apple Events.

private typealias Browser = BrowserScript.Browser

private func browserSchema(_ extra: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    var properties: [String: JSONValue] = [
        "browser": .object([
            "type": .string("string"),
            "enum": .array([.string("safari"), .string("chrome")]),
            "description": .string("Какой браузер")
        ])
    ]
    properties.merge(extra) { $1 }
    return .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array((["browser"] + required).map(JSONValue.string))
    ])
}

private func field(_ description: String, type: String = "string") -> JSONValue {
    .object(["type": .string(type), "description": .string(description)])
}

private extension JSONValue {
    var browser: Browser { self["browser"]?.stringValue == "chrome" ? .chrome : .safari }
}

/// Запуск AppleScript отдельным процессом: не держит главный поток, пока браузер думает.
private func runAppleScript(_ source: String) async -> (ok: Bool, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-"]
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    return await withCheckedContinuation { continuation in
        process.terminationHandler = { process in
            let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let ok = process.terminationStatus == 0
            continuation.resume(returning: (ok, (ok ? out : err).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(source.utf8))
            try? input.fileHandleForWriting.close()
        } catch {
            continuation.resume(returning: (false, error.localizedDescription))
        }
    }
}

/// Понятное объяснение частых ошибок AppleScript.
private func explain(_ error: String, browser: Browser) -> String {
    if error.contains("-1743") || error.lowercased().contains("not authorized") {
        return "macOS не разрешила Runie управлять \(browser.title). Разрешите: Системные настройки → Конфиденциальность → Автоматизация → Runie → \(browser.title)."
    }
    if error.lowercased().contains("javascript") {
        return browser == .safari
            ? "В Safari выключен JavaScript из Apple Events. Включите: Safari → Настройки → Дополнительно → «Показывать функции для веб-разработчиков», затем меню «Разработка» → «Разрешить JavaScript из Apple Events»."
            : "В Chrome выключен JavaScript из Apple Events. Включите: меню «Вид» → «Разработчик» → «Разрешить JavaScript из Apple Events»."
    }
    return "\(browser.title) ответил ошибкой: \(error)"
}

/// Открыт ли браузер — по списку запущенных приложений, без AppleScript: иначе
/// macOS спросила бы ещё и разрешение управлять System Events.
private func ensureRunning(_ browser: Browser) async -> HostToolResult? {
    let bundleID = browser == .safari ? "com.apple.Safari" : "com.google.Chrome"
    let running = await MainActor.run {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
    return running ? nil : HostToolResult("\(browser.title) не открыт.", isError: true)
}

private func javaScript(_ browser: Browser, _ code: String, arguments: JSONValue) async -> HostToolResult {
    if let notRunning = await ensureRunning(browser) { return notRunning }
    let script = BrowserScript.runJavaScript(
        browser, code,
        window: arguments["window"]?.intValue,
        tab: arguments["tab"]?.intValue
    )
    let result = await runAppleScript(script)
    guard result.ok else { return HostToolResult(explain(result.output, browser: browser), isError: true) }
    return HostToolResult(result.output)
}

private let windowTabFields: [String: JSONValue] = [
    "window": field("Номер окна из browser_tabs; без него — переднее окно", type: "integer"),
    "tab": field("Номер вкладки из browser_tabs; без него — активная", type: "integer")
]

// MARK: - Просмотр

struct BrowserTabsTool: HostTool {
    let name = "browser_tabs"
    let description = "Открытые вкладки Safari или Chrome: номер окна и вкладки, заголовок, адрес, какая активна."
    let inputSchema = browserSchema()

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let browser = arguments.browser
        if let notRunning = await ensureRunning(browser) { return notRunning }
        let result = await runAppleScript(BrowserScript.listTabs(browser))
        guard result.ok else { return HostToolResult(explain(result.output, browser: browser), isError: true) }
        let lines = result.output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { return nil }
            let active = parts[2] == "1" ? " (активная)" : ""
            return "- окно \(parts[0]), вкладка \(parts[1])\(active): \(parts[3]) — \(parts[4])"
        }
        return HostToolResult(lines.isEmpty ? "Вкладок нет." : "Вкладки \(browser.title):\n" + lines.joined(separator: "\n"))
    }
}

struct BrowserPageTextTool: HostTool {
    let name = "browser_page_text"
    let description = "Текст страницы во вкладке Safari или Chrome (по умолчанию — в активной): заголовок, адрес и видимый текст."
    let inputSchema = browserSchema(windowTabFields)

    func call(_ arguments: JSONValue) async -> HostToolResult {
        await javaScript(arguments.browser, BrowserScript.pageTextJS, arguments: arguments)
    }
}

// MARK: - Управление

struct BrowserOpenTool: HostTool {
    let name = "browser_open"
    let description = "Открывает адрес в Safari или Chrome — в новой вкладке или в текущей."
    let inputSchema = browserSchema([
        "url": field("Адрес, начиная с https://"),
        "new_tab": field("Открыть в новой вкладке, по умолчанию да", type: "boolean")
    ], required: ["url"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let browser = arguments.browser
        guard let url = arguments["url"]?.stringValue, let parsed = URL(string: url),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? "")
        else { return HostToolResult("Нужен адрес, начинающийся с http:// или https://.", isError: true) }
        let newTab = arguments["new_tab"]?.boolValue ?? true
        let result = await runAppleScript(BrowserScript.open(browser, url: url, newTab: newTab))
        guard result.ok else { return HostToolResult(explain(result.output, browser: browser), isError: true) }
        return HostToolResult("Открыл \(url) в \(browser.title)\(newTab ? " в новой вкладке" : "").")
    }
}

struct BrowserSwitchTabTool: HostTool {
    let name = "browser_switch_tab"
    let description = "Переключает Safari или Chrome на вкладку по номеру окна и вкладки из browser_tabs."
    let inputSchema = browserSchema([
        "window": field("Номер окна", type: "integer"),
        "tab": field("Номер вкладки", type: "integer")
    ], required: ["window", "tab"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let browser = arguments.browser
        guard let window = arguments["window"]?.intValue, let tab = arguments["tab"]?.intValue else {
            return HostToolResult("Нужны номер окна и вкладки.", isError: true)
        }
        if let notRunning = await ensureRunning(browser) { return notRunning }
        let result = await runAppleScript(BrowserScript.activate(browser, window: window, tab: tab))
        guard result.ok else { return HostToolResult(explain(result.output, browser: browser), isError: true) }
        return HostToolResult("Переключил \(browser.title) на окно \(window), вкладку \(tab).")
    }
}

struct BrowserClickTool: HostTool {
    let name = "browser_click"
    let description = """
    Нажимает ссылку или кнопку на странице Safari или Chrome — по видимой надписи (text) или CSS-селектору (selector). \
    Не нажимай «Купить», «Оплатить», «Отправить», «Удалить» без явной просьбы человека.
    """
    let inputSchema = browserSchema(windowTabFields.merging([
        "text": field("Надпись на кнопке или ссылке"),
        "selector": field("CSS-селектор, если надписи нет")
    ]) { $1 })

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let text = arguments["text"]?.stringValue
        let selector = arguments["selector"]?.stringValue
        guard text != nil || selector != nil else { return HostToolResult("Нужна надпись или селектор.", isError: true) }
        let result = await javaScript(arguments.browser, BrowserScript.clickJS(selector: selector, text: text), arguments: arguments)
        if result.text == "not found" { return HostToolResult("Не нашёл такой кнопки или ссылки на странице.", isError: true) }
        if result.text == "bad selector" { return HostToolResult("Неверный CSS-селектор.", isError: true) }
        return result
    }
}

struct BrowserFillTool: HostTool {
    let name = "browser_fill"
    let description = """
    Заполняет поле на странице Safari или Chrome — по подписи, placeholder или имени (field) или CSS-селектору. \
    Не вводи пароли и данные карт.
    """
    let inputSchema = browserSchema(windowTabFields.merging([
        "field": field("Подпись, placeholder или имя поля"),
        "selector": field("CSS-селектор, если подписи нет"),
        "value": field("Что ввести")
    ]) { $1 }, required: ["value"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let fieldName = arguments["field"]?.stringValue
        let selector = arguments["selector"]?.stringValue
        guard let value = arguments["value"]?.stringValue, fieldName != nil || selector != nil else {
            return HostToolResult("Нужны поле и значение.", isError: true)
        }
        let lowered = ((fieldName ?? "") + " " + (selector ?? "")).lowercased()
        if ["password", "пароль", "card", "карт", "cvc", "cvv"].contains(where: lowered.contains) {
            return HostToolResult("Пароли и данные карт Руни не вводит — это делает человек сам.", isError: true)
        }
        let result = await javaScript(arguments.browser, BrowserScript.fillJS(selector: selector, field: fieldName, value: value), arguments: arguments)
        if result.text == "not found" { return HostToolResult("Не нашёл такого поля на странице.", isError: true) }
        if result.text == "bad selector" { return HostToolResult("Неверный CSS-селектор.", isError: true) }
        return result
    }
}

// MARK: - Свой JavaScript

struct BrowserRunJavaScriptTool: HostTool {
    let name = "browser_run_js"
    let description = """
    Выполняет твой JavaScript во вкладке Safari или Chrome и возвращает результат. code — тело функции: \
    верни значение через return (строку или объект — он придёт как JSON). Синхронно: await и промисы \
    не дождутся. Годится, чтобы разобрать устройство страницы, достать ссылки и таблицы, нажать элемент \
    без надписи, прокрутить, выбрать в списке. Нельзя: cookie, localStorage и другие хранилища, поля \
    паролей, fetch и отправка данных. Не нажимай «Купить», «Оплатить», «Отправить», «Удалить» без явной просьбы.
    """
    let inputSchema = browserSchema(windowTabFields.merging([
        "code": field("Тело функции JavaScript с return")
    ]) { $1 }, required: ["code"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        guard let code = arguments["code"]?.stringValue, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return HostToolResult("Нужен код.", isError: true)
        }
        if let reason = BrowserScript.forbiddenReason(inScript: code) {
            return HostToolResult(reason, isError: true)
        }
        let result = await javaScript(arguments.browser, BrowserScript.wrapUserScript(code), arguments: arguments)
        if !result.isError, result.text.hasPrefix("JS error: ") {
            return HostToolResult("Ошибка в коде: " + result.text.dropFirst(10), isError: true)
        }
        return result
    }
}
