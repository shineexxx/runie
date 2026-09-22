import Foundation

/// Поиск по указателю: слова и смысл вместе.
///
/// Два списка приходят в разных шкалах — bm25 у полнотекста, косинус у векторов, —
/// поэтому складываем не оценки, а места: запись, высокая в обоих списках,
/// обгоняет ту, что хороша только в одном. Это слияние рангов, обычный приём для
/// смешанного поиска.
public struct IndexSearch: Sendable {

    private let store: IndexStore
    private let model: MemoryModel?

    public init(store: IndexStore, model: MemoryModel? = nil) {
        self.store = store
        self.model = model
    }

    /// Сколько записей смотрим в каждом из двух списков, прежде чем слить.
    private static let depth = 40
    /// Смягчает разницу между первым и вторым местом — стандартное значение.
    private static let softening = 20.0

    public func search(
        _ query: String,
        sources: Set<IndexStore.Source>? = nil,
        limit: Int = 8
    ) throws -> [IndexStore.Hit] {
        var ranks: [Int64: Double] = [:]
        var items: [Int64: IndexStore.Item] = [:]

        let byWords = try store.searchByWords(query, sources: sources, limit: Self.depth)
        for (rank, hit) in byWords.enumerated() {
            // Ключ — источник и внешний номер: по нему списки и сходятся.
            let id = try key(for: hit.item)
            ranks[id, default: 0] += 1 / (Self.softening + Double(rank))
            items[id] = hit.item
        }

        if let model, let question = model.embed(query) {
            let vectors = try store.vectors(sources: sources)
            if vectors.count > 1 {
                let centered = Self.center(vectors.map(\.vector), question: question)
                var scored: [(Int64, Float)] = []
                for (index, entry) in vectors.enumerated() {
                    scored.append((entry.id, MemoryModel.similarity(centered.question, centered.vectors[index])))
                }
                scored.sort { $0.1 > $1.1 }
                let best = scored.prefix(Self.depth).filter { $0.1 >= Self.floor }
                let found = try store.items(ids: best.map(\.0))
                for (rank, entry) in best.enumerated() {
                    guard let item = found[entry.0] else { continue }
                    ranks[entry.0, default: 0] += 1 / (Self.softening + Double(rank))
                    items[entry.0] = item
                }
            }
        }

        return ranks
            .compactMap { id, score in items[id].map { IndexStore.Hit(item: $0, score: score) } }
            .sorted { $0.score > $1.score || ($0.score == $1.score && $0.item.date > $1.item.date) }
            .prefix(limit)
            .map { $0 }
    }

    /// Близость ниже этой — шум.
    private static let floor: Float = 0.10

    /// Номер записи в базе. Полнотекст и векторы приходят из одной таблицы,
    /// поэтому достаточно найти запись по источнику и внешнему номеру.
    private func key(for item: IndexStore.Item) throws -> Int64 {
        try store.identifier(source: item.source, externalID: item.externalID) ?? -1
    }

    /// Вычитает из векторов их общее среднее: без этого всё похоже на всё.
    private static func center(_ vectors: [[Float]], question: [Float]) -> (question: [Float], vectors: [[Float]]) {
        guard let dimensions = vectors.first?.count, dimensions > 0 else { return (question, vectors) }
        var mean = [Float](repeating: 0, count: dimensions)
        for vector in vectors where vector.count == dimensions {
            for index in 0..<dimensions { mean[index] += vector[index] }
        }
        let count = Float(vectors.count)
        for index in 0..<dimensions { mean[index] /= count }

        func centered(_ vector: [Float]) -> [Float] {
            guard vector.count == dimensions else { return vector }
            var result = [Float](repeating: 0, count: dimensions)
            var norm: Float = 0
            for index in 0..<dimensions {
                result[index] = vector[index] - mean[index]
                norm += result[index] * result[index]
            }
            norm = norm.squareRoot()
            return norm > 0 ? result.map { $0 / norm } : result
        }
        return (centered(question), vectors.map(centered))
    }
}
