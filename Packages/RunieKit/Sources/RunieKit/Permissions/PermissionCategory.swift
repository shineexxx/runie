import Foundation

/// Группа действий, о которых агент спрашивает разрешение, — в словах человека,
/// а не в именах команд. Настройки разрешений показывают именно их.
public enum PermissionCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case readFiles
    case browseFolders
    case systemInfo
    case calendarRead
    case browserRead
    case editFiles
    case moveDelete
    case openApps
    case internet
    case automation
    case install
    case sharing
    case calendarEdit
    case browserControl
    case pageScript
    case quietBrowser
    case signInAsYou
    case extendRunie
    case memory
    case personalIndex
    case contacts
    case services
    case otherCommands

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .readFiles: t("Чтение файлов")
        case .browseFolders: t("Просмотр папок и поиск")
        case .systemInfo: t("Сведения о системе")
        case .calendarRead: t("Просмотр календаря и напоминаний")
        case .browserRead: t("Просмотр браузера")
        case .editFiles: t("Создание и правка файлов")
        case .moveDelete: t("Перемещение и удаление")
        case .openApps: t("Открытие приложений и ссылок")
        case .internet: t("Интернет")
        case .automation: t("Управление другими приложениями")
        case .install: t("Установка программ")
        case .sharing: t("Отправка файлов")
        case .calendarEdit: t("Изменение календаря и напоминаний")
        case .browserControl: t("Управление браузером")
        case .pageScript: t("JavaScript на странице")
        case .quietBrowser: t("Свой браузер без окна")
        case .signInAsYou: t("Вход под вашей учётной записью")
        case .extendRunie: t("Новые возможности Руни")
        case .memory: t("Память Руни")
        case .personalIndex: t("Поиск по вашим данным")
        case .contacts: t("Контакты")
        case .services: t("Подключённые сервисы")
        case .otherCommands: t("Прочие команды")
        }
    }

    public var summary: String {
        switch self {
        case .readFiles: t("Открыть файл и прочитать, что в нём: текст, таблицу, документ.")
        case .browseFolders: t("Посмотреть, что лежит в папке, найти файл по имени, узнать размер папки.")
        case .systemInfo: t("Узнать версию macOS, свободное место на диске, заряд батареи, дату.")
        case .editFiles: t("Создать новый файл или папку, изменить или скопировать файл.")
        case .moveDelete: t("Переименовать, перенести или удалить файл или папку.")
        case .openApps: t("Запустить приложение, открыть файл или ссылку.")
        case .internet: t("Открыть страницу, поискать в интернете, скачать файл.")
        case .automation: t("Выполнить действие в другом приложении через AppleScript или Быстрые команды.")
        case .install: t("Поставить или обновить программу через Homebrew, npm, pip.")
        case .browserRead: t("Посмотреть открытые вкладки Safari и Chrome и прочитать текст страницы.")
        case .browserControl: t("Открыть ссылку, перейти на вкладку, нажать кнопку или заполнить поле на странице.")
        case .extendRunie: t("Подключить сервис или сохранить навык. Работает только в Runie — Claude Code в терминале не меняется.")
        case .personalIndex: t("Искать по указателю, который Руни собрал из ваших файлов, писем и заметок. Что в него попадает, вы выбираете сами в настройках; пока источник не включён, искать нечего.")
        case .quietBrowser: t("Сходить на сайт в своём браузере, которого не видно: прочитать страницу, нажать, заполнить поле. Ваши вкладки и работа не трогаются.")
        case .signInAsYou: t("Взять куки сайта из вашего Safari или Chrome, чтобы зайти туда под вашей учётной записью. Только для того сайта, о котором речь.")
        case .memory: t("Запомнить факт о вас, дописать дневник дня или вспомнить сохранённое. Всё лежит обычными текстовыми файлами в папке Документы → Runie → Memory.")
        case .pageScript: t("Выполнить свой код на открытой странице: разобрать её устройство, достать данные, нажать то, что не нажимается по надписи. Код видно в запросе.")
        case .calendarRead: t("Посмотреть встречи и напоминания — например, чтобы разобрать день.")
        case .calendarEdit: t("Добавить встречу или напоминание, отметить напоминание выполненным.")
        case .sharing: t("Подготовить письмо, сообщение или AirDrop с файлами. Отправляете вы сами — кнопкой в открывшемся окне.")
        case .contacts: t("Найти человека в Контактах, чтобы узнать почту или телефон.")
        case .services: t("Обратиться к подключённому сервису: Notion, Slack, календарю и другим.")
        case .otherCommands: t("Любая команда, которая не попала в группы выше.")
        }
    }

    /// Что делать, пока человек ничего не выбрал. Память разрешена сразу: она пишет
    /// только в свою папку, а вопрос на каждое «запомни» быстро надоедает.
    public var defaultRule: PermissionPolicy.Rule {
        // Память и указатель человек включает сам, в настройках: это и есть
        // согласие, спрашивать ещё раз при каждом поиске незачем.
        self == .memory || self == .personalIndex ? .allow : .ask
    }

    /// Группы, которые не разрешает заранее даже самый доверчивый режим.
    ///
    /// Удалённый файл не вернуть, а установленная программа остаётся в системе
    /// и после того, как про неё забыли. Здесь вопрос — последняя преграда, и
    /// он стоит секунды внимания.
    public var alwaysAsks: Bool {
        // Вход под учётной записью человека — всегда с его ведома: куки дают
        // сайту думать, что за экраном он сам.
        self == .moveDelete || self == .install || self == .signInAsYou
    }

    /// Можно ли испортить что-то необратимо. Такие группы в настройках помечаются.
    public var isRisky: Bool {
        switch self {
        case .readFiles, .browseFolders, .systemInfo, .calendarRead, .browserRead, .memory, .personalIndex: false
        default: true
        }
    }

    /// Примеры: что делает команда по-русски и как она называется.
    public var examples: [(meaning: String, command: String)] {
        switch self {
        case .readFiles:
            [(t("показать содержимое файла"), "cat"), (t("первые или последние строки"), "head, tail"),
             (t("найти текст внутри файлов"), "grep"), (t("посчитать строки и слова"), "wc"),
             (t("прочитать файл"), "Read")]
        case .browseFolders:
            [(t("список файлов в папке"), "ls"), (t("найти файл по имени"), "find, mdfind"),
             (t("размер папки"), "du")]
        case .systemInfo:
            [(t("версия macOS"), "sw_vers"), (t("свободное место на диске"), "df"),
             (t("сведения о компьютере"), "system_profiler"), (t("заряд батареи"), "pmset -g")]
        case .editFiles:
            [(t("создать или изменить файл"), "Write, Edit"), (t("создать папку"), "mkdir"),
             (t("скопировать"), "cp"), (t("упаковать или распаковать архив"), "zip, unzip, tar")]
        case .moveDelete:
            [(t("переименовать или перенести"), "mv"), (t("удалить"), "rm")]
        case .openApps:
            [(t("открыть приложение, файл или ссылку"), "open")]
        case .internet:
            [(t("открыть страницу"), "WebFetch"), (t("поиск в интернете"), "WebSearch"),
             (t("скачать файл"), "curl")]
        case .automation:
            [(t("действие в другом приложении"), "osascript"), (t("запустить быструю команду"), "shortcuts")]
        case .install:
            [(t("поставить программу"), "brew, npm, pip")]
        case .browserRead:
            [(t("список вкладок"), "Safari, Chrome"), (t("текст страницы"), "Safari, Chrome")]
        case .browserControl:
            [(t("открыть ссылку"), "Safari, Chrome"), (t("нажать кнопку"), "Safari, Chrome"), (t("заполнить поле"), "Safari, Chrome")]
        case .extendRunie:
            [(t("подключить сервис"), t("MCP-сервер")), (t("запомнить, как делать задачу"), t("навык"))]
        case .personalIndex:
            [(t("найти свой файл или письмо"), t("указатель")), (t("вспомнить, где это лежало"), t("указатель"))]
        case .memory:
            [(t("запомнить факт или поправку"), t("память")), (t("записать, что сделали за день"), t("дневник")), (t("вспомнить сохранённое"), t("память"))]
        case .quietBrowser:
            [(t("открыть страницу"), t("свой браузер")), (t("прочитать и нажать"), t("свой браузер")),
             (t("снимок страницы"), t("свой браузер"))]
        case .signInAsYou:
            [(t("взять куки сайта"), "Safari, Chrome")]
        case .pageScript:
            [(t("найти элементы и ссылки"), "Safari, Chrome"), (t("достать таблицу с данными"), "Safari, Chrome"), (t("прокрутить, выбрать в списке"), "Safari, Chrome")]
        case .calendarRead:
            [(t("встречи на сегодня или неделю"), t("Календарь")), (t("список дел"), t("Напоминания"))]
        case .calendarEdit:
            [(t("новая встреча"), t("Календарь")), (t("новое напоминание"), t("Напоминания")), (t("отметить выполненным"), t("Напоминания"))]
        case .sharing:
            [(t("письмо с вложением"), t("Почта")), (t("сообщение с файлом"), t("Сообщения")), (t("передать рядом"), "AirDrop")]
        case .contacts:
            [(t("найти почту или телефон"), t("Контакты"))]
        case .services:
            [(t("действие в подключённом сервисе"), "mcp__…")]
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
        case "mcp__runie__browser_tabs", "mcp__runie__browser_page_text": return [.browserRead]
        case "mcp__runie__browser_open", "mcp__runie__browser_switch_tab", "mcp__runie__browser_click", "mcp__runie__browser_fill":
            return [.browserControl]
        case "mcp__runie__browser_run_js": return [.pageScript]
        case "mcp__runie__web_open":
            // Вход под учётной записью — отдельный вопрос поверх обычного захода.
            return input["sign_in"]?.boolValue == true ? [.quietBrowser, .signInAsYou] : [.quietBrowser]
        case "mcp__runie__web_read", "mcp__runie__web_elements", "mcp__runie__web_snapshot",
             "mcp__runie__web_click", "mcp__runie__web_fill", "mcp__runie__web_forget":
            return [.quietBrowser]
        case "mcp__runie__web_run_js": return [.quietBrowser, .pageScript]
        case "mcp__runie__add_service", "mcp__runie__remove_service", "mcp__runie__save_skill", "mcp__runie__remove_skill":
            return [.extendRunie]
        case "mcp__runie__list_extensions": return [.systemInfo]
        // Вопрос человеку и так требует его ответа: спрашивать разрешение,
        // чтобы спросить, — бессмысленно. Пустой список значит «можно всегда».
        case "mcp__runie__ask_user", "AskUserQuestion": return []
        case "mcp__runie__search_my_stuff": return [.personalIndex]
        case "mcp__runie__memory_save", "mcp__runie__memory_forget", "mcp__runie__memory_recall",
             "mcp__runie__memory_journal", "mcp__runie__memory_profile":
            return [.memory]
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
    /// Узел из адреса в запросе. Человек мог написать его без «https://».
    public static func site(of request: PermissionRequest) -> String? {
        guard let address = request.input["url"]?.stringValue else { return nil }
        let text = address.contains("://") ? address : "https://" + address
        return URL(string: text)?.host()?.lowercased()
    }

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

    /// Выбранный человеком набор. Помнится отдельно от правил, чтобы новые
    /// группы разрешений вели себя так, как он однажды решил.
    ///
    /// Без этого каждая новая возможность Руни начинала спрашивать заново:
    /// правила сохранены только для тех групп, что были в момент выбора, а про
    /// новую в настройках ничего нет.
    public enum Preset: String, Codable, Sendable {
        case strict
        case safe
        case permissive
        /// Человек настраивал группы по одной.
        case custom

        func rule(for category: PermissionCategory) -> Rule {
            switch self {
            case .strict: .ask
            case .safe: category.isRisky ? .ask : .allow
            case .permissive: category.alwaysAsks ? .ask : .allow
            case .custom: category.defaultRule
            }
        }
    }

    public var preset: Preset

    public var rules: [PermissionCategory: Rule]

    /// Сайты, на которые человек разрешил заходить под своей учётной записью.
    ///
    /// Вход хранится по узлам, а не одним выключателем: разрешив дневник, человек
    /// не разрешает почту. Список виден в настройках, и любой сайт из него можно
    /// убрать.
    public var signedInSites: Set<String>

    public init(rules: [PermissionCategory: Rule] = [:], signedInSites: Set<String> = [],
                preset: Preset = .custom) {
        self.rules = rules
        self.signedInSites = signedInSites
        self.preset = preset
    }

    // Старые настройки про сайты ничего не знают — читаем их без ошибки.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([PermissionCategory: Rule].self, forKey: .rules) ?? [:]
        signedInSites = try container.decodeIfPresent(Set<String>.self, forKey: .signedInSites) ?? []
        // Настройки, сохранённые до появления наборов: узнаём набор по правилам,
        // иначе человек, однажды нажавший «Разрешить почти всё», снова начнёт
        // отвечать на вопросы о каждой новой группе.
        preset = try container.decodeIfPresent(Preset.self, forKey: .preset) ?? Self.infer(from: rules)
    }

    /// Какому набору соответствуют сохранённые правила.
    static func infer(from rules: [PermissionCategory: Rule]) -> Preset {
        // Меньше половины групп — человек явно настраивал их по одной.
        guard rules.count >= PermissionCategory.allCases.count / 2 else { return .custom }
        for preset in [Preset.permissive, .safe, .strict]
        where rules.allSatisfy({ $0.value == preset.rule(for: $0.key) }) {
            return preset
        }
        return .custom
    }

    /// Правило для группы: своё, если человек его задал, иначе — из набора.
    public func rule(for category: PermissionCategory) -> Rule {
        rules[category] ?? preset.rule(for: category)
    }

    /// Разрешать без вопроса, только если разрешены все группы, которые затрагивает
    /// запрос. Запрос без групп — одни нейтральные команды — тоже разрешается.
    public func allows(_ request: PermissionRequest) -> Bool {
        let categories = PermissionClassifier.categories(for: request)
        // Вход под учётной записью спрашивается один раз на сайт: дальше этот
        // сайт в списке разрешённых, а все остальные — по-прежнему через вопрос.
        if categories.contains(.signInAsYou),
           let site = PermissionClassifier.site(of: request), signedInSites.contains(site) {
            return categories.filter { $0 != .signInAsYou }.allSatisfy { rule(for: $0) == .allow }
        }
        return categories.allSatisfy { rule(for: $0) == .allow }
    }

    // MARK: Готовые наборы

    /// Спрашивать обо всём: ни одна группа не разрешена заранее.
    public static var strict: PermissionPolicy {
        PermissionPolicy(
            rules: Dictionary(uniqueKeysWithValues: PermissionCategory.allCases.map { ($0, .ask) }),
            preset: .strict
        )
    }

    /// Разрешено то, что ничего не меняет: чтение, просмотр, сведения о системе.
    public static var safe: PermissionPolicy {
        var policy = PermissionPolicy(preset: .safe)
        for category in PermissionCategory.allCases {
            policy.rules[category] = category.isRisky ? .ask : .allow
        }
        return policy
    }

    /// Разрешено всё, кроме необратимого: перемещения с удалением и установки
    /// программ. Для тех, кому вопрос на каждое действие мешает работать.
    public static var permissive: PermissionPolicy {
        var policy = PermissionPolicy(preset: .permissive)
        for category in PermissionCategory.allCases {
            policy.rules[category] = category.alwaysAsks ? .ask : .allow
        }
        return policy
    }
}
