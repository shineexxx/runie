import AppKit
import EventKit
import Observation
import RunieKit

/// Приветствие и подсказки под полем ввода, которые придумывает ИИ.
///
/// Чат их никогда не ждёт: при открытии сразу стоят последние подсказки для этого
/// приложения (или обычные), а новые придумываются в фоне и плавно подменяют старые.
/// Для одного приложения — не чаще раза в `refreshInterval`, чтобы не тратить лимит.
@MainActor
@Observable
final class SuggestionsModel {

    private(set) var current: [Suggestion] = []
    /// Приветствие в пустом чате вместо «Чем помочь?».
    private(set) var greeting: String
    private(set) var isGenerating = false

    @ObservationIgnored private let generator: ClaudeSuggestionGenerator?
    @ObservationIgnored private let store: ChatHistoryStore
    @ObservationIgnored private var cache: [String: Generated] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Последнее придуманное — в том числе из прошлого запуска.
    @ObservationIgnored private var last: Generated?

    private struct Generated: Codable {
        let date: Date
        let set: SuggestionSet
    }

    private static let refreshInterval: TimeInterval = 20 * 60
    private static let lastKey = "suggestions.lastSet"

    /// Источники из MCP-серверов: имя сервера → запрос. Задаёт приложение.
    @ObservationIgnored var sources: () -> [(server: String, query: String)] = { [] }
    @ObservationIgnored private let digest: MCPDigest?
    /// Сводки по источникам — не чаще раза в полчаса на сервер и запрос.
    @ObservationIgnored private var noteCache: [String: (date: Date, note: SuggestionContext.ServiceNote?)] = [:]
    private static let noteInterval: TimeInterval = 30 * 60

    init(store: ChatHistoryStore) {
        self.store = store
        let executable = try? ClaudeCodeLocator().locate()
        generator = executable.map { ClaudeSuggestionGenerator(executable: $0) }
        digest = executable.map { executable in
            MCPDigest(backend: ClaudeCodeBackend(
                executable: executable,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                arguments: ClaudeCodeArguments(additionalArguments: MCPDigest.arguments())
            ))
        }
        let saved = UserDefaults.standard.data(forKey: Self.lastKey)
            .flatMap { try? JSONDecoder().decode(Generated.self, from: $0) }
        last = saved
        current = saved?.set.suggestions ?? Suggestion.fixed(ContextSuggestions.fallback)
        greeting = saved.flatMap { Self.stillFits($0) ? $0.set.greeting : nil }
            ?? SuggestionSet.fallbackGreeting()
    }

    /// Приветствие «Доброе утро» вечером неуместно: придуманное в другое время суток
    /// не показывается.
    private static func stillFits(_ generated: Generated, now: Date = Date()) -> Bool {
        SuggestionContext.partOfDay(at: generated.date) == SuggestionContext.partOfDay(at: now)
    }

    /// Вызывается при открытии чата.
    func refresh(for app: AppContext?) {
        let key = app?.bundleIdentifier ?? "none"

        if let cached = cache[key] {
            current = cached.set.suggestions
            greeting = (Self.stillFits(cached) ? cached.set.greeting : nil) ?? SuggestionSet.fallbackGreeting()
            if Date().timeIntervalSince(cached.date) < Self.refreshInterval, Self.stillFits(cached) { return }
        } else {
            // Пока ИИ думает — последние придуманные подсказки. Шаблонные под
            // семейство приложения — только если ИИ ещё ни разу не отвечал.
            if let last {
                current = last.set.suggestions
            } else if let app {
                current = Suggestion.fixed(app.suggestions)
            }
            // Последнее придуманное приветствие лучше шаблонного, если время суток то же.
            greeting = last.flatMap { Self.stillFits($0) ? $0.set.greeting : nil }
                ?? SuggestionSet.fallbackGreeting()
        }

        guard let generator, task == nil else { return }
        let appName = app?.name
        let running = Self.runningApps(excluding: app?.bundleIdentifier)
        let previous = current.map(\.label)
        let store = store
        isGenerating = true
        task = Task { [weak self] in
            // Файлы и история — не в главном потоке: первый доступ к Загрузкам
            // вызывает системный запрос, и чат не должен его ждать.
            let events = await Self.todayEvents()
            let notes = await self?.serviceNotes() ?? []
            let context = await Task.detached(priority: .utility) {
                SuggestionContext(
                    date: Date(),
                    appName: appName,
                    runningApps: running,
                    events: events,
                    recentFiles: SuggestionsModel.recentFiles(),
                    recentConversations: store.list().prefix(5).map(\.title),
                    previousSuggestions: previous
                )
            }.value
            var enriched = context
            enriched.serviceNotes = notes
            let result = try? await generator.generate(enriched)
            #if DEBUG
            // `-RunieSuggestTrace путь` — что ушло в генератор и что вернулось.
            if let path = UserDefaults.standard.string(forKey: "RunieSuggestTrace") {
                let trace = notes.map { "[\($0.source)] \($0.summary)" }.joined(separator: "\n")
                    + "\n---\n" + (result.map { "\($0.greeting ?? "") | " + $0.suggestions.map(\.label).joined(separator: " | ") } ?? "нет ответа")
                try? trace.write(toFile: path, atomically: true, encoding: .utf8)
            }
            #endif
            guard let self else { return }
            self.task = nil
            self.isGenerating = false
            guard let result, result.suggestions.count >= 2 else { return }
            let set = SuggestionSet(greeting: result.greeting, suggestions: Array(result.suggestions.prefix(2)))
            let generated = Generated(date: Date(), set: set)
            self.cache[key] = generated
            self.last = generated
            self.current = set.suggestions
            if let greeting = set.greeting { self.greeting = greeting }
            UserDefaults.standard.set(try? JSONEncoder().encode(generated), forKey: Self.lastKey)
        }
    }

    // MARK: - Данные

    /// Сводки из включённых источников — параллельно, из кэша, если свежие.
    private func serviceNotes() async -> [SuggestionContext.ServiceNote] {
        guard let digest else { return [] }
        let now = Date()
        var notes: [SuggestionContext.ServiceNote] = []
        var stale: [(key: String, server: String, query: String)] = []
        for source in sources() {
            let key = source.server + "\u{1F}" + source.query
            if let cached = noteCache[key], now.timeIntervalSince(cached.date) < Self.noteInterval {
                if let note = cached.note { notes.append(note) }
            } else {
                stale.append((key, source.server, source.query))
            }
        }
        let fresh = await withTaskGroup(of: (String, SuggestionContext.ServiceNote?).self) { group in
            for item in stale {
                group.addTask {
                    let summary = await digest.collect(server: item.server, query: item.query)
                    let title = item.server.hasPrefix("claude.ai ") ? String(item.server.dropFirst(10)) : item.server
                    return (item.key, summary.map { SuggestionContext.ServiceNote(source: title, summary: $0) })
                }
            }
            var results: [(String, SuggestionContext.ServiceNote?)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (key, note) in fresh {
            noteCache[key] = (now, note)
            if let note { notes.append(note) }
        }
        return notes
    }

    /// Открытые программы с окнами — без фоновых служб, самого Runie и той, что впереди.
    private static func runningApps(excluding frontmost: String?) -> [String] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != own && $0.bundleIdentifier != frontmost }
            .compactMap(\.localizedName)
    }

    private static let eventStore = EKEventStore()

    /// Встречи на сегодня, которые ещё не закончились. Доступ к Календарю
    /// спрашивается один раз; без него подсказки строятся без встреч.
    private static func todayEvents(now: Date = Date()) async -> [SuggestionContext.Event] {
        let store = eventStore
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            break
        case .notDetermined:
            guard (try? await store.requestFullAccessToEvents()) == true else { return [] }
        default:
            return []
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map { SuggestionContext.Event(title: $0.title ?? "Событие", start: $0.startDate, isAllDay: $0.isAllDay) }
    }

    /// Имена файлов, изменённых за двое суток в Загрузках и на Рабочем столе.
    /// Только верхний уровень папок и только имена — содержимое не читается.
    nonisolated private static func recentFiles(now: Date = Date()) -> [SuggestionContext.RecentFile] {
        let fileManager = FileManager.default
        let folders: [(FileManager.SearchPathDirectory, String)] = [
            (.downloadsDirectory, "Загрузки"),
            (.desktopDirectory, "Рабочий стол")
        ]
        var files: [SuggestionContext.RecentFile] = []
        for (directory, title) in folders {
            guard let url = fileManager.urls(for: directory, in: .userDomainMask).first,
                  let items = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                  )
            else { continue }
            for item in items {
                guard let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modified) < 48 * 3600
                else { continue }
                files.append(.init(name: item.lastPathComponent, folder: title, modified: modified))
            }
        }
        return Array(files.sorted { $0.modified > $1.modified }.prefix(8))
    }
}
