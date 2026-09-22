import Foundation

/// Долгая память Руни: обычные Markdown-файлы в папке пользователя.
///
/// Три слоя. `profile.md` — кто человек и как с ним работать, целиком уходит в
/// системный промпт. `facts/` — по файлу на факт с шапкой (тип, описание, даты);
/// в промпт попадает только индекс `MEMORY.md`, сами файлы агент читает через
/// `memory_recall`. `journal/` — короткие записи по дням: что делали и решили,
/// последние дни тоже видны агенту. Всё можно открыть, поправить и удалить руками.
public struct MemoryStore: Sendable {

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Documents/Runie/Memory`: видимая папка, открывается в Finder и Obsidian.
    public static var standard: MemoryStore {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return MemoryStore(root: documents.appending(path: "Runie/Memory", directoryHint: .isDirectory))
    }

    public var profileURL: URL { root.appendingPathComponent("profile.md") }
    public var indexURL: URL { root.appendingPathComponent("MEMORY.md") }
    public var factsURL: URL { root.appendingPathComponent("facts", isDirectory: true) }
    public var journalURL: URL { root.appendingPathComponent("journal", isDirectory: true) }

    // MARK: Подготовка

    /// Создаёт папки и пустые профиль с индексом, если их ещё нет.
    public func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: factsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: journalURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: profileURL.path) {
            try Self.write(Self.profileTemplate, to: profileURL)
        }
        if !fileManager.fileExists(atPath: indexURL.path) {
            try rebuildIndex()
        }
    }

    private static let profileTemplate = """
    # Профиль

    Здесь Руни хранит то, что знает о вас: как вас зовут, чем занимаетесь, как любите, \
    чтобы с вами работали. Файл можно править руками — Руни прочитает его при следующем разговоре.

    """

    // MARK: Факты

    /// Тип факта — как в памяти Claude Code: о человеке, поправки к работе, дела, ссылки.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case user
        case feedback
        case project
        case reference

        public var title: String {
            switch self {
            case .user: t("О вас")
            case .feedback: t("Как работать")
            case .project: t("Проекты и дела")
            case .reference: t("Ссылки и источники")
            }
        }
    }

    public struct Fact: Equatable, Sendable {
        /// Имя файла без расширения: латиница, цифры, дефис.
        public var name: String
        public var kind: Kind
        /// Одна строка: по ней факт ищется и показывается в индексе.
        public var description: String
        /// Сам факт с подробностями, Markdown.
        public var body: String
        public var created: Date
        public var updated: Date

        public init(name: String, kind: Kind, description: String, body: String,
                    created: Date = Date(), updated: Date = Date()) {
            self.name = name
            self.kind = kind
            self.description = description
            self.body = body
            self.created = created
            self.updated = updated
        }

        public var fileName: String { name + ".md" }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case badName(String)
        case empty
        case secret(String)
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .badName(let name): t("Имя «\(name)» не подходит: только латинские строчные буквы, цифры и дефис, до 60 символов.")
            case .empty: t("Нечего запоминать: нужны описание и сам факт.")
            case .secret(let what): t("Это похоже на \(what) — такое Руни не запоминает.")
            case .notFound(let name): t("В памяти нет «\(name)».")
            }
        }
    }

    public func facts() -> [Fact] {
        let files = (try? FileManager.default.contentsOfDirectory(at: factsURL, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { Self.parseFact(at: $0) }
            .sorted { $0.name < $1.name }
    }

    public func fact(named name: String) -> Fact? {
        Self.parseFact(at: factsURL.appendingPathComponent(name + ".md"))
    }

    /// Сохраняет факт (тем же именем — перезаписывает) и обновляет индекс.
    @discardableResult
    public func save(_ fact: Fact) throws -> Fact {
        var fact = fact
        fact.name = fact.name.isEmpty ? Self.slug(for: fact.description) : fact.name
        fact.description = fact.description.trimmingCharacters(in: .whitespacesAndNewlines)
        fact.body = fact.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidName(fact.name) else { throw Failure.badName(fact.name) }
        guard !fact.description.isEmpty, !fact.body.isEmpty else { throw Failure.empty }
        if let reason = Self.secretLeak(in: fact.description + "\n" + fact.body) {
            throw Failure.secret(reason)
        }
        if let existing = self.fact(named: fact.name) {
            fact.created = existing.created
        }
        fact.updated = Date()
        try FileManager.default.createDirectory(at: factsURL, withIntermediateDirectories: true)
        try Self.write(Self.render(fact), to: factsURL.appendingPathComponent(fact.fileName))
        try rebuildIndex()
        return fact
    }

    public func forget(named name: String) throws {
        let url = factsURL.appendingPathComponent(name + ".md")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.notFound(name) }
        try FileManager.default.removeItem(at: url)
        try rebuildIndex()
    }

    /// Стирает всё: факты, дневник, профиль.
    public func forgetEverything() throws {
        try? FileManager.default.removeItem(at: root)
        try prepare()
    }

    // MARK: Индекс

    /// `MEMORY.md`: по строке на факт, сгруппировано по типу. Это то, что агент
    /// видит всегда; за подробностями он идёт в файл.
    public func rebuildIndex() throws {
        let facts = facts()
        var lines = ["# Память Руни", "",
                     "Индекс собирается сам из `facts/`; править нужно сами файлы фактов.", ""]
        for kind in Kind.allCases {
            let group = facts.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            lines.append("## \(kind.title)")
            for fact in group {
                lines.append("- [\(fact.description)](facts/\(fact.fileName))")
            }
            lines.append("")
        }
        if facts.isEmpty {
            lines.append("_Пока пусто._")
            lines.append("")
        }
        try Self.write(lines.joined(separator: "\n"), to: indexURL)
    }

    // MARK: Профиль

    public func profile() -> String {
        (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
    }

    public func setProfile(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        if let reason = Self.secretLeak(in: text) { throw Failure.secret(reason) }
        try Self.write(text + "\n", to: profileURL)
    }

    // MARK: Дневник

    /// Дописывает строку в запись за день: `journal/2026-09-22.md`.
    public func addJournal(_ note: String, at date: Date = Date()) throws {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !note.isEmpty else { throw Failure.empty }
        if let reason = Self.secretLeak(in: note) { throw Failure.secret(reason) }
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
        let url = journalURL.appendingPathComponent(Self.dayName(date) + ".md")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# \(Self.dayName(date))\n"
        if !text.hasSuffix("\n") { text += "\n" }
        text += "- \(Self.timeFormatter.string(from: date)) \(note)\n"
        try Self.write(text, to: url)
    }

    /// Записи за последние `days` дней, от старых к новым.
    public func journal(days: Int, until date: Date = Date()) -> [(day: String, text: String)] {
        let calendar = Calendar(identifier: .gregorian)
        return (0..<max(days, 0)).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
            let name = Self.dayName(day)
            guard let text = try? String(contentsOf: journalURL.appendingPathComponent(name + ".md"), encoding: .utf8) else {
                return nil
            }
            return (name, text)
        }
    }

    // MARK: Промпт

    /// Кусок системного промпта: профиль, индекс и дневник за последние дни.
    /// Ограничен по объёму, чтобы память не съедала контекст.
    public func promptSection(now: Date = Date(), days: Int = 3) -> String {
        var parts = ["## Память (папка \(root.path))"]
        let profile = Self.clip(profile(), 3_000)
        if !profile.isEmpty {
            parts.append("### Профиль\n" + profile)
        }
        let index = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
        let indexLines = index.split(separator: "\n").filter { $0.hasPrefix("- ") || $0.hasPrefix("## ") }
        if !indexLines.isEmpty {
            parts.append("### Что запомнено (подробности — memory_recall)\n" + Self.clip(indexLines.joined(separator: "\n"), 6_000))
        }
        let entries = journal(days: days, until: now)
        if !entries.isEmpty {
            let text = entries.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
            parts.append("### Дневник за последние дни\n" + Self.clip(text, 3_000))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Имена и защита

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 60
            && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
            && !name.hasPrefix("-") && !name.hasSuffix("-")
    }

    /// Имя файла из описания: «Предпочитает короткие ответы» → `predpochitaet-korotkie-otvety`.
    public static func slug(for text: String) -> String {
        let latin = text
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? ""
        let words = latin.lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .prefix(6)
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "fact" : String(slug.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Ключи, пароли и номера карт в память не попадают. Возвращает, на что похоже.
    public static func secretLeak(in text: String) -> String? {
        let patterns: [(String, String)] = [
            (#"(?i)(sk|rk)-[a-z0-9_-]{16,}"#, "ключ API"),
            (#"(?:ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{16,}"#, "токен GitHub"),
            (#"xox[abpr]-[A-Za-z0-9-]{10,}"#, "токен Slack"),
            (#"AKIA[0-9A-Z]{16}"#, "ключ AWS"),
            (#"AIza[0-9A-Za-z_-]{30,}"#, "ключ Google"),
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "закрытый ключ"),
            (#"(?i)(пароль|password|passwd|пин|pin-код|cvv|cvc)\s*[:=—-]\s*\S+"#, "пароль"),
            (#"(?i)(api[_ -]?key|token|токен|секрет|secret)\s*[:=]\s*[A-Za-z0-9_\-./+]{12,}"#, "ключ или токен")
        ]
        for (pattern, what) in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return what
        }
        if let card = text.range(of: #"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#, options: .regularExpression),
           Self.passesLuhn(String(text[card])) {
            return "номер карты"
        }
        return nil
    }

    private static func passesLuhn(_ text: String) -> Bool {
        let digits = text.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13 else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            let value = index % 2 == 1 ? digit * 2 : digit
            sum += value > 9 ? value - 9 : value
        }
        return sum % 10 == 0
    }

    // MARK: Файлы

    private static func render(_ fact: Fact) -> String {
        """
        ---
        name: \(fact.name)
        description: \(fact.description.replacingOccurrences(of: "\n", with: " "))
        kind: \(fact.kind.rawValue)
        created: \(dayName(fact.created))
        updated: \(dayName(fact.updated))
        ---

        \(fact.body)

        """
    }

    private static func parseFact(at url: URL) -> Fact? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fields = SkillCatalog.frontmatter(text)
        let name = fields["name"] ?? url.deletingPathExtension().lastPathComponent
        guard let description = fields["description"], !description.isEmpty else { return nil }
        let kind = fields["kind"].flatMap(Kind.init(rawValue:)) ?? .user
        let created = fields["created"].flatMap(dayFormatter.date(from:)) ?? Date()
        let updated = fields["updated"].flatMap(dayFormatter.date(from:)) ?? created
        return Fact(name: name, kind: kind, description: description, body: SkillCatalog.body(text),
                    created: created, updated: updated)
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    public static func dayName(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
