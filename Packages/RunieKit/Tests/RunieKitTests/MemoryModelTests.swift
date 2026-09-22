import Foundation
import Testing
@testable import RunieKit

/// Модель весит 54 МБ и лежит не в репозитории, а в папке приложения: тесты,
/// которым нужна матрица, идут только если человек её скачал.
@Suite("Смысловой поиск")
struct MemoryModelTests {

    private static let model = try? MemoryModel()

    private struct Reference: Decodable {
        let text: String
        let ids: [Int]
        let tokens: [String]
    }

    @Test("токенизатор разбирает фразы так же, как библиотека")
    func tokenizer() throws {
        let data = try FixtureLoader.data(named: "wordpiece.json")
        let references = try JSONDecoder().decode([Reference].self, from: data)
        let tokenizer = try #require(Self.model?.tokenizer, "модель не скачана — тест пропущен")
        for reference in references {
            #expect(tokenizer.encode(reference.text) == reference.ids, "\(reference.text) → \(reference.tokens)")
        }
    }

    @Test("близкие по смыслу фразы ближе, чем чужие")
    func similarity() throws {
        let model = try #require(Self.model, "модель не скачана — тест пропущен")
        let anchor = try #require(model.embed("Скриншоты сначала показывать, потом заливать в git"))
        let close = try #require(model.embed("правило про картинки перед коммитом"))
        let far = try #require(model.embed("Любит кофе по утрам"))
        #expect(MemoryModel.similarity(anchor, close) > MemoryModel.similarity(anchor, far))
        #expect(model.embed("   ") == nil)
        #expect(model.dimensions == 256)
    }

    @Test("вектор единичной длины")
    func normalized() throws {
        let model = try #require(Self.model, "модель не скачана — тест пропущен")
        let vector = try #require(model.embed("проверка длины"))
        var norm: Float = 0
        for value in vector { norm += value * value }
        #expect(abs(norm.squareRoot() - 1) < 0.001)
    }

    @Test("со смыслом поиск находит то, что сказано другими словами")
    func semantic() throws {
        let model = try #require(Self.model, "модель не скачана — тест пропущен")
        let corpus = [
            "Скриншоты сначала показывать, потом заливать в git",
            "Проект RUN365: заказчики Александр и Валентин, отчёты в Telegram",
            "Предпочитает короткие ответы без воды",
            "Любит кофе по утрам и разбор дня в 9:00",
            "Репозиторий Runie публичный под лицензией MIT",
            "Не спрашивать разрешение дважды на одно и то же",
            "Встреча с Аней по поводу фотографий со съёмки",
            "Долгая память лежит в Документах, папка Runie, Memory"
        ]
        let facts = corpus.map {
            MemoryStore.Fact(name: MemoryStore.slug(for: $0), kind: .user, description: $0, body: "")
        }
        // Ни одного общего слова с записью — по словам такое не найти.
        let paraphrases = [
            ("кто заказчик run365", 1),
            ("любит краткость", 2),
            ("prefers short replies", 2),
            ("под какой лицензией код", 4),
            ("не переспрашивай одно и то же", 5),
            ("фото для ани", 6),
            ("где лежат файлы памяти", 7)
        ]
        for (query, expected) in paraphrases {
            let found = MemorySearch.search(query, in: facts, model: model).first?.fact.description
            #expect(found == corpus[expected], "«\(query)» → \(found ?? "ничего")")
        }
        // Без модели половина этих запросов не находится вовсе.
        let lexicalOnly = paraphrases.filter {
            MemorySearch.search($0.0, in: facts).first?.fact.description == corpus[$0.1]
        }
        #expect(lexicalOnly.count < paraphrases.count)
        // Чужое не выдаём за своё.
        #expect(MemorySearch.search("рецепт борща с пампушками", in: facts, model: model).isEmpty)
    }

    @Test("без файлов модель не грузится")
    func missing() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("runie-no-model-\(UUID().uuidString)")
        #expect(!MemoryModel.isInstalled(in: empty))
        #expect(throws: MemoryModel.Failure.notInstalled) { try MemoryModel(directory: empty) }
    }
}
