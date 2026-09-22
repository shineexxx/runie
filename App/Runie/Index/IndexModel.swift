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

    /// Источники, которые Руни уже умеет собирать.
    static let available: [IndexStore.Source] = [.files, .mail, .notes]

    /// Человек уже решал, что индексировать. Пока не решал — включаем всё сами,
    /// когда доступ к диску выдан: он для того и выдавался.
    var didChoose: Bool { UserDefaults.standard.object(forKey: Self.key) != nil }

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

    /// Обновляет указатель по включённым источникам: при запуске и потом раз в час.
    ///
    /// Без этого указатель застывал бы на том, что было в день включения: обход
    /// запускался только нажатием переключателя.
    func start() {
        guard !enabled.isEmpty else { return }
        Task { @MainActor in
            // Даём приложению подняться: человек открыл Mac, ему не до обхода.
            try? await Task.sleep(for: .seconds(8))
            refreshAll()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { IndexModel.shared.refreshAll() }
        }
    }

    @ObservationIgnored private var timer: Timer?

    /// Ставит в очередь все включённые источники. Уже идущий обход не трогает.
    func refreshAll() {
        for source in Self.available where enabled.contains(source) && !queue.contains(source) {
            queue.append(source)
        }
        startNext()
    }

    /// Включает всё, что Руни умеет, и обходит по очереди.
    func enableEverything() {
        guard !isScanning else { return }
        enabled = Set(Self.available)
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: Self.key)
        queue = Self.available
        startNext()
    }

    func setEnabled(_ source: IndexStore.Source, _ isOn: Bool) {
        if isOn { enabled.insert(source) } else { enabled.remove(source) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: Self.key)
        if isOn {
            queue.append(source)
            if !isScanning { startNext() }
        } else {
            queue.removeAll { $0 == source }
            // Выключили — стираем собранное: человек отказался, значит отказался.
            // Чужой обход при этом не трогаем: он про другой источник.
            if scanning?.source == source {
                task?.cancel()
                scanning = nil
            }
            try? openStore()?.removeAll(source: source)
            refreshCounts()
            startNext()
        }
    }

    /// Очередь источников на обход: три сразу отменяли бы друг друга.
    @ObservationIgnored private var queue: [IndexStore.Source] = []

    private func startNext() {
        guard !isScanning, !queue.isEmpty else { return }
        rescan(queue.removeFirst())
    }

    /// Обходит источник заново. Уже идущий обход отменяется.
    func rescan(_ source: IndexStore.Source, full: Bool = false) {
        guard enabled.contains(source), let store = openStore() else {
            startNext()
            return
        }
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
                case .notes:
                    try await NotesCollector().scan(into: store, model: model, since: full ? .distantPast : nil) { done in
                        Task { @MainActor in
                            let index = IndexModel.shared
                            guard index.scanning?.source == source else { return }
                            index.scanning = (source, done)
                        }
                    }
                case .mail:
                    try await MailCollector().scan(into: store, model: model, since: full ? .distantPast : nil) { done in
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
            startNext()
        }
    }

    /// Стирает указатель целиком.
    func removeEverything() {
        task?.cancel()
        queue.removeAll()
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
