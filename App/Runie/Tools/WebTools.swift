import AppKit
import RunieKit
import WebKit

// Невидимый браузер Руни: настоящая страница с JavaScript, но без окна.
//
// Нужен, чтобы Руни мог сходить куда-то сам — посмотреть расписание, найти
// ответ на странице, нажать кнопку — и не мешать человеку работать. Свой
// браузер человека при этом не трогается: ни вкладок, ни фокуса.
//
// Куки берутся из Safari и Chrome и только для того сайта, куда Руни идёт
// сейчас: войдя в дневник, он не получает заодно доступ к почте и банку.

@MainActor
final class HeadlessBrowser {

    static let shared = HeadlessBrowser()

    /// Куда сохраняются снимки страниц.
    static var snapshotsDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Runie/Web", directoryHint: .isDirectory)
    }

    private var window: NSWindow?
    private var webView: WKWebView?
    /// Сайты, для которых человек уже разрешил вход своей учётной записью.
    private(set) var signedInHosts: Set<String> = []

    enum Failure: LocalizedError {
        case badURL(String)
        case load(String)
        case blank

        var errorDescription: String? {
            switch self {
            case .badURL(let text): "Не похоже на адрес: \(text)"
            case .load(let reason): "Страница не открылась: \(reason)"
            case .blank: "Сначала откройте страницу — web_open."
            }
        }
    }

    /// Готовит окно за пределами экранов. WKWebView рисует и считает скрипты,
    /// только находясь в окне, поэтому окно есть — просто его никто не видит.
    private func prepared() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        webView.customUserAgent = Self.userAgent

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        // Далеко за краем любого экрана: страница живёт, но человек её не видит.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderBack(nil)

        self.window = window
        self.webView = webView
        return webView
    }

    /// Обычный Safari: сайты не должны принимать Руни за робота.
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    // MARK: Куки

    /// Переносит куки сайта из браузера человека. Возвращает, сколько и откуда.
    func importCookies(for host: String) async throws -> String {
        let store = prepared().configuration.websiteDataStore.httpCookieStore
        var report: [String] = []
        var total = 0

        // Чтение идёт в стороне от главного потока: у Chrome ключ лежит в
        // Связке ключей, а она умеет спросить разрешение и подождать ответа.
        let safari = await Task.detached { (try? SafariCookies.cookies(for: host)) ?? [] }.value
        let chrome = await Task.detached { (try? ChromeCookies.cookies(for: host)) ?? [] }.value

        for (source, cookies) in [(BrowserCookieSource.safari, safari), (.chrome, chrome)] {
            let fresh = cookies.filter { !$0.isExpired() }
            guard !fresh.isEmpty else { continue }
            for cookie in fresh {
                guard let converted = Self.convert(cookie) else { continue }
                await store.setCookie(converted)
                total += 1
            }
            report.append("\(source.title): \(fresh.count)")
        }
        guard total > 0 else {
            return "Куки для \(host) не нашлись. Возможно, вы туда ещё не входили — "
                 + "или у Руни нет полного доступа к диску."
        }
        signedInHosts.insert(host)
        return "Взял куки \(host) — \(report.joined(separator: ", "))."
    }

    private static func convert(_ cookie: BrowserCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: cookie.domain,
            .path: cookie.path.isEmpty ? "/" : cookie.path,
            .name: cookie.name,
            .value: cookie.value
        ]
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.isSecure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    /// Забывает всё, что браузер накопил: куки, хранилища, кеш.
    func forgetEverything() async {
        guard let webView else { return }
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        signedInHosts.removeAll()
    }

    // MARK: Страница

    @discardableResult
    func open(_ address: String) async throws -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: text), url.host() != nil else { throw Failure.badURL(address) }
        let webView = prepared()
        webView.load(URLRequest(url: url))
        try await settle()
        let title = (try? await runJS("document.title")) ?? ""
        return "Открыл \(url.host() ?? text)\(title.isEmpty ? "" : " — \(title)")"
    }

    /// Ждёт, пока страница перестанет грузиться. Современные сайты дорисовывают
    /// себя скриптами, поэтому после загрузки даём им ещё мгновение.
    private func settle(timeout: TimeInterval = 25) async throws {
        guard let webView else { throw Failure.blank }
        let deadline = Date().addingTimeInterval(timeout)
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .milliseconds(450))
    }

    func runJS(_ code: String) async throws -> String {
        guard let webView else { throw Failure.blank }
        let result = try await webView.evaluateJavaScript(code)
        switch result {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case is NSNull, nil: return ""
        default: return String(describing: result!)
        }
    }

    /// Видимый текст страницы.
    func text(limit: Int = 12_000) async throws -> String {
        let script = """
        (function(){
          var body = document.body ? document.body.innerText : '';
          return body.replace(/\\n{3,}/g, '\\n\\n').trim();
        })()
        """
        let text = try await runJS(script)
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Ссылки, кнопки и поля — то, с чем можно взаимодействовать.
    func elements(limit: Int = 120) async throws -> String {
        let script = """
        (function(){
          var out = [];
          var nodes = document.querySelectorAll('a[href], button, input, select, textarea, [role=button]');
          for (var i = 0; i < nodes.length && out.length < \(limit); i++) {
            var n = nodes[i];
            var box = n.getBoundingClientRect();
            if (!box.width || !box.height) continue;
            var label = (n.innerText || n.value || n.placeholder || n.getAttribute('aria-label') || '').trim();
            label = label.replace(/\\s+/g, ' ').slice(0, 80);
            var kind = n.tagName.toLowerCase();
            if (kind === 'input') kind = 'поле(' + (n.type || 'text') + ')';
            if (kind === 'a') kind = 'ссылка';
            if (kind === 'button') kind = 'кнопка';
            if (!label && kind.indexOf('поле') !== 0) continue;
            out.push('- ' + kind + ': ' + (label || n.name || n.id));
          }
          return out.join('\\n');
        })()
        """
        let list = try await runJS(script)
        return list.isEmpty ? "На странице нет ссылок, кнопок и полей." : list
    }

    func click(_ target: String) async throws -> String {
        let script = """
        (function(){
          var needle = \(Self.quote(target)).toLowerCase();
          var nodes = document.querySelectorAll('a, button, input[type=submit], input[type=button], [role=button]');
          for (var i = 0; i < nodes.length; i++) {
            var n = nodes[i];
            var label = (n.innerText || n.value || n.getAttribute('aria-label') || '').trim().toLowerCase();
            if (label && label.indexOf(needle) !== -1) { n.click(); return label; }
          }
          return '';
        })()
        """
        let clicked = try await runJS(script)
        guard !clicked.isEmpty else { return "Не нашёл, на что нажать: «\(target)». Посмотрите web_elements." }
        try await settle(timeout: 15)
        return "Нажал «\(clicked)»."
    }

    func fill(_ field: String, with value: String) async throws -> String {
        let script = """
        (function(){
          var needle = \(Self.quote(field)).toLowerCase();
          var nodes = document.querySelectorAll('input, textarea, select');
          for (var i = 0; i < nodes.length; i++) {
            var n = nodes[i];
            var label = ((n.placeholder || '') + ' ' + (n.name || '') + ' ' + (n.id || '') + ' '
                         + (n.getAttribute('aria-label') || '')).toLowerCase();
            if (label.indexOf(needle) !== -1) {
              n.focus();
              n.value = \(Self.quote(value));
              n.dispatchEvent(new Event('input', {bubbles: true}));
              n.dispatchEvent(new Event('change', {bubbles: true}));
              return n.placeholder || n.name || n.id || 'поле';
            }
          }
          return '';
        })()
        """
        let filled = try await runJS(script)
        guard !filled.isEmpty else { return "Не нашёл поле «\(field)». Посмотрите web_elements." }
        return "Заполнил «\(filled)»."
    }

    /// Снимок страницы — когда по тексту не разобраться.
    func snapshot() async throws -> URL {
        guard let webView else { throw Failure.blank }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image = try await webView.takeSnapshot(configuration: configuration)
        try FileManager.default.createDirectory(at: Self.snapshotsDirectory, withIntermediateDirectories: true)
        let url = Self.snapshotsDirectory.appending(path: "page-\(Int(Date().timeIntervalSince1970)).png")
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.load("снимок не получился")
        }
        try png.write(to: url)
        return url
    }

    /// Строка в вид, пригодный для вставки в скрипт.
    private static func quote(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - Инструменты

struct WebOpenTool: HostTool {
    let name = "web_open"
    let description = """
    Открывает страницу в своём браузере — невидимом, отдельном от Safari и Chrome человека: его вкладки \
    и работа не трогаются. Дальше страницу можно читать (web_read), смотреть её кнопки и поля \
    (web_elements), нажимать и заполнять. Если нужна страница, куда человек входит под своей учётной \
    записью — дневник, личный кабинет, почта, — ставь sign_in: тогда Руни возьмёт куки этого сайта из \
    браузера человека. Куки берутся только для этого сайта и только с его разрешения.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "url": .object(["type": .string("string"), "description": .string("Адрес страницы")]),
            "sign_in": .object([
                "type": .string("boolean"),
                "description": .string("Войти под учётной записью человека, взяв куки сайта из его браузера")
            ])
        ]),
        "required": .array([.string("url")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let address = arguments["url"]?.stringValue ?? ""
        let browser = await HeadlessBrowser.shared
        var report = ""
        if arguments["sign_in"]?.boolValue == true {
            guard let host = URL(string: address.contains("://") ? address : "https://" + address)?.host() else {
                return HostToolResult("Не похоже на адрес: \(address)", isError: true)
            }
            do {
                report = try await browser.importCookies(for: host) + "\n"
            } catch {
                report = error.localizedDescription + "\n"
            }
        }
        do {
            let opened = try await browser.open(address)
            return HostToolResult(report + opened)
        } catch {
            return HostToolResult(report + error.localizedDescription, isError: true)
        }
    }
}

struct WebReadTool: HostTool {
    let name = "web_read"
    let description = "Текст открытой страницы. Начинай с него: по тексту видно почти всё."
    let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        do {
            let text = try await HeadlessBrowser.shared.text()
            return HostToolResult(text.isEmpty ? "Страница пустая — возможно, она ещё грузится." : text)
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }
}

struct WebElementsTool: HostTool {
    let name = "web_elements"
    let description = "Ссылки, кнопки и поля открытой страницы — чтобы знать, на что нажимать и что заполнять."
    let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        do {
            return HostToolResult(try await HeadlessBrowser.shared.elements())
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }
}

struct WebClickTool: HostTool {
    let name = "web_click"
    let description = "Нажимает ссылку или кнопку по её надписи на открытой странице."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string"), "description": .string("Надпись или её часть")])]),
        "required": .array([.string("text")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        do {
            return HostToolResult(try await HeadlessBrowser.shared.click(arguments["text"]?.stringValue ?? ""))
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }
}

struct WebFillTool: HostTool {
    let name = "web_fill"
    let description = """
    Заполняет поле на открытой странице. Пароли и данные карт не вводи — их человек вводит сам.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "field": .object(["type": .string("string"), "description": .string("Подпись поля, его имя или placeholder")]),
            "value": .object(["type": .string("string")])
        ]),
        "required": .array([.string("field"), .string("value")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        do {
            let report = try await HeadlessBrowser.shared.fill(
                arguments["field"]?.stringValue ?? "",
                with: arguments["value"]?.stringValue ?? ""
            )
            return HostToolResult(report)
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }
}

struct WebRunJavaScriptTool: HostTool {
    let name = "web_run_js"
    let description = """
    Выполняет твой JavaScript на открытой странице — когда готовых действий мало: разобрать таблицу, \
    достать ссылки, прокрутить, выбрать в списке. Пиши коротко и понятно: человек видит код в запросе \
    разрешения. Возвращай результат из кода.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["code": .object(["type": .string("string")])]),
        "required": .array([.string("code")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let code = arguments["code"]?.stringValue ?? ""
        if let reason = BrowserScript.forbiddenReason(inScript: code) {
            return HostToolResult(reason, isError: true)
        }
        do {
            let result = try await HeadlessBrowser.shared.runJS(BrowserScript.wrapUserScript(code))
            return HostToolResult(result.isEmpty ? "Готово, но код ничего не вернул." : result)
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }
}

struct WebSnapshotTool: HostTool {
    let name = "web_snapshot"
    let description = """
    Снимок открытой страницы — когда по тексту не разобраться: таблица с разметкой, схема, капча. \
    Вставь путь в ответ как ![страница](путь), чтобы человек тоже её увидел.
    """
    let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        do {
            let url = try await HeadlessBrowser.shared.snapshot()
            return HostToolResult("Снимок: \(url.path)")
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }
}

struct WebForgetTool: HostTool {
    let name = "web_forget"
    let description = "Стирает всё, что накопил невидимый браузер: куки, хранилища, кеш."
    let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        await HeadlessBrowser.shared.forgetEverything()
        return HostToolResult("Невидимый браузер забыл всё: куки и хранилища стёрты.")
    }
}
