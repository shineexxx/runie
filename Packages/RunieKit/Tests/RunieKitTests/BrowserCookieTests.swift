import CommonCrypto
import Foundation
import SQLite3
import Testing
@testable import RunieKit

/// Разбор кук проверяется на файлах, собранных здесь же: настоящие куки
/// человека для этого не нужны и в проверках им делать нечего.
@Suite("Куки из браузеров")
struct BrowserCookieTests {

    // MARK: Кому подходит кука

    @Test("кука с точкой покрывает поддомены, без точки — только сам узел")
    func matching() {
        let wide = BrowserCookie(domain: ".example.com", name: "s", value: "1")
        #expect(wide.matches(host: "example.com"))
        #expect(wide.matches(host: "dnevnik.example.com"))
        #expect(!wide.matches(host: "notexample.com"))
        #expect(!wide.matches(host: "example.com.evil.ru"))

        let exact = BrowserCookie(domain: "example.com", name: "s", value: "1")
        #expect(exact.matches(host: "example.com"))
        #expect(!exact.matches(host: "dnevnik.example.com"))
        #expect(BrowserCookie(domain: "EXAMPLE.com", name: "s", value: "1").matches(host: "example.COM"))
    }

    @Test("просроченная кука видна как просроченная")
    func expiry() {
        let now = Date()
        #expect(BrowserCookie(domain: "a.ru", name: "s", value: "1",
                              expires: now.addingTimeInterval(-60)).isExpired(at: now))
        #expect(!BrowserCookie(domain: "a.ru", name: "s", value: "1",
                               expires: now.addingTimeInterval(60)).isExpired(at: now))
        // Кука сессии живёт, пока открыт браузер, — сроком не ограничена.
        #expect(!BrowserCookie(domain: "a.ru", name: "s", value: "1").isExpired(at: now))
    }

    // MARK: Safari

    @Test("разбор файла Safari: домен, имя, значение, срок и флаги")
    func safari() throws {
        let expires = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let file = SafariCookieFile(cookies: [
            .init(domain: ".dnevnik.ru", name: "sid", value: "abc123", path: "/",
                  expires: expires, isSecure: true, isHTTPOnly: true),
            .init(domain: "example.com", name: "theme", value: "dark", path: "/settings")
        ])
        let parsed = try SafariCookies.parse(file.data())
        #expect(parsed.count == 2)

        let session = try #require(parsed.first { $0.name == "sid" })
        #expect(session.domain == ".dnevnik.ru")
        #expect(session.value == "abc123")
        #expect(session.isSecure)
        #expect(session.isHTTPOnly)
        #expect(abs((session.expires ?? .distantPast).timeIntervalSinceReferenceDate - 800_000_000) < 1)

        let theme = try #require(parsed.first { $0.name == "theme" })
        #expect(theme.path == "/settings")
        #expect(!theme.isSecure)
    }

    @Test("страницы разбираются все, а не только первая")
    func safariPages() throws {
        let file = SafariCookieFile(
            pages: [[.init(domain: "a.ru", name: "one", value: "1")],
                    [.init(domain: "b.ru", name: "two", value: "2"),
                     .init(domain: "c.ru", name: "three", value: "3")]]
        )
        let parsed = try SafariCookies.parse(file.data())
        #expect(parsed.map(\.name).sorted() == ["one", "three", "two"])
    }

    @Test("чужой файл не притворяется куками")
    func safariGarbage() throws {
        #expect(throws: CookieFailure.self) { try SafariCookies.parse(Data("не куки".utf8)) }
        #expect(throws: CookieFailure.self) { try SafariCookies.parse(Data()) }
        // Обрезанный заголовок: страниц обещано больше, чем есть. Верить такому
        // файлу нельзя — лучше честно сказать, что он испорчен.
        var truncated = Data("cook".utf8)
        truncated.append(contentsOf: [0, 0, 0, 2, 0, 0, 0, 90])
        #expect(throws: CookieFailure.self) { try SafariCookies.parse(truncated) }

        // А вот оборванный хвост не страшен: что успели разобрать — то и берём.
        var short = SafariCookieFile(cookies: [.init(domain: "a.ru", name: "one", value: "1")]).data()
        short = short.prefix(short.count - 10)
        #expect(try SafariCookies.parse(short).isEmpty)
    }

    @Test("нет файла — понятная ошибка про доступ")
    func safariMissing() {
        let nowhere = FileManager.default.temporaryDirectory.appending(path: "нет-таких-\(UUID().uuidString)")
        #expect(throws: CookieFailure.self) { try SafariCookies.cookies(at: nowhere) }
    }

    // MARK: Chrome

    @Test("ключ выводится так же, как его выводит Chrome")
    func chromeKey() {
        let key = ChromeCookies.derive(password: Data("пароль из связки".utf8))
        #expect(key.count == 16)
        // Тот же пароль — тот же ключ; другой — другой.
        #expect(key == ChromeCookies.derive(password: Data("пароль из связки".utf8)))
        #expect(key != ChromeCookies.derive(password: Data("другой".utf8)))
    }

    @Test("значение расшифровывается обратно")
    func chromeDecrypt() throws {
        let key = ChromeCookies.derive(password: Data("тест".utf8))
        let encrypted = try #require(encrypt("секретное значение", key: key))
        #expect(ChromeCookies.decrypt(encrypted, key: key) == "секретное значение")
        // Чужим ключом не расшифровать.
        #expect(ChromeCookies.decrypt(encrypted, key: ChromeCookies.derive(password: Data("не тот".utf8))) != "секретное значение")
        // Незашифрованное значение возвращается как есть.
        #expect(ChromeCookies.decrypt(Data("открытым текстом".utf8), key: key) == "открытым текстом")
    }

    @Test("время Chrome переводится в обычное")
    func chromeTime() throws {
        // 1 января 2020 года в микросекундах от 1601 года.
        let raw = Int64((Date(timeIntervalSince1970: 1_577_836_800).timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let date = try #require(ChromeCookies.expiry(raw))
        #expect(abs(date.timeIntervalSince1970 - 1_577_836_800) < 1)
        #expect(ChromeCookies.expiry(0) == nil)
    }

    @Test("из базы берутся только куки нужного сайта")
    func chromeDatabase() throws {
        let key = ChromeCookies.derive(password: Data("тест".utf8))
        let database = try ChromeCookieFile(cookies: [
            ("dnevnik.ru", "sid", "нужная"),
            (".dnevnik.ru", "auth", "тоже нужная"),
            ("bank.example", "token", "чужая")
        ], key: key).write()
        defer { try? FileManager.default.removeItem(at: database) }

        let found = try ChromeCookies.cookies(for: "dnevnik.ru", in: database, key: key)
        #expect(found.map(\.name).sorted() == ["auth", "sid"])
        #expect(found.first { $0.name == "sid" }?.value == "нужная")
        // Куки чужого сайта не уезжают вместе с нужными — ради этого всё и затевалось.
        #expect(!found.contains { $0.name == "token" })
    }

    // MARK: Вспомогательное

    private func encrypt(_ text: String, key: Data) -> Data? {
        let plain = Data(text.utf8)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let capacity = plain.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            plain.withUnsafeBytes { plainBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                plainBytes.baseAddress, plain.count,
                                outputBytes.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data("v10".utf8) + output.prefix(moved)
    }
}

/// Сборщик файла Safari того же вида, что пишет сам Safari.
private struct SafariCookieFile {
    var pages: [[BrowserCookie]]

    init(cookies: [BrowserCookie]) {
        pages = [cookies]
    }

    init(pages: [[BrowserCookie]]) {
        self.pages = pages
    }

    func data() -> Data {
        let bodies = pages.map(page)
        var file = Data("cook".utf8)
        file += UInt32(bodies.count).bigEndianData
        for body in bodies { file += UInt32(body.count).bigEndianData }
        for body in bodies { file += body }
        return file
    }

    private func page(_ cookies: [BrowserCookie]) -> Data {
        let records = cookies.map(record)
        // Заголовок страницы: метка, счётчик, смещения записей и нулевое поле.
        let headerSize = 4 + 4 + records.count * 4 + 4
        var offsets: [UInt32] = []
        var running = headerSize
        for record in records {
            offsets.append(UInt32(running))
            running += record.count
        }
        var page = Data([0x00, 0x00, 0x01, 0x00])
        page += UInt32(records.count).littleEndianData
        for offset in offsets { page += offset.littleEndianData }
        page += UInt32(0).littleEndianData
        for record in records { page += record }
        return page
    }

    private func record(_ cookie: BrowserCookie) -> Data {
        let domain = Data(cookie.domain.utf8) + [0]
        let name = Data(cookie.name.utf8) + [0]
        let path = Data(cookie.path.utf8) + [0]
        let value = Data(cookie.value.utf8) + [0]
        let start = 56
        let domainOffset = start
        let nameOffset = domainOffset + domain.count
        let pathOffset = nameOffset + name.count
        let valueOffset = pathOffset + path.count
        let size = valueOffset + value.count

        var flags: UInt32 = 0
        if cookie.isSecure { flags |= 1 }
        if cookie.isHTTPOnly { flags |= 4 }

        var record = UInt32(size).littleEndianData
        record += UInt32(0).littleEndianData
        record += flags.littleEndianData
        record += UInt32(0).littleEndianData
        record += UInt32(domainOffset).littleEndianData
        record += UInt32(nameOffset).littleEndianData
        record += UInt32(pathOffset).littleEndianData
        record += UInt32(valueOffset).littleEndianData
        // Поле комментария и восемь нулей до срока.
        record += UInt32(0).littleEndianData
        record += UInt32(0).littleEndianData
        record += (cookie.expires?.timeIntervalSinceReferenceDate ?? 0).bitPattern.littleEndianData
        record += UInt64(0).littleEndianData
        record += domain + name + path + value
        return record
    }
}

/// Сборщик базы кук того же вида, что у Chrome.
private struct ChromeCookieFile {
    var cookies: [(host: String, name: String, value: String)]
    var key: Data

    func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "runie-chrome-test-\(UUID().uuidString).db")
        var handle: OpaquePointer?
        sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { sqlite3_close(handle) }
        sqlite3_exec(handle, """
            CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
                                  path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER);
            """, nil, nil, nil)
        for cookie in cookies {
            let encrypted = Self.encrypt(cookie.value, key: key) ?? Data()
            var statement: OpaquePointer?
            sqlite3_prepare_v2(handle, """
                INSERT INTO cookies (host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly)
                VALUES (?, ?, '', ?, '/', 0, 1, 1)
                """, -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, cookie.host, -1, transient)
            sqlite3_bind_text(statement, 2, cookie.name, -1, transient)
            _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(encrypted.count), transient) }
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        return url
    }

    static func encrypt(_ text: String, key: Data) -> Data? {
        let plain = Data(text.utf8)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let capacity = plain.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            plain.withUnsafeBytes { plainBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                plainBytes.baseAddress, plain.count,
                                outputBytes.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data("v10".utf8) + output.prefix(moved)
    }
}

private extension UInt32 {
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}

private extension UInt64 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}
