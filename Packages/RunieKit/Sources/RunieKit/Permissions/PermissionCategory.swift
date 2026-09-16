import Foundation

/// Группа действий, о которых агент спрашивает разрешение, — в словах человека,
/// а не в именах команд. Настройки разрешений показывают именно их.
public enum PermissionCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case readFiles
    case browseFolders
    case systemInfo
    case calendarRead
    case editFiles
    case moveDelete
    case openApps
    case internet
    case automation
    case install
    case sharing
    case calendarEdit
    case contacts
    case services
    case otherCommands

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .readFiles: "Чтение файлов"
        case .browseFolders: "Просмотр папок и поиск"
        case .systemInfo: "Сведения о системе"
        case .calendarRead: "Просмотр календаря и напоминаний"
        case .editFiles: "Создание и правка файлов"
        case .moveDelete: "Перемещение и удаление"
        case .openApps: "Открытие приложений и ссылок"
        case .internet: "Интернет"
        case .automation: "Управление другими приложениями"
        case .install: "Установка программ"
        case .sharing: "Отправка файлов"
        case .calendarEdit: "Изменение календаря и напоминаний"
        case .contacts: "Контакты"
        case .services: "Подключённые сервисы"
        case .otherCommands: "Прочие команды"
        }
    }

    public var summary: String {
        switch self {
        case .readFiles: "Открыть файл и прочитать, что в нём: текст, таблицу, документ."
        case .browseFolders: "Посмотреть, что лежит в папке, найти файл по имени, узнать размер папки."
        case .systemInfo: "Узнать версию macOS, свободное место на диске, заряд батареи, дату."
        case .editFiles: "Создать новый файл или папку, изменить или скопировать файл."
        case .moveDelete: "Переименовать, перенести или удалить файл или папку."
        case .openApps: "Запустить приложение, открыть файл или ссылку."
        case .internet: "Открыть страницу, поискать в интернете, скачать файл."
        case .automation: "Выполнить действие в другом приложении через AppleScript или Быстрые команды."
        case .install: "Поставить или обновить программу через Homebrew, npm, pip."
        case .calendarRead: "Посмотреть встречи и напоминания — например, чтобы разобрать день."
        case .calendarEdit: "Добавить встречу или напоминание, отметить напоминание выполненным."
        case .sharing: "Подготовить письмо, сообщение или AirDrop с файлами. Отправляете вы сами — кнопкой в открывшемся окне."
        case .contacts: "Найти человека в Контактах, чтобы узнать почту или телефон."
        case .services: "Обратиться к подключённому сервису: Notion, Slack, календарю и другим."
        case .otherCommands: "Любая команда, которая не попала в группы выше."
        }
    }

    /// Можно ли испортить что-то необратимо. Такие группы в настройках помечаются.
    public var isRisky: Bool {
        switch self {
        case .readFiles, .browseFolders, .systemInfo, .calendarRead: false
        default: true
        }
    }

    /// Примеры: что делает команда по-русски и как она называется.
    public var examples: [(meaning: String, command: String)] {
        switch self {
        case .readFiles:
            [("показать содержимое файла", "cat"), ("первые или последние строки", "head, tail"),
             ("найти текст внутри файлов", "grep"), ("посчитать строки и слова", "wc"),
             ("прочитать файл", "Read")]
        case .browseFolders:
            [("список файлов в папке", "ls"), ("найти файл по имени", "find, mdfind"),
             ("размер папки", "du")]
        case .systemInfo:
            [("версия macOS", "sw_vers"), ("свободное место на диске", "df"),
             ("сведения о компьютере", "system_profiler"), ("заряд батареи", "pmset -g")]
        case .editFiles:
            [("создать или изменить файл", "Write, Edit"), ("создать папку", "mkdir"),
             ("скопировать", "cp"), ("упаковать или распаковать архив", "zip, unzip, tar")]
        case .moveDelete:
            [("переименовать или перенести", "mv"), ("удалить", "rm")]
        case .openApps:
            [("открыть приложение, файл или ссылку", "open")]
        case .internet:
            [("открыть страницу", "WebFetch"), ("поиск в интернете", "WebSearch"),
             ("скачать файл", "curl")]
        case .automation:
            [("действие в другом приложении", "osascript"), ("запустить быструю команду", "shortcuts")]
        case .install:
            [("поставить программу", "brew, npm, pip")]
        case .calendarRead:
            [("встречи на сегодня или неделю", "Календарь"), ("список дел", "Напоминания")]
        case .calendarEdit:
            [("новая встреча", "Календарь"), ("новое напоминание", "Напоминания"), ("отметить выполненным", "Напоминания")]
        case .sharing:
            [("письмо с вложением", "Почта"), ("сообщение с файлом", "Сообщения"), ("передать рядом", "AirDrop")]
        case .contacts:
            [("найти почту или телефон", "Контакты")]
        case .services:
            [("действие в подключённом сервисе", "mcp__…")]
        case .otherCommands:
            []
        }
    }
}

/// Раскладывает запрос разрешения по группам.
///
/// Команда оболочки разбирается по частям: `ls ~/Downloads | head` — это просмотр
/// папки и чтение. Всё, что разобрать нельзя (подстановка `$(…)`, `sudo`, незнакомая
/// программа), уходит в «Прочие команды», чтобы правило «разрешать чтение» не
/// пропустило под своей вывеской что-то опасное.
public enum PermissionClassifier {

    public static func categories(for request: PermissionRequest) -> Set<PermissionCategory> {
        categories(toolName: request.toolName, input: request.input)
    }

    public static func categories(toolName: String, input: JSONValue) -> Set<PermissionCategory> {
        switch toolName {
        case "Read": return [.readFiles]
        case "Glob", "Grep", "LS": return [.browseFolders]
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return [.editFiles]
        case "WebFetch", "WebSearch": return [.internet]
        case "Bash": return shellCategories(input["command"]?.stringValue ?? "")
        case "mcp__runie__find_files": return [.browseFolders]
        case "mcp__runie__reveal_in_finder", "mcp__runie__open_files": return [.openApps]
        case "mcp__runie__compress_images", "mcp__runie__zip_files": return [.editFiles]
        case "mcp__runie__share_files": return [.sharing]
        case "mcp__runie__find_contact": return [.contacts]
        case "mcp__runie__calendar_events", "mcp__runie__reminders": return [.calendarRead]
        case "mcp__runie__create_event", "mcp__runie__create_reminder", "mcp__runie__complete_reminder":
            return [.calendarEdit]
        default:
            if toolName.hasPrefix("mcp__runie__") { return [.otherCommands] }
            return toolName.hasPrefix("mcp__") ? [.services] : [.otherCommands]
        }
    }

    // MARK: - Оболочка

    static func shellCategories(_ command: String) -> Set<PermissionCategory> {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [.otherCommands] }
        // Подстановки выполняют произвольный код внутри, по имени первой программы
        // о них ничего не скажешь.
        if trimmed.contains("$(") || trimmed.contains("`") || trimmed.contains("<(") {
            return [.otherCommands]
        }

        guard let split = splitCommand(trimmed) else { return [.otherCommands] }
        var result = Set<PermissionCategory>()
        if split.writesToFile { result.insert(.editFiles) }
        for segment in split.segments {
            result.formUnion(segmentCategories(segment))
        }
        return result
    }

    /// Нейтральные команды сами по себе ничего не делают с файлами и системой.
    private static let neutral: Set<String> = ["echo", "printf", "true", "false", "cd", "test", "[", "sleep", "exit"]

    private static let table: [String: PermissionCategory] = {
        var table: [String: PermissionCategory] = [:]
        func put(_ names: [String], _ category: PermissionCategory) {
            for name in names { table[name] = category }
        }
        put(["cat", "head", "tail", "less", "more", "wc", "file", "stat", "xxd", "strings", "mdls",
             "grep", "egrep", "fgrep", "rg", "sort", "uniq", "cut", "diff", "cmp", "md5", "shasum",
             "jq", "pdftotext", "column", "tr", "nl", "plutil"], .readFiles)
        put(["ls", "find", "du", "tree", "mdfind", "locate", "pwd", "realpath", "dirname",
             "basename", "fd"], .browseFolders)
        put(["sw_vers", "uname", "system_profiler", "df", "date", "whoami", "id", "hostname",
             "sysctl", "uptime", "vm_stat", "ioreg", "which", "cal", "ps", "top", "sw_vers",
             "diskutil", "ifconfig", "locale", "printenv"], .systemInfo)
        put(["mkdir", "touch", "cp", "tee", "ditto", "zip", "unzip", "tar", "gzip", "gunzip",
             "textutil", "sips", "ln", "pandoc"], .editFiles)
        put(["mv", "rm", "rmdir", "trash", "srm", "unlink"], .moveDelete)
        put(["open", "say"], .openApps)
        put(["curl", "wget", "ping", "nslookup", "dig", "host", "whois"], .internet)
        put(["osascript", "shortcuts", "automator"], .automation)
        put(["brew", "npm", "npx", "pip", "pip3", "pipx", "gem", "cargo", "mas", "port", "uv",
             "softwareupdate", "yarn", "pnpm"], .install)
        return table
    }()

    private static func segmentCategories(_ words: [String]) -> Set<PermissionCategory> {
        var words = words
        // Переменные окружения перед командой: `LANG=C sort file`.
        while let first = words.first, first.contains("="), !first.hasPrefix("=") {
            words.removeFirst()
        }
        guard let first = words.first else { return [] }
        let name = (first as NSString).lastPathComponent
        let arguments = Array(words.dropFirst())

        if neutral.contains(name) { return [] }

        switch name {
        case "sed", "awk", "gawk":
            // `sed -i` правит файл на месте; awk умеет запускать команды через system().
            if name == "sed" {
                return arguments.contains(where: { $0.hasPrefix("-i") }) ? [.editFiles] : [.readFiles]
            }
            return arguments.joined(separator: " ").contains("system") ? [.otherCommands] : [.readFiles]
        case "defaults":
            return arguments.first == "read" ? [.systemInfo] : [.otherCommands]
        case "pmset":
            return arguments.first == "-g" ? [.systemInfo] : [.otherCommands]
        case "find":
            // `find -delete` и `-exec` — уже не просмотр.
            if arguments.contains("-delete") { return [.moveDelete] }
            if arguments.contains(where: { $0.hasPrefix("-exec") || $0 == "-ok" }) { return [.otherCommands] }
            return [.browseFolders]
        case "env", "time", "nohup", "nice", "command":
            // Обёртки запускают другую команду — судим по ней.
            if name == "command", arguments.first == "-v" { return [.systemInfo] }
            let rest = Array(arguments.drop { $0.hasPrefix("-") })
            if rest.isEmpty { return name == "env" ? [.systemInfo] : [] }
            return segmentCategories(rest)
        case "xargs":
            let rest = Array(arguments.drop { $0.hasPrefix("-") })
            return rest.isEmpty ? [.otherCommands] : segmentCategories(rest)
        default:
            return table[name].map { [$0] } ?? [.otherCommands]
        }
    }

    // MARK: - Разбор строки

    struct SplitCommand {
        var segments: [[String]]
        var writesToFile: Bool
    }

    /// Делит строку на простые команды по `|`, `&&`, `||`, `;` и переводам строк
    /// с учётом кавычек. `nil` — строку разобрать не удалось (незакрытая кавычка).
    static func splitCommand(_ command: String) -> SplitCommand? {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var hasWord = false
        var writes = false
        var quote: Character?
        var chars = Array(command)
        chars.append(" ")
        var index = 0

        func endWord() {
            if hasWord { words.append(word) }
            word = ""
            hasWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }

        while index < chars.count {
            let c = chars[index]
            if let q = quote {
                if c == q {
                    quote = nil
                } else if c == "\\", q == "\"", index + 1 < chars.count {
                    index += 1
                    word.append(chars[index])
                } else {
                    word.append(c)
                }
                index += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                hasWord = true
            case "\\":
                if index + 1 < chars.count {
                    index += 1
                    word.append(chars[index])
                    hasWord = true
                }
            case " ", "\t":
                endWord()
            case "\n", ";", "|", "&":
                endSegment()
                // `&&`, `||`, `|&` — два символа.
                if index + 1 < chars.count, chars[index + 1] == "&" || chars[index + 1] == "|" {
                    index += 1
                }
            case ">":
                // `2>&1` и `>/dev/null` ничего не пишут в файлы человека. Номер
                // дескриптора перед `>` — не аргумент команды.
                if hasWord, !word.isEmpty, word.allSatisfy(\.isNumber) {
                    word = ""
                    hasWord = false
                }
                endWord()
                var target = index + 1
                if target < chars.count, chars[target] == ">" { target += 1 }
                if target < chars.count, chars[target] == "&" {
                    index = target
                    break
                }
                while target < chars.count, chars[target] == " " { target += 1 }
                let rest = String(chars[target...])
                if !rest.hasPrefix("/dev/null") { writes = true }
                // Имя файла после `>` — не аргумент команды.
                var end = target
                while end < chars.count, !" ;|&\n".contains(chars[end]) { end += 1 }
                index = end - 1
            case "<":
                endWord()
            default:
                word.append(c)
                hasWord = true
            }
            index += 1
        }
        guard quote == nil else { return nil }
        endSegment()
        return SplitCommand(segments: segments, writesToFile: writes)
    }
}

/// Правила разрешений, заданные человеком в настройках.
public struct PermissionPolicy: Codable, Sendable, Equatable {

    public enum Rule: String, Codable, Sendable, CaseIterable {
        /// Показывать вопрос.
        case ask
        /// Разрешать без вопроса.
        case allow
    }

    public var rules: [PermissionCategory: Rule]

    public init(rules: [PermissionCategory: Rule] = [:]) {
        self.rules = rules
    }

    public func rule(for category: PermissionCategory) -> Rule {
        rules[category] ?? .ask
    }

    /// Разрешать без вопроса, только если разрешены все группы, которые затрагивает
    /// запрос. Запрос без групп — одни нейтральные команды — тоже разрешается.
    public func allows(_ request: PermissionRequest) -> Bool {
        PermissionClassifier.categories(for: request).allSatisfy { rule(for: $0) == .allow }
    }
}
