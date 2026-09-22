import Foundation

/// Собирает заметки в указатель.
///
/// Через Apple Events: свойства запрашиваются у Заметок сразу списками, поэтому
/// несколько сотен заметок читаются за доли секунды. Поштучный обход был бы в
/// сотни раз медленнее — каждое обращение идёт через межпроцессное сообщение.
///
/// Полный доступ к диску для этого не нужен: хватает разрешения управлять
/// Заметками. Но если Заметки закрыты, обход пропускается — Руни не открывает
/// чужие программы сам.
public struct NotesCollector: Sendable {

    public static let bundleID = "com.apple.Notes"

    public init() {}

    /// Одна заметка в ответе скрипта.
    struct Row {
        let id: String
        let title: String
        let date: Date
        let body: String
    }

    /// Скрипт просит у Заметок всё сразу: списками, а не по одной.
    static let script = """
    set fieldSep to (ASCII character 1)
    set recordSep to (ASCII character 2)
    tell application "Notes"
        set noteIds to id of notes
        set noteNames to name of notes
        set noteStamps to modification date of notes
        set noteBodies to plaintext of notes
    end tell
    set pieces to {}
    repeat with i from 1 to count of noteIds
        set end of pieces to ((item i of noteIds) & fieldSep & (item i of noteNames) & fieldSep & ((item i of noteStamps) as «class isot» as string) & fieldSep & (item i of noteBodies))
    end repeat
    set AppleScript's text item delimiters to recordSep
    set out to pieces as text
    set AppleScript's text item delimiters to ""
    return out
    """

    /// Сколько знаков заметки кладём в указатель.
    public var maxTextLength = 20_000

    /// Разбирает ответ скрипта в записи указателя.
    static func rows(from output: String) -> [Row] {
        AppleScriptRunner.parse(output).compactMap { fields in
            guard fields.count >= 4, !fields[0].isEmpty else { return nil }
            return Row(
                id: fields[0],
                title: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
                date: AppleScriptRunner.date(fromISO: fields[2]) ?? Date(),
                body: fields[3...].joined(separator: AppleScriptRunner.fieldSeparator)
            )
        }
    }

    func item(from row: Row) -> IndexStore.Item {
        let body = row.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // У заметки первая строка часто и есть заголовок — не повторяем её в теле.
        let trimmedBody = body.hasPrefix(row.title) ? String(body.dropFirst(row.title.count)) : body
        return IndexStore.Item(
            source: .notes,
            externalID: row.id,
            title: row.title.isEmpty ? String(body.prefix(60)) : row.title,
            body: String(trimmedBody.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTextLength)),
            date: row.date
        )
    }

    /// Обходит заметки и складывает их в указатель. Возвращает, сколько положил.
    @discardableResult
    public func scan(
        into store: IndexStore,
        model: MemoryModel? = nil,
        since: Date? = nil,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        guard AppleScriptRunner.isRunning(bundleID: Self.bundleID) else {
            throw AppleScriptRunner.Failure.notRunning(t("Заметки"))
        }
        let start = Date()
        let output = try await AppleScriptRunner.run(Self.script)
        let since = since ?? store.lastScan(of: .notes)
        var indexed = 0
        for row in Self.rows(from: output) {
            try Task.checkCancellation()
            // Заметка не менялась с прошлого обхода — трогать её незачем.
            if let since, row.date <= since { continue }
            let item = item(from: row)
            let vector = model?.embed(item.title + " " + String(item.body.prefix(1_000)))
            try store.put(item, vector: vector)
            indexed += 1
            if indexed % 50 == 0 {
                progress?(indexed)
                await Task.yield()
            }
        }
        try store.markScanned(.notes, at: start)
        progress?(indexed)
        return indexed
    }
}
