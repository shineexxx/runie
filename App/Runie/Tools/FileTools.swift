import AppKit
import Contacts
import ImageIO
import RunieKit
import UniformTypeIdentifiers

// Встроенные инструменты Runie для работы с файлами: то, что на Mac делается
// нативно и чего нет у Claude Code. Каждый вызов проходит обычный вопрос о
// разрешении; отправка никогда не уходит сама — открывается окно, где человек
// нажимает «Отправить».

enum RunieTools {
    static let server = HostToolServer(name: "runie", tools: [
        FindFilesTool(),
        RevealInFinderTool(),
        OpenFilesTool(),
        CompressImagesTool(),
        ZipFilesTool(),
        ShareFilesTool(),
        FindContactTool(),
        CalendarEventsTool(),
        CreateEventTool(),
        RemindersTool(),
        CreateReminderTool(),
        CompleteReminderTool(),
        BrowserTabsTool(),
        BrowserPageTextTool(),
        BrowserOpenTool(),
        BrowserSwitchTabTool(),
        BrowserClickTool(),
        BrowserFillTool()
    ])
}

// MARK: - Общее

private enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string))
        ])
    }

    static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
        return .object(schema)
    }

    static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    static let paths: JSONValue = .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("Полные пути к файлам")
    ])
}

private extension JSONValue {
    var paths: [String] {
        (self["paths"]?.arrayValue ?? []).compactMap(\.stringValue).map(FileInfo.resolve)
    }
}

private enum FileInfo {
    /// Путь, как его понял агент, — к настоящему файлу. macOS ставит в имена
    /// скриншотов неразрывные узкие пробелы («Снимок экрана — … в 19.09.50»), а
    /// модель пересказывает их обычными, и файл «не находится». Если точного пути
    /// нет, ищем в той же папке имя, совпадающее без учёта вида пробелов и
    /// Unicode-нормализации.
    static func resolve(_ raw: String) -> String {
        let path = (raw as NSString).expandingTildeInPath
        guard !FileManager.default.fileExists(atPath: path) else { return path }
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        let wanted = loose(url.lastPathComponent)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              let match = names.first(where: { loose($0) == wanted })
        else { return path }
        return folder.appending(path: match).path
    }

    private static func loose(_ name: String) -> String {
        let spaces: Set<Character> = ["\u{00A0}", "\u{202F}", "\u{2007}", "\u{2009}"]
        return String(name.precomposedStringWithCanonicalMapping.map { spaces.contains($0) ? " " : $0 })
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func size(of path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func line(_ path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes?[.modificationDate] as? Date)
            .map { $0.formatted(.relative(presentation: .named).locale(Locale(identifier: "ru_RU"))) } ?? ""
        return "- \(path) (\(size(bytes)), \(date))"
    }

    /// Имя, которого ещё нет в папке: «Архив.zip», «Архив 2.zip»…
    static func unique(_ url: URL) -> URL {
        var candidate = url
        var index = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = url.deletingLastPathComponent().appending(path: name)
            index += 1
        }
        return candidate
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func missing(_ paths: [String]) -> [String] {
        paths.filter { !FileManager.default.fileExists(atPath: $0) }
    }
}

private func runProcess(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    return await withCheckedContinuation { continuation in
        process.terminationHandler = { process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
        }
        do { try process.run() } catch { continuation.resume(returning: (-1, "")) }
    }
}

// MARK: - Поиск

struct FindFilesTool: HostTool {
    let name = "find_files"
    let description = """
    Ищет файлы на Mac через Spotlight — быстро и по всему диску, включая скриншоты. \
    Возвращает полные пути, размеры и даты. Для «вчерашних скриншотов» — kind=screenshot, modified=yesterday.
    """
    let inputSchema = Schema.object([
        "query": Schema.string("Часть имени файла, необязательно"),
        "kind": Schema.string("Что искать", enum: ["any", "screenshot", "image", "pdf", "document", "archive", "video", "audio", "folder"]),
        "modified": Schema.string("Когда менялся", enum: ["any", "today", "yesterday", "week", "month"]),
        "folder": Schema.string("Искать только в этой папке, необязательно"),
        "limit": Schema.number("Сколько результатов, по умолчанию 20, не больше 50")
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        var clauses: [String] = []
        if let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            clauses.append("kMDItemFSName == \"*\(escaped)*\"cd")
        }
        switch arguments["kind"]?.stringValue ?? "any" {
        case "screenshot": clauses.append("kMDItemIsScreenCapture == 1")
        case "image": clauses.append("kMDItemContentTypeTree == \"public.image\"")
        case "pdf": clauses.append("kMDItemContentType == \"com.adobe.pdf\"")
        case "document":
            clauses.append("(kMDItemContentTypeTree == \"public.text\" || kMDItemContentTypeTree == \"com.adobe.pdf\" || kMDItemContentTypeTree == \"public.composite-content\")")
        case "archive": clauses.append("kMDItemContentTypeTree == \"public.archive\"")
        case "video": clauses.append("kMDItemContentTypeTree == \"public.movie\"")
        case "audio": clauses.append("kMDItemContentTypeTree == \"public.audio\"")
        case "folder": clauses.append("kMDItemContentType == \"public.folder\"")
        default: break
        }
        switch arguments["modified"]?.stringValue ?? "any" {
        case "today": clauses.append("kMDItemFSContentChangeDate >= $time.today")
        case "yesterday": clauses.append("kMDItemFSContentChangeDate >= $time.today(-1) && kMDItemFSContentChangeDate < $time.today")
        case "week": clauses.append("kMDItemFSContentChangeDate >= $time.today(-7)")
        case "month": clauses.append("kMDItemFSContentChangeDate >= $time.today(-30)")
        default: break
        }
        guard !clauses.isEmpty else {
            return HostToolResult("Укажите, что искать: часть имени, вид файла или когда он менялся.", isError: true)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = arguments["folder"]?.stringValue.map { ($0 as NSString).expandingTildeInPath } ?? home
        let limit = min(max(arguments["limit"]?.intValue ?? 20, 1), 50)
        let result = await runProcess("/usr/bin/mdfind", ["-onlyin", folder, clauses.joined(separator: " && ")])
        guard result.status == 0 else {
            return HostToolResult("Spotlight не ответил. Возможно, индекс ещё строится.", isError: true)
        }

        let paths = result.output
            .split(separator: "\n").map(String.init)
            .filter { !$0.contains("/Library/") && !$0.contains("/.") }
        let dated = paths.map { path -> (String, Date) in
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return (path, date ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)

        guard !dated.isEmpty else { return HostToolResult("Ничего не нашлось.") }
        let more = paths.count > limit ? "\n…и ещё \(paths.count - limit)." : ""
        return HostToolResult("Нашлось \(paths.count):\n" + dated.map { FileInfo.line($0.0) }.joined(separator: "\n") + more)
    }
}

// MARK: - Finder

struct RevealInFinderTool: HostTool {
    let name = "reveal_in_finder"
    let description = "Открывает Finder и выделяет в нём файлы — чтобы человек их увидел."
    let inputSchema = Schema.object(["paths": Schema.paths], required: ["paths"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let paths = arguments.paths
        let missing = FileInfo.missing(paths)
        guard missing.isEmpty else { return HostToolResult("Нет таких файлов: \(missing.joined(separator: ", "))", isError: true) }
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
        return HostToolResult("Показал в Finder: \(paths.count).")
    }
}

struct OpenFilesTool: HostTool {
    let name = "open_files"
    let description = "Открывает файлы в приложениях по умолчанию: картинку в Просмотре, документ в его редакторе."
    let inputSchema = Schema.object(["paths": Schema.paths], required: ["paths"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let paths = arguments.paths
        let missing = FileInfo.missing(paths)
        guard missing.isEmpty else { return HostToolResult("Нет таких файлов: \(missing.joined(separator: ", "))", isError: true) }
        await MainActor.run {
            for path in paths { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
        return HostToolResult("Открыл: \(paths.count).")
    }
}

// MARK: - Сжатие и архив

struct CompressImagesTool: HostTool {
    let name = "compress_images"
    let description = """
    Сжимает картинки (PNG, HEIC, JPEG, скриншоты) в JPEG поменьше. Оригиналы не трогает: \
    копии кладёт в новую папку в Загрузках (или в destination). Возвращает пути и сколько места сэкономлено.
    """
    let inputSchema = Schema.object([
        "paths": Schema.paths,
        "max_side": Schema.number("Длинная сторона в пикселях, по умолчанию 1600"),
        "quality": Schema.number("Качество JPEG от 0.1 до 1, по умолчанию 0.8"),
        "destination": Schema.string("Папка для результата, необязательно")
    ], required: ["paths"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let paths = arguments.paths
        guard !paths.isEmpty else { return HostToolResult("Нет файлов.", isError: true) }
        let maxSide = min(max(arguments["max_side"]?.intValue ?? 1600, 200), 8000)
        let quality = min(max(arguments["quality"]?.doubleValue ?? 0.8, 0.1), 1)

        let stamp = Date().formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU")))
        let folder = arguments["destination"]?.stringValue.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileInfo.unique(FileInfo.downloads.appending(path: "Сжатые картинки \(stamp)"))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return HostToolResult("Не удалось создать папку \(folder.path): \(error.localizedDescription)", isError: true)
        }

        var lines: [String] = []
        var before: Int64 = 0
        var after: Int64 = 0
        var failed: [String] = []
        for path in paths {
            let source = URL(fileURLWithPath: path)
            let target = FileInfo.unique(folder.appending(path: source.deletingPathExtension().lastPathComponent + ".jpg"))
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSide
                  ] as CFDictionary),
                  let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else {
                failed.append(source.lastPathComponent)
                continue
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                failed.append(source.lastPathComponent)
                continue
            }
            let old = FileInfo.size(of: path)
            let new = FileInfo.size(of: target.path)
            before += old
            after += new
            lines.append("- \(target.path) (\(FileInfo.size(old)) → \(FileInfo.size(new)))")
        }

        var text = "Сжал \(lines.count) в папку \(folder.path): было \(FileInfo.size(before)), стало \(FileInfo.size(after)).\n"
            + lines.joined(separator: "\n")
        if !failed.isEmpty { text += "\nНе получилось: \(failed.joined(separator: ", "))." }
        return HostToolResult(text, isError: lines.isEmpty)
    }
}

struct ZipFilesTool: HostTool {
    let name = "zip_files"
    let description = "Упаковывает файлы и папки в один ZIP-архив. По умолчанию кладёт его в Загрузки."
    let inputSchema = Schema.object([
        "paths": Schema.paths,
        "name": Schema.string("Имя архива без .zip, необязательно"),
        "destination": Schema.string("Папка для архива, необязательно")
    ], required: ["paths"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let paths = arguments.paths
        guard !paths.isEmpty else { return HostToolResult("Нет файлов.", isError: true) }
        let missing = FileInfo.missing(paths)
        guard missing.isEmpty else { return HostToolResult("Нет таких файлов: \(missing.joined(separator: ", "))", isError: true) }

        let name = arguments["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? (paths.count == 1 ? URL(fileURLWithPath: paths[0]).deletingPathExtension().lastPathComponent : "Архив")
        let folder = arguments["destination"]?.stringValue.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileInfo.downloads
        let archive = FileInfo.unique(folder.appending(path: "\(name).zip"))

        let source: URL
        var staging: URL?
        if paths.count == 1 {
            source = URL(fileURLWithPath: paths[0])
        } else {
            // Несколько файлов — через временную папку с именем архива внутри.
            let temp = FileManager.default.temporaryDirectory.appending(path: "runie-zip-\(UUID().uuidString)")
            let inner = temp.appending(path: name)
            do {
                try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    try FileManager.default.copyItem(at: url, to: FileInfo.unique(inner.appending(path: url.lastPathComponent)))
                }
            } catch {
                return HostToolResult("Не удалось собрать файлы: \(error.localizedDescription)", isError: true)
            }
            staging = temp
            source = inner
        }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }

        let result = await runProcess("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", source.path, archive.path])
        guard result.status == 0 else { return HostToolResult("Не удалось создать архив.", isError: true) }
        return HostToolResult("Готов архив: \(archive.path) (\(FileInfo.size(FileInfo.size(of: archive.path)))).")
    }
}

// MARK: - Отправка

struct ShareFilesTool: HostTool {
    let name = "share_files"
    let description = """
    Готовит отправку файлов: открывает новое письмо в Почте, сообщение в Сообщениях или окно AirDrop \
    с приложенными файлами. Сам НЕ отправляет — человек проверяет и нажимает «Отправить». \
    Для Почты recipients — адреса email, для Сообщений — телефоны или email (найди через find_contact).
    """
    let inputSchema = Schema.object([
        "paths": Schema.paths,
        "via": Schema.string("Чем отправить", enum: ["mail", "messages", "airdrop"]),
        "recipients": .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string("Email или телефоны получателей, необязательно")
        ]),
        "subject": Schema.string("Тема письма, необязательно"),
        "message": Schema.string("Текст письма или сообщения, необязательно")
    ], required: ["paths", "via"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let paths = arguments.paths
        let missing = FileInfo.missing(paths)
        guard !paths.isEmpty, missing.isEmpty else {
            return HostToolResult(paths.isEmpty ? "Нет файлов." : "Нет таких файлов: \(missing.joined(separator: ", "))", isError: true)
        }
        let via = arguments["via"]?.stringValue ?? "mail"
        let recipients = (arguments["recipients"]?.arrayValue ?? []).compactMap(\.stringValue)
        let subject = arguments["subject"]?.stringValue
        let message = arguments["message"]?.stringValue

        let opened: Bool = await MainActor.run {
            let serviceName: NSSharingService.Name = switch via {
            case "messages": .composeMessage
            case "airdrop": .sendViaAirDrop
            default: .composeEmail
            }
            guard let service = NSSharingService(named: serviceName) else { return false }
            if !recipients.isEmpty { service.recipients = recipients }
            if let subject { service.subject = subject }
            var items: [Any] = paths.map { URL(fileURLWithPath: $0) }
            if let message, via != "airdrop" { items.insert(message, at: 0) }
            guard service.canPerform(withItems: items) else { return false }
            NSApp.activate()
            service.perform(withItems: items)
            return true
        }
        guard opened else {
            return HostToolResult("Не получилось открыть отправку через \(via): служба недоступна на этом Mac.", isError: true)
        }
        let window = switch via {
        case "messages": "окно Сообщений"
        case "airdrop": "окно AirDrop"
        default: "новое письмо в Почте"
        }
        return HostToolResult("Открыл \(window) с файлами (\(paths.count)). Ничего не отправлено: человек проверит и отправит сам.")
    }
}

struct FindContactTool: HostTool {
    let name = "find_contact"
    let description = "Ищет человека в Контактах по имени и возвращает его email и телефоны."
    let inputSchema = Schema.object(["name": Schema.string("Имя, фамилия или часть")], required: ["name"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        guard let name = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return HostToolResult("Нужно имя.", isError: true)
        }
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            break
        case .notDetermined:
            guard (try? await store.requestAccess(for: .contacts)) == true else {
                return HostToolResult("Нет доступа к Контактам.", isError: true)
            }
        default:
            return HostToolResult("Нет доступа к Контактам: разрешите его в Системных настройках → Конфиденциальность → Контакты.", isError: true)
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactEmailAddressesKey, CNContactPhoneNumbersKey
        ] as [CNKeyDescriptor]
        let contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        guard !contacts.isEmpty else { return HostToolResult("В Контактах нет «\(name)».") }

        let lines = contacts.prefix(10).map { contact -> String in
            let fullName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let emails = contact.emailAddresses.map { $0.value as String }
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            var parts = ["- \(fullName.isEmpty ? contact.organizationName : fullName)"]
            if !emails.isEmpty { parts.append("email: " + emails.joined(separator: ", ")) }
            if !phones.isEmpty { parts.append("тел.: " + phones.joined(separator: ", ")) }
            return parts.joined(separator: "; ")
        }
        return HostToolResult("Нашлось \(contacts.count):\n" + lines.joined(separator: "\n"))
    }
}
