import Foundation
import Testing
@testable import RunieKit

@Suite("Сбор почты")
struct MailCollectorTests {

    private func makeMailFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runie-mail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "V10/Аккаунт.mbox/Messages"), withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeMessage(_ text: String, named name: String, in root: URL, date: Date? = nil) throws -> URL {
        let url = root.appending(path: "V10/Аккаунт.mbox/Messages/\(name).emlx")
        let body = Data(text.utf8)
        try (Data("\(body.count)\n".utf8) + body).write(to: url)
        if let date {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return url
    }

    private func letter(subject: String, from: String, body: String) -> String {
        """
        From: \(from)
        Subject: \(subject)
        Date: Mon, 21 Sep 2026 14:32:10 +0300
        Content-Type: text/plain; charset=utf-8

        \(body)
        """
    }

    @Test("письма находятся по всей папке Почты, новые первыми")
    func files() throws {
        let root = try makeMailFolder()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_790_000_000)
        try writeMessage(letter(subject: "Старое", from: "a@b.c", body: "текст"), named: "1", in: root, date: old)
        try writeMessage(letter(subject: "Новое", from: "a@b.c", body: "текст"), named: "2", in: root, date: new)
        // Не письмо — не берём.
        try Data("мусор".utf8).write(to: root.appending(path: "V10/Аккаунт.mbox/Messages/заметка.txt"))

        let collector = MailCollector(mailDirectory: root)
        #expect(collector.canReadFiles)
        let all = collector.files(newerThan: nil, limit: 10)
        #expect(all.count == 2)
        #expect(all.first?.date == new)

        // Только то, что появилось после прошлого обхода.
        let fresh = collector.files(newerThan: Date(timeIntervalSince1970: 1_750_000_000), limit: 10)
        #expect(fresh.count == 1)

        // Предел соблюдается и оставляет самое свежее.
        #expect(collector.files(newerThan: nil, limit: 1).first?.date == new)
    }

    @Test("обход кладёт письма в указатель с темой, отправителем и текстом")
    func scan() async throws {
        let root = try makeMailFolder()
        try writeMessage(letter(subject: "Смета на кухню", from: "Саша <sasha@example.com>",
                                body: "Плитка — 40 000 ₽, работа — 25 000 ₽."), named: "1", in: root)
        try writeMessage(letter(subject: "Счёт за интернет", from: "billing@example.com",
                                body: "Оплатите до пятницы."), named: "2", in: root)

        let store = try IndexStore(url: root.appending(path: "index.sqlite"))
        let collector = MailCollector(mailDirectory: root)
        let indexed = try await collector.scan(into: store)
        #expect(indexed == 2)
        #expect(try store.count(source: .mail) == 2)

        let found = try #require(try store.searchByWords("плитка").first)
        #expect(found.item.title == "Смета на кухню")
        #expect(found.item.details["from"] == "Саша <sasha@example.com>")
        #expect(found.item.body.contains("40 000"))
        #expect(store.lastScan(of: .mail) != nil)

        // Второй обход не двоит записи: письма те же.
        let again = try await collector.scan(into: store, since: nil)
        #expect(try store.count(source: .mail) == 2)
        #expect(again >= 0)
    }

    @Test("история добирается порциями, пока письма не кончатся")
    func history() async throws {
        let root = try makeMailFolder()
        for index in 1...5 {
            try writeMessage(letter(subject: "Письмо \(index)", from: "a@b.c", body: "текст"),
                             named: "\(index)", in: root,
                             date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400))
        }
        let store = try IndexStore(url: root.appending(path: "index.sqlite"))
        var collector = MailCollector(mailDirectory: root)
        collector.recentLimit = 2

        // Первый проход берёт два самых новых и запоминает, докуда дошёл.
        #expect(try await collector.scan(into: store, limit: 2) == 2)
        let depth = try #require(store.mark(MailCollector.depthMark))

        // Следующий — ещё два, уже старее отметки.
        #expect(try await collector.scan(into: store, limit: 2) == 2)
        #expect(try store.count(source: .mail) == 4)
        #expect(try #require(store.mark(MailCollector.depthMark)) < depth)

        // И так до конца: пятое письмо, дальше добирать нечего.
        #expect(try await collector.scan(into: store, limit: 2) == 1)
        #expect(try store.count(source: .mail) == 5)
        #expect(try await collector.scan(into: store, limit: 2) == 0)
    }

    @Test("без доступа к папке идём запасным путём")
    func noAccess() {
        let collector = MailCollector(mailDirectory: URL(fileURLWithPath: "/такой/папки/нет"))
        #expect(!collector.canReadFiles)
        #expect(collector.files(newerThan: nil, limit: 10).isEmpty)
    }

    @Test("ответ скрипта разбирается в письма")
    func script() {
        let collector = MailCollector()
        let separator = AppleScriptRunner.fieldSeparator
        let output = [
            ["12345", "Смета на кухню", "Саша <sasha@example.com>", "2026-09-21T14:32:10", "Плитка — 40 000 ₽"],
            ["12346", "", "billing@example.com", "2026-09-20T10:00:00", "Оплатите счёт"]
        ].map { $0.joined(separator: separator) }.joined(separator: AppleScriptRunner.recordSeparator)

        let items = collector.itemsFromScript(output)
        #expect(items.count == 2)
        #expect(items.first?.externalID == "message:12345")
        #expect(items.first?.details["from"] == "Саша <sasha@example.com>")
        #expect(items.first?.source == .mail)
        // Письмо без темы всё равно попадает в указатель — по тексту его найдут.
        #expect(items.last?.title == t("Письмо без темы"))
        #expect(collector.itemsFromScript("").isEmpty)
    }

    @Test("в скрипте стоит предел на число писем")
    func scriptLimit() {
        #expect(MailCollector.recentScript(limit: 50).contains("set lastOne to 50"))
        #expect(MailCollector.recentScript(limit: 50).contains("date received"))
    }
}
