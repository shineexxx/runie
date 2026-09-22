import Foundation
#if canImport(AppKit)
import AppKit
import PDFKit
#endif

/// Собирает файлы в указатель.
///
/// Список берётся у Spotlight: он и так следит за диском, второй раз обходить
/// папки самим незачем. Содержимое читается только у того, что читается просто, —
/// текст, разметка, PDF; у остальных в указатель идут имя, папка и дата, по ним
/// тоже находят. Системное, скрытое и рабочие папки сборок пропускаются.
public struct FileCollector: Sendable {

    public struct Options: Sendable {
        /// Где искать. По умолчанию — дом человека.
        public var roots: [URL]
        /// Файл тяжелее — берём только имя: читать его долго, а толку мало.
        public var maxFileSize: Int
        /// Сколько знаков текста кладём в указатель.
        public var maxTextLength: Int

        public init(
            roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser],
            maxFileSize: Int = 8 * 1024 * 1024,
            maxTextLength: Int = 20_000
        ) {
            self.roots = roots
            self.maxFileSize = maxFileSize
            self.maxTextLength = maxTextLength
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Что пропускаем

    /// Папки, внутри которых человеку искать нечего: системное, кэши, сборки.
    static let skippedFolders: Set<String> = [
        "Library", "node_modules", ".git", ".build", "DerivedData", "Pods",
        ".venv", "venv", "__pycache__", ".next", "dist", "build", ".Trash",
        ".cache", "Caches", ".npm", ".gradle", "vendor"
    ]

    /// Расширения, которые незачем даже упоминать: временное и служебное.
    static let skippedExtensions: Set<String> = [
        "o", "a", "so", "dylib", "class", "pyc", "lock", "log", "tmp", "swp",
        "dSYM", "framework", "xcuserstate"
    ]

    /// Стоит ли брать этот путь вообще.
    public static func isWorthIndexing(_ url: URL) -> Bool {
        let parts = url.pathComponents
        // Скрытые папки и наши «пропускаемые» — мимо. Сам файл может быть скрытым
        // только если человек так назвал документ; такие тоже пропускаем.
        for part in parts.dropFirst() {
            if part.hasPrefix(".") && part != parts.last { return false }
            if skippedFolders.contains(part) { return false }
        }
        if url.lastPathComponent.hasPrefix(".") { return false }
        if skippedExtensions.contains(url.pathExtension) { return false }
        // Внутренности пакетов (.app, .photoslibrary) — не документы.
        if parts.dropLast().contains(where: { $0.hasSuffix(".app") || $0.hasSuffix(".photoslibrary") }) {
            return false
        }
        return true
    }

    // MARK: Содержимое

    /// Расширения, у которых читаем текст. Остальные попадают в указатель именем.
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "csv", "tsv", "json", "yaml", "yml",
        "swift", "py", "js", "ts", "tsx", "jsx", "sh", "html", "css", "xml",
        "srt", "vtt", "tex", "org", "toml", "ini", "conf"
    ]

    /// Текст файла — столько, сколько кладём в указатель. `nil`, если читать нечем.
    public func text(of url: URL) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= options.maxFileSize else { return nil }
        let ext = url.pathExtension.lowercased()

        if ext == "pdf" {
            #if canImport(AppKit)
            guard let document = PDFDocument(url: url) else { return nil }
            var text = ""
            // Больше нескольких страниц в указателе всё равно не нужно.
            for index in 0..<min(document.pageCount, 30) {
                guard let page = document.page(at: index), let piece = page.string else { continue }
                text += piece + "\n"
                if text.count >= options.maxTextLength { break }
            }
            return clip(text)
            #else
            return nil
            #endif
        }
        if ext == "rtf" {
            #if canImport(AppKit)
            guard let attributed = try? NSAttributedString(
                url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
            ) else { return nil }
            return clip(attributed.string)
            #else
            return nil
            #endif
        }
        guard Self.textExtensions.contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        // Двоичное с текстовым расширением бывает: нули — верный признак.
        guard !data.prefix(1024).contains(0) else { return nil }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return clip(text)
    }

    private func clip(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= options.maxTextLength ? trimmed : String(trimmed.prefix(options.maxTextLength))
    }

    /// Запись указателя для одного файла. `nil`, если файла нет или он не нужен.
    public func item(for url: URL) -> IndexStore.Item? {
        guard Self.isWorthIndexing(url) else { return nil }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory != true else { return nil }
        var details = ["folder": url.deletingLastPathComponent().lastPathComponent]
        if let size = values.fileSize { details["size"] = String(size) }
        if !url.pathExtension.isEmpty { details["kind"] = url.pathExtension.lowercased() }
        return IndexStore.Item(
            source: .files,
            externalID: url.path,
            // Имя без расширения читается как заголовок: «Смета на ремонт».
            title: url.deletingPathExtension().lastPathComponent,
            body: text(of: url) ?? "",
            date: values.contentModificationDate ?? Date(),
            details: details
        )
    }

    // MARK: Обход

    /// Пути, которые Spotlight знает в этих папках и которые менялись после `since`.
    public func paths(changedSince since: Date?, limit: Int = 20_000) -> [URL] {
        var found: [URL] = []
        for root in options.roots {
            found += Self.spotlightPaths(in: root, changedSince: since, limit: limit - found.count)
            if found.count >= limit { break }
        }
        return found.filter(Self.isWorthIndexing)
    }

    /// Обходит файлы и складывает их в указатель. Возвращает, сколько положил.
    ///
    /// Работа долгая, поэтому прерывается по отмене задачи: человек закрыл
    /// настройки — обход прекращается на ближайшем файле.
    @discardableResult
    public func scan(
        into store: IndexStore,
        model: MemoryModel? = nil,
        since: Date? = nil,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        let start = Date()
        let urls = paths(changedSince: since ?? store.lastScan(of: .files))
        var indexed = 0
        for url in urls {
            try Task.checkCancellation()
            guard let item = item(for: url) else { continue }
            // Вектор считаем по началу: у длинного текста смысл задаёт первый кусок.
            let vector = model?.embed(item.title + " " + String(item.body.prefix(1_000)))
            try store.put(item, vector: vector)
            indexed += 1
            if indexed % 50 == 0 {
                progress?(indexed)
                await Task.yield()
            }
        }
        try store.markScanned(.files, at: start)
        progress?(indexed)
        return indexed
    }

    // MARK: Spotlight

    /// Спрашивает Spotlight, какие файлы лежат в папке. Запрос синхронный: обход
    /// идёт в фоне, и ждать очереди главного потока незачем.
    static func spotlightPaths(in root: URL, changedSince since: Date?, limit: Int) -> [URL] {
        guard limit > 0 else { return [] }
        // Spotlight понимает только сравнения; «взять всё» — это «изменено после
        // начала времён». Дату он ждёт в своём виде `$time.iso(...)`.
        let moment = ISO8601DateFormatter.string(
            from: since ?? Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(identifier: "UTC")!,
            formatOptions: [.withInternetDateTime]
        )
        let predicate = "kMDItemContentModificationDate > $time.iso(\(moment))"
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, [root.path] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        let count = min(MDQueryGetResultCount(query), limit)
        var urls: [URL] = []
        urls.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            urls.append(URL(fileURLWithPath: path))
        }
        return urls
    }
}
