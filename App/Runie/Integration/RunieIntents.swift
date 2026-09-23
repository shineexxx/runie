import AppIntents
import AppKit
import RunieKit

// Действия Руни для Spotlight, Быстрых команд и Siri.
//
// Их вызывает сам человек, поэтому вопрос отправляется сразу — в отличие от
// ссылок `runie://`, которые может открыть кто угодно.

struct AskRunieIntent: AppIntent {
    static let title: LocalizedStringResource = "Спросить Руни"
    static let description = IntentDescription("Открывает чат у орба и задаёт Руни вопрос.")

    @Parameter(title: "Вопрос", requestValueDialog: "Что спросить у Руни?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Спросить Руни: \(\.$question)")
    }

    /// Руни и так на экране — орбом; его главное окно здесь не нужно.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        RunieCommands.noteCommand()
        RunieCommands.ask?(question, true)
        return .result()
    }
}

struct OpenRunieChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть чат Руни"
    static let description = IntentDescription("Открывает чат у орба.")

    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        RunieCommands.noteCommand()
        RunieCommands.openChat?()
        return .result()
    }
}

struct NewRunieConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Новый разговор с Руни"
    static let description = IntentDescription("Начинает разговор с чистого листа и открывает чат.")

    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        RunieCommands.noteCommand()
        RunieCommands.newConversation?()
        return .result()
    }
}

// MARK: - Поиск по указателю

/// Запись указателя: файл, письмо, заметка, разговор, страница.
struct IndexItemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Находка Руни"
    static let defaultQuery = IndexItemQuery()

    /// Источник и внешний номер: по ним запись находится снова.
    let id: String
    let title: String
    let subtitle: String
    let source: String
    let externalID: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: .init(systemName: Self.symbol(for: source))
        )
    }

    init(hit: IndexStore.Hit) {
        let item = hit.item
        source = item.source.rawValue
        externalID = item.externalID
        id = item.source.rawValue + "|" + item.externalID
        title = item.title
        let day = item.date.formatted(.dateTime.day().month().year().locale(.runie))
        subtitle = [item.source.title, day, item.details["from"] ?? item.details["host"]]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func symbol(for source: String) -> String {
        switch IndexStore.Source(rawValue: source) {
        case .files: "doc"
        case .mail: "envelope"
        case .notes: "note.text"
        case .messages: "message"
        case .photos: "photo"
        case .history: "safari"
        case nil: "magnifyingglass"
        }
    }
}

/// Поиск записей по строке: так Spotlight и Быстрые команды достают находки.
struct IndexItemQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [IndexItemEntity] {
        try await IndexModel.shared.search(string, sources: nil, limit: 12).map(IndexItemEntity.init)
    }

    /// По номеру запись отдельно не ищется: номер несёт в себе всё, но
    /// Spotlight спрашивает только то, что сам же недавно получил.
    func entities(for identifiers: [String]) async throws -> [IndexItemEntity] { [] }

    func suggestedEntities() async throws -> [IndexItemEntity] { [] }
}

struct SearchMyStuffIntent: AppIntent {
    static let title: LocalizedStringResource = "Найти у себя"
    static let description = IntentDescription(
        "Ищет по указателю Руни: файлы, письма, заметки, переписку и историю браузера — по смыслу, а не по точному слову."
    )

    @Parameter(title: "Что ищем", requestValueDialog: "Что найти?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Найти у себя: \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IndexItemEntity]> & ProvidesDialog {
        let found = try await IndexModel.shared.search(query, sources: nil, limit: 12).map(IndexItemEntity.init)
        let dialog: IntentDialog = found.isEmpty
            ? "Ничего не нашлось. Возможно, указатель ещё не собран — это в настройках Руни."
            : "Нашлось: \(found.count)."
        return .result(value: found, dialog: dialog)
    }
}

/// Открывает находку: файл — в своей программе, страницу — в браузере.
struct OpenIndexItemIntent: OpenIntent {
    static let title: LocalizedStringResource = "Открыть находку"

    @Parameter(title: "Находка")
    var target: IndexItemEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        switch IndexStore.Source(rawValue: target.source) {
        case .files:
            NSWorkspace.shared.open(URL(fileURLWithPath: target.externalID))
        case .history:
            if let url = URL(string: String(target.externalID.dropFirst("page:".count))) {
                NSWorkspace.shared.open(url)
            }
        default:
            // Письмо, заметку или переписку проще всего показать через Руни.
            RunieCommands.noteCommand()
            RunieCommands.ask?("Покажи: «\(target.title)»", true)
        }
        return .result()
    }
}

// MARK: - Готовые команды

/// Команды, которые появляются в Spotlight и Быстрых командах сами, без настройки.
struct RunieShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskRunieIntent(),
            phrases: [
                "Спросить \(.applicationName)",
                "Спроси \(.applicationName)",
                "Ask \(.applicationName)"
            ],
            shortTitle: "Спросить Руни",
            systemImageName: "bubble.left"
        )
        AppShortcut(
            intent: SearchMyStuffIntent(),
            phrases: [
                "Найти у себя в \(.applicationName)",
                "Поиск в \(.applicationName)",
                "Search in \(.applicationName)"
            ],
            shortTitle: "Найти у себя",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: NewRunieConversationIntent(),
            phrases: [
                "Новый разговор в \(.applicationName)",
                "New chat in \(.applicationName)"
            ],
            shortTitle: "Новый разговор",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenRunieChatIntent(),
            phrases: [
                "Открыть \(.applicationName)",
                "Open \(.applicationName)"
            ],
            shortTitle: "Открыть чат",
            systemImageName: "circle.dotted"
        )
    }
}
