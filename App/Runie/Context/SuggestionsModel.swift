import AppKit
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

    init(store: ChatHistoryStore) {
        self.store = store
        generator = (try? ClaudeCodeLocator().locate()).map { ClaudeSuggestionGenerator(executable: $0) }
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
            if let app {
                // Пока ИИ думает — подсказки под семейство приложения.
                current = Suggestion.fixed(app.suggestions)
            }
            // Последнее придуманное приветствие лучше шаблонного, если время суток то же.
            greeting = last.flatMap { Self.stillFits($0) ? $0.set.greeting : nil }
                ?? SuggestionSet.fallbackGreeting()
        }

        guard let generator, task == nil else { return }
        let appName = app?.name
        let previous = current.map(\.label)
        let store = store
        isGenerating = true
        task = Task { [weak self] in
            // Файлы и история — не в главном потоке: первый доступ к Загрузкам
            // вызывает системный запрос, и чат не должен его ждать.
            let context = await Task.detached(priority: .utility) {
                SuggestionContext(
                    date: Date(),
                    appName: appName,
                    recentFiles: SuggestionsModel.recentFiles(),
                    recentConversations: store.list().prefix(5).map(\.title),
                    previousSuggestions: previous
                )
            }.value
            let result = try? await generator.generate(context)
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
