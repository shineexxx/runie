import Foundation
import Testing
@testable import RunieKit

@Suite("Сбор файлов")
struct FileCollectorTests {

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runie-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("мимо идут системное, скрытое и папки сборок")
    func skipping() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(FileCollector.isWorthIndexing(home.appending(path: "Documents/смета.pdf")))
        #expect(FileCollector.isWorthIndexing(home.appending(path: "Desktop/Проект/заметки.md")))
        #expect(!FileCollector.isWorthIndexing(home.appending(path: "Library/Caches/что-то.txt")))
        #expect(!FileCollector.isWorthIndexing(home.appending(path: "Проект/node_modules/react/index.js")))
        #expect(!FileCollector.isWorthIndexing(home.appending(path: "Проект/.git/config")))
        #expect(!FileCollector.isWorthIndexing(home.appending(path: "Документы/.скрытый.txt")))
        #expect(!FileCollector.isWorthIndexing(home.appending(path: "Проект/build/main.o")))
        #expect(!FileCollector.isWorthIndexing(home.appending(path: "Applications/Runie.app/Contents/Info.plist")))
    }

    @Test("текст читается у разметки и обычных файлов, у чужого — нет")
    func text() throws {
        let folder = try makeFolder()
        let collector = FileCollector()
        let markdown = try write("# Смета\n\nПлитка — 40 тысяч", to: folder.appending(path: "смета.md"))
        #expect(collector.text(of: markdown)?.contains("Плитка") == true)

        // Картинка: расширение не текстовое — содержимое не читаем.
        let image = try write("не важно", to: folder.appending(path: "фото.jpg"))
        #expect(collector.text(of: image) == nil)

        // Двоичное под видом текста: внутри нули.
        let fake = folder.appending(path: "странный.txt")
        try Data([0x00, 0x01, 0x02, 0x00, 0x41]).write(to: fake)
        #expect(collector.text(of: fake) == nil)

        // Пустой файл читать нечего.
        try write("", to: folder.appending(path: "пусто.txt"))
        #expect(collector.text(of: folder.appending(path: "пусто.txt")) == nil)
    }

    @Test("длинный текст обрезается, тяжёлый файл не читается")
    func limits() throws {
        let folder = try makeFolder()
        // Предел размера считается в байтах, а «я» занимает два.
        var collector = FileCollector(options: .init(maxFileSize: 200, maxTextLength: 20))
        let long = try write(String(repeating: "я", count: 40), to: folder.appending(path: "длинный.txt"))
        #expect(collector.text(of: long)?.count == 20)

        let heavy = try write(String(repeating: "я", count: 500), to: folder.appending(path: "тяжёлый.txt"))
        #expect(collector.text(of: heavy) == nil)

        collector.options.maxFileSize = 8 * 1024 * 1024
        #expect(collector.text(of: heavy)?.count == 20)
    }

    @Test("запись: имя без расширения как заголовок, папка и вид рядом")
    func item() throws {
        let folder = try makeFolder()
        let collector = FileCollector()
        let file = try write("Плитка и работа", to: folder.appending(path: "Смета на ремонт.md"))
        let item = try #require(collector.item(for: file))
        #expect(item.source == .files)
        #expect(item.title == "Смета на ремонт")
        #expect(item.body == "Плитка и работа")
        #expect(item.externalID == file.path)
        #expect(item.details["kind"] == "md")
        #expect(item.details["folder"] == folder.lastPathComponent)

        // Папку в указатель не кладём.
        #expect(collector.item(for: folder) == nil)
        #expect(collector.item(for: folder.appending(path: "нет-такого.txt")) == nil)
    }

    @Test("обход кладёт файлы в указатель и помечает время")
    func scan() async throws {
        let folder = try makeFolder()
        try write("Плитка — 40 тысяч", to: folder.appending(path: "смета.md"))
        try write("Горы, море, сентябрь", to: folder.appending(path: "отпуск.txt"))
        try write("не индексируется", to: folder.appending(path: "node_modules/пакет/файл.js"))

        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        // Своя папка вместо Spotlight: во временных папках он ничего не знает.
        let collector = FileCollector(options: .init(roots: [folder]))
        let urls = try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            // Сама база и её спутники (-wal, -shm) в указатель не идут.
            .filter { FileCollector.isWorthIndexing($0) && !$0.lastPathComponent.hasPrefix("index.sqlite") }
        for url in urls {
            if let item = collector.item(for: url) { try store.put(item) }
        }
        try store.markScanned(.files)

        #expect(try store.count(source: .files) == 2)
        #expect(try store.searchByWords("плитка").first?.item.title == "смета")
        #expect(try store.searchByWords("сентябрь").first?.item.title == "отпуск")
        #expect(store.lastScan(of: .files) != nil)
    }
}
