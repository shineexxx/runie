import Foundation

/// Поиск по фактам памяти: по словам, с поправкой на русские окончания.
///
/// Индекс фактов агент и так видит в промпте, поэтому поиск нужен, когда фактов
/// много или запрос сформулирован иначе, чем описание. Слова сравниваются по
/// основе: «скриншоты», «скриншот» и «скриншотов» — одно слово.
public enum MemorySearch {

    public struct Hit: Equatable, Sendable {
        public let fact: MemoryStore.Fact
        public let score: Float
    }

    /// Лучшие совпадения, по убыванию. Пустой запрос ничего не находит.
    ///
    /// Слова находят факт, где запрос и запись сказаны одинаково. Если человек
    /// скачал модель смыслового поиска, к этому добавляется близость по смыслу:
    /// «правило про картинки» находит запись про скриншоты.
    public static func search(
        _ query: String,
        in facts: [MemoryStore.Fact],
        model: MemoryModel? = nil,
        limit: Int = 5
    ) -> [Hit] {
        let terms = Set(stems(query))
        guard !terms.isEmpty else { return [] }
        // Балл за слова приводим к доле от возможного: совпало одно слово из трёх —
        // треть, а не единица. Иначе случайное общее слово перевесит смысл.
        let best = Float(terms.count) * 3 * 1.5
        var scores = facts.map { score($0, terms: terms) / best }
        if let model, let semantic = semanticScores(query, facts: facts, model: model) {
            for index in scores.indices {
                scores[index] += semanticWeight * semantic[index]
            }
        }
        var hits: [Hit] = []
        for (fact, score) in zip(facts, scores) where score > 0 {
            hits.append(Hit(fact: fact, score: score))
        }
        hits.sort { first, second in
            first.score == second.score ? first.fact.updated > second.fact.updated : first.score > second.score
        }
        return Array(hits.prefix(limit))
    }

    /// Насколько запрос близок каждому факту по смыслу, от 0 до 1.
    ///
    /// Векторы центрируются: у статической модели все фразы лежат в узком конусе,
    /// и без вычитания общей части близость почти не отличает своё от чужого.
    /// Слабую близость отбрасываем — это шум, а не находка.
    private static func semanticScores(
        _ query: String,
        facts: [MemoryStore.Fact],
        model: MemoryModel
    ) -> [Float]? {
        guard let question = model.embed(query) else { return nil }
        let vectors = facts.map { model.embed($0.description + " " + $0.body) }
        let dimensions = model.dimensions
        var mean = [Float](repeating: 0, count: dimensions)
        var count: Float = 0
        for vector in vectors.compactMap({ $0 }) {
            for index in 0..<dimensions { mean[index] += vector[index] }
            count += 1
        }
        guard count > 1 else { return nil }
        for index in 0..<dimensions { mean[index] /= count }

        func centered(_ vector: [Float]) -> [Float] {
            var result = [Float](repeating: 0, count: dimensions)
            var norm: Float = 0
            for index in 0..<dimensions {
                result[index] = vector[index] - mean[index]
                norm += result[index] * result[index]
            }
            norm = norm.squareRoot()
            return norm > 0 ? result.map { $0 / norm } : result
        }

        let asked = centered(question)
        let similarities = vectors.map { vector in
            vector.map { MemoryModel.similarity(asked, centered($0)) } ?? 0
        }
        // Находка — это когда один факт заметно ближе остальных. На чужой вопрос
        // («рецепт борща») все факты похожи одинаково слабо, и отрыва нет.
        if similarities.count > 1 {
            let ranked = similarities.sorted(by: >)
            guard ranked[0] - ranked[1] >= semanticMargin else { return nil }
        }
        return similarities.map { $0 >= semanticFloor ? $0 : 0 }
    }

    /// Близость ниже этой — шум, а не находка.
    private static let semanticFloor: Float = 0.10
    /// Насколько ближайший факт должен опережать следующий.
    private static let semanticMargin: Float = 0.10
    /// Насколько смысл весомее совпадения слов. Подобрано на наборе запросов,
    /// где спрашивают другими словами, чем записано.
    private static let semanticWeight: Float = 2.5

    /// Описание и имя весят больше тела: они и есть суть факта.
    private static func score(_ fact: MemoryStore.Fact, terms: Set<String>) -> Float {
        let description = Set(stems(fact.description))
        let name = Set(stems(fact.name.replacingOccurrences(of: "-", with: " ")))
        let body = Set(stems(fact.body))
        var score: Float = 0
        for term in terms {
            if description.contains(term) { score += 3 }
            else if name.contains(term) { score += 2 }
            else if body.contains(term) { score += 1 }
        }
        // Доля покрытых слов запроса: «кто заказчик run365» с двумя совпадениями
        // выше, чем длинный факт с одним.
        let covered = terms.filter { description.contains($0) || name.contains($0) || body.contains($0) }.count
        return score * (0.5 + Float(covered) / Float(terms.count))
    }

    /// Слова текста, приведённые к основе.
    static func stems(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
            .map(stem)
    }

    /// Грубая основа: у длинных слов отрезается хвост, где живут окончания.
    /// Для латиницы и коротких слов — как есть.
    private static func stem(_ word: String) -> String {
        guard word.count > 4, word.unicodeScalars.contains(where: { cyrillic.contains($0) }) else {
            return word.count > 6 ? String(word.prefix(6)) : word
        }
        let keep = max(4, word.count - (word.count >= 8 ? 3 : 2))
        return String(word.prefix(keep))
    }

    private static let cyrillic = CharacterSet(charactersIn: "абвгдежзийклмнопрстуфхцчшщъыьэюя")

    private static let stopWords: Set<String> = [
        "и", "в", "во", "на", "не", "что", "он", "она", "это", "как", "по", "но", "из", "за", "от", "до",
        "для", "или", "то", "же", "у", "с", "со", "о", "об", "при", "про", "мне", "меня", "мой", "моя",
        "the", "a", "an", "of", "to", "in", "on", "is", "it", "for", "and", "or", "my", "me", "i"
    ]
}
