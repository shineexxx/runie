import Foundation
import RunieKit

// Телеграм: Руни читает личную переписку человека и отвечает в ней от его имени.
//
// Работает через Telegram Business — режим для владельцев Premium. Опрос идёт,
// пока открыт Runie; Телеграм придерживает недоставленное сутки, поэтому
// перерывы на сон и перезапуск ничего не теряют.
//
// У нового человека выключено: пока он не подключит Телеграм, инструментов
// telegram_* у агента нет вовсе.

@MainActor
@Observable
final class TelegramService {

    static let shared = TelegramService()

    /// Ключ бота лежит в Связке ключей, как ключи остальных сервисов.
    nonisolated static let tokenVariable = RuniePlugin.environmentVariable(server: "telegram", variable: "BOT_TOKEN")
    private static let enabledKey = "telegram.enabled"

    /// Подключён и включён ли Телеграм. У нового человека — нет.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { start() } else { stop() }
            onChange?()
        }
    }

    /// Расширение включили или выключили — приложению нужно пересобрать инструменты.
    @ObservationIgnored var onChange: (() -> Void)?

    private(set) var lastError: String?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var opened: TelegramStore?

    /// Хранилище переписки. Открывается при первом обращении.
    var store: TelegramStore? {
        if let opened { return opened }
        opened = try? TelegramStore()
        return opened
    }

    /// Связка ключей — дело не главного потока: если macOS решит спросить доступ,
    /// главный поток встанет вместе с диалогом и окно Руни не откроется.
    nonisolated var api: TelegramAPI {
        TelegramAPI(token: { TokenCache.value() })
    }

    /// Ключ бота, прочитанный один раз за запуск.
    ///
    /// Связка ключей умеет спросить разрешение на доступ, и если читать её на
    /// каждое действие, человек будет отвечать на один и тот же вопрос снова и
    /// снова. Одно чтение за запуск — один вопрос, и тот при первом обращении.
    enum TokenCache {
        nonisolated(unsafe) private static var cached: String?
        nonisolated(unsafe) private static var read = false
        private static let lock = NSLock()

        static func value() -> String? {
            lock.lock()
            defer { lock.unlock() }
            if !read {
                cached = SecretStore.value(for: TelegramService.tokenVariable)
                read = true
            }
            return cached
        }

        /// Ключ поменялся: человек ввёл новый или отключил Телеграм.
        static func forget() {
            lock.lock()
            defer { lock.unlock() }
            cached = nil
            read = false
        }
    }

    nonisolated var hasToken: Bool { TokenCache.value() != nil }

    /// Поднимает опрос, если Телеграм включён. Зовётся при запуске приложения:
    /// ключ спрашиваем в стороне, чтобы запуск не ждал Связку ключей.
    func startIfEnabled() {
        guard isEnabled else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            guard hasToken else {
                // Без ключа сбор не начнётся. Раньше это было тихо, и Телеграм
                // просто молчал; теперь причина видна в настройках.
                let reason = SecretStore.lastFailure
                    ?? String(localized: "Ключ бота не найден — подключите Телеграм заново.")
                await MainActor.run { self.lastError = reason }
                return
            }
            await MainActor.run { self.start() }
        }
    }

    func start() {
        guard polling == nil, let store else { return }
        let api = api
        polling = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    let updates = try await api.updates(after: store.offset)
                    for update in updates {
                        if let number = try TelegramUpdates.apply(update, to: store) {
                            store.offset = number
                        }
                    }
                    store.lastPoll = Date()
                    failures = 0
                    await MainActor.run { self?.lastError = nil }
                } catch is CancellationError {
                    return
                } catch {
                    failures += 1
                    let message = error.localizedDescription
                    await MainActor.run { self?.lastError = message }
                    // Сеть отвалилась или компьютер уснул: ждём всё дольше, но не больше минуты.
                    let delay = min(60, 1 << min(failures, 6))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    var isCollecting: Bool { polling != nil }

    /// Проверяет ключ, включает расширение и поднимает опрос.
    func connect() async -> String {
        guard hasToken else { return "Ключ бота не введён." }
        do {
            let name = try await api.botName()
            isEnabled = true
            return "Бот @\(name) на связи."
        } catch {
            return "Ключ не подошёл: \(error.localizedDescription)"
        }
    }

    /// Выключает и убирает всё: ключ, переписку и настройку.
    func disconnect() {
        TokenCache.forget()
        stop()
        opened = nil
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        SecretStore.delete(Self.tokenVariable)
        try? FileManager.default.removeItem(at: TelegramStore.standardURL.deletingLastPathComponent())
        onChange?()
    }

    /// Имя человека для переписки: как его знает Телеграм.
    var me: String { store?.connection()?.name ?? "Я" }
}

// MARK: - Инструменты

/// Подключение: единственный инструмент, который есть до подключения.
struct TelegramConnectTool: HostTool {
    let name = "telegram_connect"
    let description = """
    Подключает Телеграм человека: он вводит ключ своего бота в защищённом поле, и дальше Руни видит \
    личную переписку в выбранных им чатах. Сначала прочитай навык runie:connect-telegram — там условия \
    (нужен Telegram Premium и бот с включённым Business Mode) и что человек делает сам.
    """
    let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let service = await TelegramService.shared
        if await !service.hasToken {
            let entered = await SecretBroker.shared.request(
                serverName: "telegram",
                title: "Телеграм",
                fields: [RuniePlugin.SecretField(
                    variable: "BOT_TOKEN",
                    label: "Ключ бота Телеграма",
                    hint: "@BotFather → /newbot, или /mybots → API Token"
                )]
            )
            guard entered else {
                return HostToolResult("Человек не ввёл ключ. Предложи вернуться к этому позже.")
            }
        }
        // Человек только что ввёл ключ — прочитать его заново.
        await TelegramService.TokenCache.forget()
        let report = await service.connect()
        return HostToolResult(report + " " + ("""
            Последний шаг человек делает сам, в Телеграме: Настройки → Телеграм для бизнеса → Чат-боты → \
            указать своего бота и выбрать чаты. Переписка начнёт собираться сразу после этого.
            """))
    }
}

struct TelegramStatusTool: HostTool {
    let name = "telegram_status"
    let description = "Состояние Телеграма: подключён ли бот к аккаунту, сколько собрано и когда был последний опрос."
    let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let service = await TelegramService.shared
        guard let store = await service.store else { return HostToolResult("Переписка недоступна.", isError: true) }
        guard let connection = store.connection() else {
            return HostToolResult(("""
                Ключ бота на месте, но человек ещё не подключил его к аккаунту. В Телеграме: \
                Настройки → Телеграм для бизнеса → Чат-боты → указать бота и выбрать чаты.
                """))
        }
        let counts = store.counts()
        var lines = [
            "Аккаунт: \(connection.name)",
            ("Подключение: \(connection.enabled ? "включено" : "выключено")"),
            ("Право отвечать: \(connection.canReply ? "есть" : "нет")"),
            "Чатов: \(counts.chats), сообщений: \(counts.messages)",
            // Собирать и быть подключённым — разное: опрос мог и не подняться.
            ("Сбор: \(await service.isCollecting ? "идёт" : "стоит")")
        ]
        if let last = store.lastPoll {
            let seconds = Int(Date().timeIntervalSince(last))
            lines.append(("Последний опрос: \(seconds < 90 ? "\(seconds) с" : "\(seconds / 60) мин") назад"))
        }
        if let error = await service.lastError {
            lines.append("Последняя ошибка опроса: \(error)")
        }
        return HostToolResult(lines.joined(separator: "\n"))
    }
}

struct TelegramInboxTool: HostTool {
    let name = "telegram_inbox"
    let description = """
    Кто написал и кому человек ещё не ответил. С этого начинай разбор переписки: это краткая сводка по \
    чатам, а не сами сообщения. Отвечай по ней коротко — кто, о чём, что срочное.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "hours": .object(["type": .string("integer"), "description": .string("За сколько часов, по умолчанию 24")]),
            "waiting_only": .object(["type": .string("boolean"), "description": .string("Только ждущие ответа, по умолчанию да")])
        ])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        guard let store = await TelegramService.shared.store else {
            return HostToolResult("Переписка недоступна.", isError: true)
        }
        let hours = arguments["hours"]?.intValue ?? 24
        let waitingOnly = arguments["waiting_only"]?.boolValue ?? true
        let waiting = store.waiting(hours: hours, waitingOnly: waitingOnly)
        return HostToolResult(TelegramUpdates.inbox(waiting, hours: hours, waitingOnly: waitingOnly))
    }
}

struct TelegramThreadTool: HostTool {
    let name = "telegram_thread"
    let description = "Переписка с одним человеком: имя, @ник или номер чата. Прочитай её, прежде чем предлагать ответ."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "chat": .object(["type": .string("string"), "description": .string("Имя, @ник или номер чата")]),
            "limit": .object(["type": .string("integer"), "description": .string("Сколько последних сообщений, по умолчанию 30")])
        ]),
        "required": .array([.string("chat")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let service = await TelegramService.shared
        guard let store = await service.store else { return HostToolResult("Переписка недоступна.", isError: true) }
        guard let chat = store.findChat(arguments["chat"]?.stringValue ?? "") else {
            return HostToolResult("Не нашёл такой чат. Посмотрите список в telegram_inbox.")
        }
        let messages = store.messages(chatID: chat.id, limit: min(arguments["limit"]?.intValue ?? 30, 200))
        return HostToolResult(TelegramUpdates.thread(messages, chat: chat, me: await service.me))
    }
}

struct TelegramSearchTool: HostTool {
    let name = "telegram_search"
    let description = "Поиск по накопленной переписке: где обсуждали слово или фразу."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string")])]),
        "required": .array([.string("query")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let service = await TelegramService.shared
        guard let store = await service.store else { return HostToolResult("Переписка недоступна.", isError: true) }
        let query = arguments["query"]?.stringValue ?? ""
        return HostToolResult(TelegramUpdates.found(store.search(query), query: query, me: await service.me))
    }
}

struct TelegramReplyTool: HostTool {
    let name = "telegram_reply"
    let description = """
    Отправляет сообщение в чат ОТ ИМЕНИ ЧЕЛОВЕКА — собеседник увидит обычное сообщение от него, не от бота. \
    Только после того, как человек прочитал текст ответа и согласился его отправить.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "chat": .object(["type": .string("string"), "description": .string("Имя, @ник или номер чата")]),
            "text": .object(["type": .string("string"), "description": .string("Текст сообщения целиком")])
        ]),
        "required": .array([.string("chat"), .string("text")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let service = await TelegramService.shared
        guard let store = await service.store else { return HostToolResult("Переписка недоступна.", isError: true) }
        guard let chat = store.findChat(arguments["chat"]?.stringValue ?? "") else {
            return HostToolResult("Не нашёл такой чат. Посмотрите список в telegram_inbox.")
        }
        let text = (arguments["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return HostToolResult("Пустое сообщение отправлять не буду.", isError: true) }
        let connectionID = chat.connectionID.isEmpty ? (store.connection()?.id ?? "") : chat.connectionID
        guard !connectionID.isEmpty else {
            return HostToolResult("Бот не подключён к аккаунту — отправлять не от кого.", isError: true)
        }
        do {
            let result = try await service.api.send(connectionID: connectionID, chatID: chat.id, text: text)
            // Своё сообщение кладём сразу: чат должен перестать ждать ответа немедленно.
            try? store.save(message: TelegramStore.Message(
                chatID: chat.id,
                messageID: Int64(result["message_id"]?.intValue ?? Int(Date().timeIntervalSince1970)),
                date: Date(),
                outgoing: true,
                text: text
            ))
            return HostToolResult("Отправил \(chat.title): \(text)")
        } catch {
            return HostToolResult("Не отправилось: \(error.localizedDescription)", isError: true)
        }
    }
}

struct TelegramMarkAnsweredTool: HostTool {
    let name = "telegram_mark_answered"
    let description = "Убирает чат из списка ждущих ответа, когда отвечать не нужно."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["chat": .object(["type": .string("string")])]),
        "required": .array([.string("chat")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        guard let store = await TelegramService.shared.store else {
            return HostToolResult("Переписка недоступна.", isError: true)
        }
        guard let chat = store.findChat(arguments["chat"]?.stringValue ?? "") else {
            return HostToolResult("Не нашёл такой чат.")
        }
        try? store.markAnswered(chatID: chat.id)
        return HostToolResult("\(chat.title) больше не в списке ждущих ответа.")
    }
}

struct TelegramDisconnectTool: HostTool {
    let name = "telegram_disconnect"
    let description = "Отключает Телеграм: убирает ключ бота и всю накопленную переписку. Спроси подтверждение."
    let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        await TelegramService.shared.disconnect()
        return HostToolResult(("""
            Телеграм отключён: ключ бота и накопленная переписка удалены. В самом Телеграме бота тоже стоит \
            убрать: Настройки → Телеграм для бизнеса → Чат-боты.
            """))
    }
}
