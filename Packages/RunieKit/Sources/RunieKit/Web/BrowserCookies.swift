import Foundation

/// Кука из браузера человека.
public struct BrowserCookie: Equatable, Sendable {
    public var domain: String
    public var name: String
    public var value: String
    public var path: String
    public var expires: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool

    public init(domain: String, name: String, value: String, path: String = "/",
                expires: Date? = nil, isSecure: Bool = false, isHTTPOnly: Bool = false) {
        self.domain = domain
        self.name = name
        self.value = value
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }

    /// Подходит ли кука сайту. `.example.com` покрывает и `dnevnik.example.com`,
    /// а `example.com` без точки — только сам этот узел.
    public func matches(host: String) -> Bool {
        let host = host.lowercased()
        let domain = domain.lowercased()
        if domain.hasPrefix(".") {
            let bare = String(domain.dropFirst())
            return host == bare || host.hasSuffix(domain)
        }
        return host == domain
    }

    /// Просрочена ли на указанный момент.
    public func isExpired(at moment: Date = Date()) -> Bool {
        guard let expires else { return false }
        return expires <= moment
    }
}

/// Откуда Руни берёт куки: из браузеров человека.
///
/// Куки берутся только для того сайта, куда Руни идёт прямо сейчас, — и только
/// когда человек это разрешил. Ни в ответ модели, ни в файлы они не попадают:
/// прямо из браузера в свой невидимый и обратно никуда.
public enum BrowserCookieSource: String, CaseIterable, Sendable {
    case safari
    case chrome

    public var title: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        }
    }
}

public enum CookieFailure: Error, Equatable, LocalizedError {
    case noAccess(String)
    case damaged(String)
    case noKey(String)

    public var errorDescription: String? {
        switch self {
        case .noAccess(let what): t("Нет доступа к \(what). Дайте Руни полный доступ к диску в настройках macOS.")
        case .damaged(let what): t("Не удалось разобрать \(what).")
        case .noKey(let browser): t("В Связке ключей нет ключа, которым \(browser) шифрует свои куки.")
        }
    }
}

// MARK: - Safari

/// Куки Safari: свой двоичный формат `Cookies.binarycookies`.
///
/// Формат не документирован, но устойчив много лет: заголовок «cook», список
/// страниц, в каждой — записи со смещениями строк внутри себя.
public enum SafariCookies {

    public static var standardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
    }

    /// Куки для узла. Пустой `host` — все куки файла.
    public static func cookies(for host: String? = nil,
                               at url: URL = SafariCookies.standardURL) throws -> [BrowserCookie] {
        guard let data = try? Data(contentsOf: url) else {
            throw CookieFailure.noAccess(t("кукам Safari"))
        }
        return try parse(data).filter { cookie in
            guard let host, !host.isEmpty else { return true }
            return cookie.matches(host: host)
        }
    }

    static func parse(_ data: Data) throws -> [BrowserCookie] {
        let reader = ByteReader(data)
        guard reader.string(4) == "cook", let pageCount = reader.uint32(.big) else {
            throw CookieFailure.damaged(t("файл кук Safari"))
        }
        var sizes: [Int] = []
        for _ in 0..<pageCount {
            guard let size = reader.uint32(.big) else { throw CookieFailure.damaged(t("файл кук Safari")) }
            sizes.append(Int(size))
        }
        var cookies: [BrowserCookie] = []
        for size in sizes {
            guard let page = reader.slice(size) else { break }
            cookies += parsePage(page)
        }
        return cookies
    }

    private static func parsePage(_ page: Data) -> [BrowserCookie] {
        let reader = ByteReader(page)
        // Заголовок страницы: метка и число записей.
        _ = reader.uint32(.big)
        guard let count = reader.uint32(.little) else { return [] }
        var offsets: [Int] = []
        for _ in 0..<count {
            guard let offset = reader.uint32(.little) else { return [] }
            offsets.append(Int(offset))
        }
        return offsets.compactMap { parseCookie(page, at: $0) }
    }

    private static func parseCookie(_ page: Data, at start: Int) -> BrowserCookie? {
        let reader = ByteReader(page, at: start)
        guard let size = reader.uint32(.little), size > 56 else { return nil }
        _ = reader.uint32(.little)
        guard let flags = reader.uint32(.little) else { return nil }
        _ = reader.uint32(.little)
        guard let domainOffset = reader.uint32(.little),
              let nameOffset = reader.uint32(.little),
              let pathOffset = reader.uint32(.little),
              let valueOffset = reader.uint32(.little)
        else { return nil }
        // Между смещениями и сроком — поле комментария и восемь нулей.
        let expiryReader = ByteReader(page, at: start + 40)
        let expiry = expiryReader.double()

        func text(_ offset: UInt32) -> String? {
            guard offset > 0 else { return nil }
            return ByteReader(page, at: start + Int(offset)).cString()
        }
        guard let domain = text(domainOffset), let name = text(nameOffset) else { return nil }
        return BrowserCookie(
            domain: domain,
            name: name,
            value: text(valueOffset) ?? "",
            path: text(pathOffset) ?? "/",
            // Время в формате Apple: секунды от 2001 года.
            expires: expiry.map { Date(timeIntervalSinceReferenceDate: $0) },
            isSecure: flags & 1 != 0,
            isHTTPOnly: flags & 4 != 0
        )
    }
}

// MARK: - Разбор байтов

/// Чтение чисел и строк по смещениям — чтобы разбор формата читался как описание.
final class ByteReader {
    enum Endian { case little, big }

    private let data: Data
    private var index: Int

    init(_ data: Data, at index: Int = 0) {
        self.data = data
        self.index = index
    }

    func uint32(_ endian: Endian) -> UInt32? {
        guard index + 4 <= data.count else { return nil }
        let bytes = (0..<4).map { UInt32(data[data.startIndex + index + $0]) }
        index += 4
        return endian == .little
            ? bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24
            : bytes[3] | bytes[2] << 8 | bytes[1] << 16 | bytes[0] << 24
    }

    func double() -> Double? {
        guard index + 8 <= data.count else { return nil }
        var raw: UInt64 = 0
        for offset in 0..<8 {
            raw |= UInt64(data[data.startIndex + index + offset]) << (8 * UInt64(offset))
        }
        index += 8
        let value = Double(bitPattern: raw)
        return value.isFinite && value > 0 ? value : nil
    }

    func string(_ count: Int) -> String? {
        guard let slice = slice(count) else { return nil }
        return String(data: slice, encoding: .utf8)
    }

    /// Строка до нулевого байта.
    func cString() -> String? {
        var bytes: [UInt8] = []
        while index < data.count {
            let byte = data[data.startIndex + index]
            index += 1
            if byte == 0 { break }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    func slice(_ count: Int) -> Data? {
        guard count >= 0, index + count <= data.count else { return nil }
        let start = data.startIndex + index
        index += count
        return data[start..<(start + count)]
    }
}
