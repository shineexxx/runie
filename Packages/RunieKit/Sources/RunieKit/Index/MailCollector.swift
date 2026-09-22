import Foundation

/// Собирает почту в указатель.
///
/// Двумя путями. Основной — читать файлы писем в `~/Library/Mail` напрямую:
/// это тысячи писем в минуту. Папка защищена, поэтому нужен полный доступ к
/// диску — тот самый, про который спрашивает окно указателя.
///
/// Запасной — через Apple Events у самой Почты. Работает без доступа к диску,
/// но втрое медленнее одного письма в секунду: у Почты каждое обращение идёт
/// межпроцессным сообщением. Поэтому так берутся только последние письма.
public struct MailCollector: Sendable {

    public static let bundleID = "com.apple.mail"

    /// Сколько писем берём запасным путём за один обход.
    public var recentLimit = 200
    /// Сколько знаков письма кладём в указатель.
    public var maxTextLength = 20_000
    /// Папка Почты. В тестах подменяется своей.
    public var mailDirectory: URL

    public init(mailDirectory: URL? = nil) {
        self.mailDirectory = mailDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mail")
    }

    /// Доступна ли папка Почты: это и есть проверка на полный доступ к диску.
    public var canReadFiles: Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: mailDirectory.path) else {
            return false
        }
        return !contents.isEmpty
    }

    // MARK: Файлы писем

    /// Файлы писем, изменённые после `since`, новые первыми.
    func files(changedSince since: Date?, limit: Int) -> [(url: URL, date: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: mailDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [(URL, Date)] = []
        for case let url as URL in walker {
            guard url.pathExtension == "emlx" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let date = values?.contentModificationDate ?? Date()
            if let since, date <= since { continue }
            found.append((url, date))
        }
        // Новые письма важнее: если упрёмся в предел, пусть это будут свежие.
        return Array(found.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    func item(from message: MailMessage, url: URL, fallbackDate: Date) -> IndexStore.Item {
        IndexStore.Item(
            source: .mail,
            // Путь к файлу заодно даёт письму постоянный номер в указателе.
            externalID: url.path,
            title: message.subject.isEmpty ? t("Письмо без темы") : message.subject,
            body: message.body,
            date: message.date ?? fallbackDate,
            details: message.sender.isEmpty ? [:] : ["from": message.sender]
        )
    }

    /// Обходит почту и складывает её в указатель. Возвращает, сколько положил.
    @discardableResult
    public func scan(
        into store: IndexStore,
        model: MemoryModel? = nil,
        since: Date? = nil,
        limit: Int = 5_000,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        let start = Date()
        let since = since ?? store.lastScan(of: .mail)
        var indexed = 0

        if canReadFiles {
            for (url, date) in files(changedSince: since, limit: limit) {
                try Task.checkCancellation()
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let message = MailMessage.parse(emlx: data, maxBodyLength: maxTextLength)
                else { continue }
                let item = item(from: message, url: url, fallbackDate: date)
                let vector = model?.embed(item.title + " " + String(item.body.prefix(1_000)))
                try store.put(item, vector: vector)
                indexed += 1
                if indexed % 50 == 0 {
                    progress?(indexed)
                    await Task.yield()
                }
            }
        } else {
            indexed = try await scanWithAppleEvents(into: store, model: model, since: since, progress: progress)
        }

        try store.markScanned(.mail, at: start)
        progress?(indexed)
        return indexed
    }

    // MARK: Запасной путь

    /// Скрипт берёт последние письма разом: свойства списками, а не по одному.
    static func recentScript(limit: Int) -> String {
        """
        set fieldSep to (ASCII character 1)
        set recordSep to (ASCII character 2)
        tell application "Mail"
            set box to inbox
            set total to count of messages of box
            if total is 0 then return ""
            set lastOne to \(limit)
            if total < lastOne then set lastOne to total
            set subjects to subject of messages 1 thru lastOne of box
            set senders to sender of messages 1 thru lastOne of box
            set stamps to date received of messages 1 thru lastOne of box
            set numbers to id of messages 1 thru lastOne of box
            set bodies to content of messages 1 thru lastOne of box
        end tell
        set pieces to {}
        repeat with i from 1 to count of numbers
            set end of pieces to ((item i of numbers) & fieldSep & (item i of subjects) & fieldSep & (item i of senders) & fieldSep & ((item i of stamps) as «class isot» as string) & fieldSep & (item i of bodies))
        end repeat
        set AppleScript's text item delimiters to recordSep
        set out to pieces as text
        set AppleScript's text item delimiters to ""
        return out
        """
    }

    /// Письма из ответа скрипта.
    func itemsFromScript(_ output: String) -> [IndexStore.Item] {
        AppleScriptRunner.parse(output).compactMap { fields in
            guard fields.count >= 5, !fields[0].isEmpty else { return nil }
            let body = fields[4...].joined(separator: AppleScriptRunner.fieldSeparator)
            return IndexStore.Item(
                source: .mail,
                externalID: "message:" + fields[0],
                title: fields[1].isEmpty ? t("Письмо без темы") : fields[1],
                body: String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTextLength)),
                date: AppleScriptRunner.date(fromISO: fields[3]) ?? Date(),
                details: fields[2].isEmpty ? [:] : ["from": fields[2]]
            )
        }
    }

    private func scanWithAppleEvents(
        into store: IndexStore,
        model: MemoryModel?,
        since: Date?,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> Int {
        guard AppleScriptRunner.isRunning(bundleID: Self.bundleID) else {
            throw AppleScriptRunner.Failure.notRunning(t("Почта"))
        }
        let output = try await AppleScriptRunner.run(Self.recentScript(limit: recentLimit))
        var indexed = 0
        for item in itemsFromScript(output) {
            try Task.checkCancellation()
            if let since, item.date <= since { continue }
            let vector = model?.embed(item.title + " " + String(item.body.prefix(1_000)))
            try store.put(item, vector: vector)
            indexed += 1
            if indexed % 25 == 0 {
                progress?(indexed)
                await Task.yield()
            }
        }
        return indexed
    }
}
