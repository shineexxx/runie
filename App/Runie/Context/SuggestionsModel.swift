import AppKit
import Observation
import RunieKit

/// Подсказки под полем ввода, которые придумывает ИИ.
///
/// Чат их никогда не ждёт: при открытии сразу стоят последние подсказки для этого
/// приложения (или обычные), а новые придумываются в фоне и плавно подменяют старые.
/// Для одного приложения — не чаще раза в `refreshInterval`, чтобы не тратить лимит.
@MainActor
@Observable
final class SuggestionsModel {

    private(set) var current: [Suggestion] = []
    private(set) var isGenerating = false

    @ObservationIgnored private let generator: ClaudeSuggestionGenerator?
    @ObservationIgnored private let store: ChatHistoryStore
    @ObservationIgnored private var cache: [String: (date: Date, suggestions: [Suggestion])] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let refreshInterval: TimeInterval = 20 * 60
    private static let lastKey = "suggestions.last"

    init(store: ChatHistoryStore) {
        self.store = store
        generator = (try? ClaudeCodeLocator().locate()).map { ClaudeSuggestionGenerator(executable: $0) }
        let saved = UserDefaults.standard.data(forKey: Self.lastKey)
            .flatMap { try? JSONDecoder().decode([Suggestion].self, from: $0) }
        current = saved ?? Suggestion.fixed(ContextSuggestions.fallback)
    }

    /// Вызывается при открытии чата.
    func refresh(for app: AppContext?) {
        let key = app?.bundleIdentifier ?? "none"

        if let cached = cache[key] {
            current = cached.suggestions
            if Date().timeIntervalSince(cached.date) < Self.refreshInterval { return }
        } else if let app {
            // Пока ИИ думает — подсказки под семейство приложения.
            current = Suggestion.fixed(app.suggestions)
        }

        guard let generator, task == nil else { return }
        let context = SuggestionContext(
            date: Date(),
            appName: app?.name,
            recentFiles: Self.recentFiles(),
            recentConversations: store.list().prefix(5).map(\.title),
            previousSuggestions: current.map(\.label)
        )
        isGenerating = true
        task = Task { [weak self] in
            let result = try? await generator.generate(context)
            guard let self else { return }
            self.task = nil
            self.isGenerating = false
            guard let result, result.count >= 2 else { return }
            let suggestions = Array(result.prefix(2))
            self.cache[key] = (Date(), suggestions)
            self.current = suggestions
            UserDefaults.standard.set(try? JSONEncoder().encode(suggestions), forKey: Self.lastKey)
        }
    }

    // MARK: - Данные

    /// Имена файлов, изменённых за двое суток в Загрузках и на Рабочем столе.
    /// Только верхний уровень папок и только имена — содержимое не читается.
    private static func recentFiles(now: Date = Date()) -> [SuggestionContext.RecentFile] {
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
