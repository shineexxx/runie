import CommonCrypto
import Foundation
import Security
import SQLite3

/// Куки Chrome: обычная база SQLite, но значения в ней зашифрованы.
///
/// Ключ шифрования Chrome держит в Связке ключей («Chrome Safe Storage»), а из
/// него выводит настоящий ключ AES. Читать Связку ключей нужно не из главного
/// потока: macOS может спросить разрешение, и на этом вопросе всё встанет.
public enum ChromeCookies {

    /// Профили Chrome: у человека их может быть несколько — личный и рабочий.
    public static func profiles(root: URL = ChromeCookies.standardRoot) -> [URL] {
        let candidates = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return candidates
            .map { $0.appending(path: "Cookies") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    public static var standardRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Google/Chrome")
    }

    /// Куки для узла из всех профилей.
    public static func cookies(for host: String, root: URL = ChromeCookies.standardRoot) throws -> [BrowserCookie] {
        let key = try encryptionKey()
        return try profiles(root: root).flatMap { try cookies(for: host, in: $0, key: key) }
    }

    /// Ключ AES: выводится из пароля в Связке ключей по правилам Chrome.
    public static func encryptionKey(service: String = "Chrome Safe Storage",
                                     account: String = "Chrome") throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let password = result as? Data else {
            throw CookieFailure.noKey("Chrome")
        }
        return derive(password: password)
    }

    /// PBKDF2 с солью и числом повторов, которые Chrome использует на macOS.
    static func derive(password: Data, salt: String = "saltysalt", rounds: UInt32 = 1003, length: Int = 16) -> Data {
        var key = Data(count: length)
        let saltBytes = Array(salt.utf8)
        let passwordBytes = Array(password)
        _ = key.withUnsafeMutableBytes { keyBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), length
            )
        }
        return key
    }

    static func cookies(for host: String, in database: URL, key: Data) throws -> [BrowserCookie] {
        // Chrome держит базу открытой — читаем копию, чтобы не спорить за блокировки.
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "runie-chrome-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: copy) }
        guard (try? FileManager.default.copyItem(at: database, to: copy)) != nil else {
            throw CookieFailure.noAccess(t("кукам Chrome"))
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw CookieFailure.damaged(t("базу кук Chrome"))
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        let sql = """
            SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly
            FROM cookies
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CookieFailure.damaged(t("базу кук Chrome"))
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [BrowserCookie] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let domain = text(statement, 0), let name = text(statement, 1) else { continue }
            let cookie = BrowserCookie(
                domain: domain,
                name: name,
                value: "",
                path: text(statement, 4) ?? "/",
                expires: expiry(sqlite3_column_int64(statement, 5)),
                isSecure: sqlite3_column_int(statement, 6) == 1,
                isHTTPOnly: sqlite3_column_int(statement, 7) == 1
            )
            guard cookie.matches(host: host) else { continue }

            var value = text(statement, 2) ?? ""
            if value.isEmpty, let blob = sqlite3_column_blob(statement, 3) {
                let count = Int(sqlite3_column_bytes(statement, 3))
                let encrypted = Data(bytes: blob, count: count)
                value = decrypt(encrypted, key: key) ?? ""
            }
            guard !value.isEmpty else { continue }
            var found = cookie
            found.value = value
            cookies.append(found)
        }
        return cookies
    }

    /// Расшифровка значения. Chrome помечает свои шифртексты версией «v10».
    static func decrypt(_ encrypted: Data, key: Data) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = String(decoding: encrypted.prefix(3), as: UTF8.self)
        guard prefix == "v10" || prefix == "v11" else {
            // Не зашифровано — значение лежит как есть.
            return String(data: encrypted, encoding: .utf8)
        }
        let body = Data(encrypted.dropFirst(3))
        // Вектор инициализации у Chrome — шестнадцать пробелов.
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let capacity = body.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            body.withUnsafeBytes { bodyBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            bodyBytes.baseAddress, body.count,
                            outputBytes.baseAddress, capacity, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        var plain = output.prefix(moved)
        // В новых версиях перед значением лежат 32 байта проверки домена.
        if plain.count > 32, String(data: plain, encoding: .utf8) == nil {
            plain = plain.dropFirst(32)
        }
        return String(data: plain, encoding: .utf8)
    }

    /// Время Chrome: микросекунды от 1601 года.
    static func expiry(_ raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        let seconds = Double(raw) / 1_000_000 - 11_644_473_600
        return Date(timeIntervalSince1970: seconds)
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}
