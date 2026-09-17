import Testing
@testable import RunieKit

@Suite("Разметка ответа")
struct MarkdownBlocksTests {

    @Test("абзацы, заголовки, черта")
    func basics() {
        let blocks = MarkdownBlock.parse("## План\nПервая строка\nвторая\n\n---\nКонец")
        #expect(blocks == [
            .heading(level: 2, text: "План"),
            .paragraph("Первая строка\nвторая"),
            .rule,
            .paragraph("Конец")
        ])
        #expect(MarkdownBlock.parse("#хэштег") == [.paragraph("#хэштег")])
    }

    @Test("списки: маркеры, номера, вложенность, продолжение, задачи")
    func lists() {
        let blocks = MarkdownBlock.parse("- один\n  продолжение\n  - вложенный\n2. второй\n- [x] сделано\n- [ ] нет")
        #expect(blocks == [
            .listItem(level: 0, marker: "•", text: "один\nпродолжение"),
            .listItem(level: 1, marker: "•", text: "вложенный"),
            .listItem(level: 0, marker: "2.", text: "второй"),
            .listItem(level: 0, marker: "☑", text: "сделано"),
            .listItem(level: 0, marker: "☐", text: "нет")
        ])
        // «2026. год» и «*жирный*» — не списки.
        #expect(MarkdownBlock.parse("2026. год") == [.paragraph("2026. год")])
        #expect(MarkdownBlock.parse("*жирный*") == [.paragraph("*жирный*")])
    }

    @Test("код: язык, пустые строки внутри, незакрытый при печати")
    func code() {
        #expect(MarkdownBlock.parse("Смотри:\n```swift\nlet a = 1\n\n# не заголовок\n```\nГотово") == [
            .paragraph("Смотри:"),
            .code(language: "swift", text: "let a = 1\n\n# не заголовок"),
            .paragraph("Готово")
        ])
        #expect(MarkdownBlock.parse("```\nls -la") == [.code(language: nil, text: "ls -la")])
    }

    @Test("цитата и таблица")
    func quoteAndTable() {
        #expect(MarkdownBlock.parse("> важно\n> очень") == [.quote("важно\nочень")])
        let table = MarkdownBlock.parse("| Файл | Размер |\n|---|---:|\n| a.png | 2 МБ |\n| b.png |")
        #expect(table == [.table(header: ["Файл", "Размер"], rows: [["a.png", "2 МБ"], ["b.png", ""]])])
        // Без разделителя — просто текст.
        #expect(MarkdownBlock.parse("| не таблица |") == [.paragraph("| не таблица |")])
    }
}
