import Foundation
import Observation
import RunieKit

/// Указатель со стороны приложения: что включено, сколько собрано, идёт ли обход.
///
/// Сам по себе не начинает ничего: пока человек не включил источник, указателя
/// нет вовсе. Обход идёт в фоне и прерывается, если источник выключили.
@MainActor
@Observable
final class IndexModel {

    static let shared = IndexModel()

    /// Включённые источники. Лежат в настройках, чтобы пережить перезапуск.
    private(set) var enabled: Set<IndexStore.Source> = []
    /// Сколько записей в указателе по источникам.
    private(set) var counts: [IndexStore.Source: Int] = [:]
    /// Какой источник сейчас обходится и сколько уже собрано.
    fileprivate(set) var scanning: (source: IndexStore.Source, done: Int)?
    private(set) var failure: String?

    private static let key = "index.sources"

    private var store: IndexStore?
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        enabled = Set(saved.compactMap(IndexStore.Source.init(rawValue:)))
        refreshCounts()
    }

    /// Указатель открывается при первом обращении: без включённых источников
    /// файл базы вообще не нужен.
    private func openStore() -> IndexStore? {
        if let store { return store }
        do {
            let store = try IndexStore()
            self.store = store
            return store
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    var isScanning: Bool { scanning != nil }

    /// Указатель собран хоть по чему-то.
    var hasAnything: Bool { counts.values.contains { $0 > 0 } }

    func setEnabled(_ source: IndexStore.Source, _ isOn: Bool) {
        if isOn { enabled.insert(source) } else { enabled.remove(source) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: Self.key)
        if isOn {
            rescan(source)
        } else {
            // Выключили — стираем собранное: человек отказался, значит отказался.
            task?.cancel()
            try? openStore()?.removeAll(source: source)
            refreshCounts()
        }
    }

    /// Обходит источник заново. Уже идущий обход отменяется.
    func rescan(_ source: IndexStore.Source, full: Bool = false) {
        guard enabled.contains(source), let store = openStore() else { return }
        task?.cancel()
        failure = nil
        scanning = (source, 0)
        let model = MemoryModelInstaller.shared.model
        task = Task { [weak self] in
            do {
                switch source {
                case .files:
                    var options = FileCollector.Options()
                    #if DEBUG
                    // `-RunieIndexRoot /путь` — обходить только эту папку, для проверок.
                    if let root = UserDefaults.standard.string(forKey: "RunieIndexRoot") {
                        options.roots = [URL(fileURLWithPath: root)]
                    }
                    #endif
                    let collector = FileCollector(options: options)
                    try await collector.scan(into: store, model: model, since: full ? .distantPast : nil) { done in
                        Task { @MainActor in
                            let index = IndexModel.shared
                            guard index.scanning?.source == source else { return }
                            index.scanning = (source, done)
                        }
                    }
                default:
                    // Остальные источники ещё не собираются.
                    break
                }
            } catch is CancellationError {
                // Человек выключил источник или закрыл настройки — это не ошибка.
            } catch {
                self?.failure = error.localizedDescription
            }
            guard let self else { return }
            scanning = nil
            refreshCounts()
        }
    }

    /// Стирает указатель целиком.
    func removeEverything() {
        task?.cancel()
        scanning = nil
        guard let store = openStore() else { return }
        for source in IndexStore.Source.allCases {
            try? store.removeAll(source: source)
        }
        enabled = []
        UserDefaults.standard.set([String](), forKey: Self.key)
        refreshCounts()
    }

    func refreshCounts() {
        guard let store else {
            counts = [:]
            return
        }
        var counts: [IndexStore.Source: Int] = [:]
        for source in IndexStore.Source.allCases {
            counts[source] = (try? store.count(source: source)) ?? 0
        }
        self.counts = counts
    }

    /// Поиск для инструмента агента.
    nonisolated func search(_ query: String, sources: Set<IndexStore.Source>?, limit: Int) async throws -> [IndexStore.Hit] {
        let (store, model) = await MainActor.run {
            (self.openStore(), MemoryModelInstaller.shared.model)
        }
        guard let store else { return [] }
        return try IndexSearch(store: store, model: model).search(query, sources: sources, limit: limit)
    }
}
