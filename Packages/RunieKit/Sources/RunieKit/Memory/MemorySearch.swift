import Foundation

/// Поиск по фактам памяти: по словам, с поправкой на русские окончания.
///
/// Индекс фактов агент и так видит в промпте, поэтому поиск нужен, когда фактов
/// много или запрос сформулирован иначе, чем описание. Слова сравниваются по
/// основе: «скриншоты», «скриншот» и «скриншотов» — одно слово.
public enum MemorySearch {

    public struct Hit: Equatable, Sendable {
        public let fact: MemoryStore.Fact
        public let score: Double
    }

    /// Лучшие совпадения, по убыванию. Пустой запрос ничего не находит.
    public static func search(_ query: String, in facts: [MemoryStore.Fact], limit: Int = 5) -> [Hit] {
        let terms = Set(stems(query))
        guard !terms.isEmpty else { return [] }
        return facts
            .map { Hit(fact: $0, score: score($0, terms: terms)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score || ($0.score == $1.score && $0.fact.updated > $1.fact.updated) }
            .prefix(limit)
            .map { $0 }
    }

    /// Описание и имя весят больше тела: они и есть суть факта.
    private static func score(_ fact: MemoryStore.Fact, terms: Set<String>) -> Double {
        let description = Set(stems(fact.description))
        let name = Set(stems(fact.name.replacingOccurrences(of: "-", with: " ")))
        let body = Set(stems(fact.body))
        var score = 0.0
        for term in terms {
            if description.contains(term) { score += 3 }
            else if name.contains(term) { score += 2 }
            else if body.contains(term) { score += 1 }
        }
        // Доля покрытых слов запроса: «кто заказчик run365» с двумя совпадениями
        // выше, чем длинный факт с одним.
        let covered = terms.filter { description.contains($0) || name.contains($0) || body.contains($0) }.count
        return score * (0.5 + Double(covered) / Double(terms.count))
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
