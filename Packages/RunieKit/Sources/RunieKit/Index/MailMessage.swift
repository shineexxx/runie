import Foundation

/// Разбор письма из файла Почты (`.emlx`).
///
/// Формат простой: первая строка — длина письма, дальше само письмо по RFC 822,
/// в конце служебный plist. Нас интересуют тема, отправитель, дата и текст.
///
/// Разбор нарочно щадящий: почта в жизни бывает какой угодно, и сломаться на
/// одном кривом письме, потеряв весь обход, — плохой размен. Чего не поняли,
/// то пропускаем.
public struct MailMessage: Equatable, Sendable {

    public var subject: String
    public var sender: String
    public var date: Date?
    public var body: String

    public init(subject: String, sender: String, date: Date?, body: String) {
        self.subject = subject
        self.sender = sender
        self.date = date
        self.body = body
    }

    /// Разбирает содержимое `.emlx`. `nil`, если это вообще не письмо.
    public static func parse(emlx data: Data, maxBodyLength: Int = 20_000) -> MailMessage? {
        // Первая строка — длина письма в байтах; по ней отрезаем служебный plist.
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let header = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
        let length = Int(header.trimmingCharacters(in: .whitespaces)) ?? 0
        let start = data.index(after: newline)
        let end = length > 0 ? data.index(start, offsetBy: min(length, data.count - (start - data.startIndex)))
                             : data.endIndex
        return parse(message: data[start..<end], maxBodyLength: maxBodyLength)
    }

    /// Разбирает письмо по RFC 822: заголовки, потом тело.
    public static func parse(message data: Data, maxBodyLength: Int = 20_000) -> MailMessage? {
        let text = decodeText(data, charset: nil)
        guard !text.isEmpty else { return nil }
        let (headerText, bodyText) = split(text)
        let headers = parseHeaders(headerText)
        guard !headers.isEmpty else { return nil }

        let body = extractBody(bodyText, headers: headers, maxLength: maxBodyLength)
        return MailMessage(
            subject: decodeWords(headers["subject"] ?? ""),
            sender: decodeWords(headers["from"] ?? ""),
            date: headers["date"].flatMap(parseDate),
            body: body
        )
    }

    // MARK: Заголовки

    /// Делит письмо на заголовки и тело по первой пустой строке.
    private static func split(_ text: String) -> (String, String) {
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = text.range(of: separator) {
                return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
            }
        }
        return (text, "")
    }

    /// Заголовки письма. Ключи в нижнем регистре; продолжения строк склеиваются.
    static func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        var key = ""
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                // Длинный заголовок перенесён на следующую строку.
                guard !key.isEmpty else { continue }
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return headers
    }

    /// `=?UTF-8?B?...?=` — так в заголовках прячут не-латиницу.
    ///
    /// Границу куска ищем выражением с ленивым концом: искать «?=» простым
    /// поиском нельзя — в самом тексте куска эти два знака стоят у каждого
    /// байта («?Q?=D0=9F»), и конец находился бы слишком рано.
    static func decodeWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let pattern = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?(.*?)\?="#)
        guard let pattern else { return text }
        let full = text as NSString
        var result = ""
        var position = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: full.length)) {
            result += full.substring(with: NSRange(location: position, length: match.range.location - position))
            let charset = full.substring(with: match.range(at: 1))
            let encoding = full.substring(with: match.range(at: 2)).uppercased()
            let payload = full.substring(with: match.range(at: 3))
            let decoded: String?
            if encoding == "B" {
                decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
                    .map { decodeText($0, charset: charset) }
            } else {
                // В заголовках подчёркивание означает пробел.
                decoded = decodeQuotedPrintable(payload.replacingOccurrences(of: "_", with: " "), charset: charset)
            }
            result += decoded ?? payload
            position = match.range.location + match.range.length
        }
        result += full.substring(from: position)
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Дата письма. Формат в почте один, но часовой пояс пишут по-разному.
    static func parseDate(_ text: String) -> Date? {
        let cleaned = text.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            dateFormatter.dateFormat = format
            if let date = dateFormatter.date(from: cleaned) { return date }
        }
        return nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: Тело

    /// Текст письма: берём первую текстовую часть, разметку — только если другой нет.
    private static func extractBody(_ text: String, headers: [String: String], maxLength: Int) -> String {
        let contentType = headers["content-type"] ?? "text/plain"
        var plain: String?
        var html: String?

        if let boundary = boundary(in: contentType) {
            // Составное письмо: куски разделены границей, у каждого свои заголовки.
            for part in text.components(separatedBy: "--" + boundary).dropFirst() {
                let (partHeader, partBody) = split(part)
                let partHeaders = parseHeaders(partHeader)
                let type = (partHeaders["content-type"] ?? "").lowercased()
                if let inner = Self.boundary(in: type) {
                    // Вложенная составная часть — разбираем её так же.
                    let nested = extractBody(partBody, headers: ["content-type": "multipart; boundary=\(inner)"], maxLength: maxLength)
                    if plain == nil, !nested.isEmpty { plain = nested }
                    continue
                }
                guard type.contains("text/") else { continue }
                let decoded = decodePart(partBody, headers: partHeaders)
                if type.contains("text/plain"), plain == nil {
                    plain = decoded
                } else if type.contains("text/html"), html == nil {
                    html = decoded
                }
            }
        } else if contentType.lowercased().contains("text/html") {
            html = decodePart(text, headers: headers)
        } else {
            plain = decodePart(text, headers: headers)
        }

        let body = plain ?? html.map(stripHTML) ?? ""
        let trimmed = body
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= maxLength ? trimmed : String(trimmed.prefix(maxLength))
    }

    /// Граница составного письма из `Content-Type`.
    static func boundary(in contentType: String) -> String? {
        guard contentType.lowercased().contains("multipart"),
              let range = contentType.range(of: #"boundary="?([^";]+)"?"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return contentType[range]
            .replacingOccurrences(of: "boundary=", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    /// Раскодирует часть письма по её `Content-Transfer-Encoding`.
    private static func decodePart(_ text: String, headers: [String: String]) -> String {
        let charset = self.charset(in: headers["content-type"] ?? "")
        switch (headers["content-transfer-encoding"] ?? "").lowercased() {
        case "base64":
            let joined = text.components(separatedBy: .whitespacesAndNewlines).joined()
            guard let data = Data(base64Encoded: joined, options: .ignoreUnknownCharacters) else { return text }
            return decodeText(data, charset: charset)
        case "quoted-printable":
            return decodeQuotedPrintable(text, charset: charset) ?? text
        default:
            return text
        }
    }

    static func charset(in contentType: String) -> String? {
        guard let range = contentType.range(of: #"charset="?([^";]+)"?"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return contentType[range]
            .replacingOccurrences(of: "charset=", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    /// Байты в строку с оглядкой на кодировку письма.
    static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset, charset.lowercased() != "utf-8" {
            let encoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            )
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// `=D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82` — «Привет».
    static func decodeQuotedPrintable(_ text: String, charset: String?) -> String? {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "=" {
                let next = text.index(after: index)
                // «=» в конце строки — перенос, его просто выбрасываем.
                if next < text.endIndex, text[next] == "\r" || text[next] == "\n" {
                    index = next
                    while index < text.endIndex, text[index] == "\r" || text[index] == "\n" {
                        index = text.index(after: index)
                    }
                    continue
                }
                let hexEnd = text.index(index, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                if let byte = UInt8(text[text.index(after: index)..<hexEnd], radix: 16) {
                    bytes.append(byte)
                    index = hexEnd
                    continue
                }
            }
            bytes.append(contentsOf: Array(String(character).utf8))
            index = text.index(after: index)
        }
        return decodeText(Data(bytes), charset: charset)
    }

    /// Текст из разметки: письма часто приходят только в HTML.
    static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in [#"<script[^>]*>[\s\S]*?</script>"#, #"<style[^>]*>[\s\S]*?</style>"#, #"<head[^>]*>[\s\S]*?</head>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"<(br|/p|/div|/tr|/h[1-6])[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&laquo;": "«", "&raquo;": "»", "&mdash;": "—", "&ndash;": "–"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // Числовые ссылки вида &#1055;
        while let range = text.range(of: #"&#\d+;"#, options: .regularExpression) {
            let digits = text[range].dropFirst(2).dropLast()
            let replacement = UInt32(digits).flatMap(Unicode.Scalar.init).map(String.init) ?? " "
            text.replaceSubrange(range, with: replacement)
        }
        return text
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
