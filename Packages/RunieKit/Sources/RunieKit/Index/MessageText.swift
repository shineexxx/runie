import Foundation

/// Текст сообщения из базы Сообщений.
///
/// У старых сообщений он лежит обычной строкой. У новых поле пустое, а сам
/// текст спрятан в `attributedBody` — это архив `NSAttributedString` старого
/// формата `typedstream`, который в Swift уже не распаковать штатными
/// средствами.
///
/// Поэтому достаём строку по устройству архива: после имени класса `NSString`
/// идёт длина и байты текста. Приём грубый, но в архиве сообщения всегда
/// ровно одна такая строка — сам текст.
enum MessageText {

    /// Текст сообщения. Сначала обычное поле, потом двоичное.
    static func text(plain: String?, attributed: Data?) -> String? {
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plain
        }
        guard let attributed else { return nil }
        return fromTypedStream(attributed)
    }

    /// Ищет строку в архиве `typedstream`.
    static func fromTypedStream(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let start = find(marker: Array("NSString".utf8), in: bytes) else { return nil }

        // За именем класса идёт немного служебных байтов, и текст начинается
        // после знака «+» — так в этом формате помечают строку.
        var index = start + 8
        let limit = min(start + 24, bytes.count)
        while index < limit, bytes[index] != 0x2B {
            index += 1
        }
        guard index < limit else { return nil }
        index += 1
        guard index < bytes.count else { return nil }

        let length: Int
        if bytes[index] == 0x81 {
            // Длинная строка: два байта длины следом за маркером.
            guard index + 2 < bytes.count else { return nil }
            length = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8)
            index += 3
        } else {
            length = Int(bytes[index])
            index += 1
        }
        guard length > 0, index + length <= bytes.count else { return nil }
        let text = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func find(marker: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= marker.count else { return nil }
        for start in 0...(bytes.count - marker.count) where Array(bytes[start..<(start + marker.count)]) == marker {
            return start
        }
        return nil
    }

    /// Время в базе Сообщений: наносекунды от 2001 года. В старых записях —
    /// секунды, поэтому маленькие числа переводим иначе.
    static func date(fromAppleTime value: Int64) -> Date {
        let seconds = value > 1_000_000_000_000 ? Double(value) / 1_000_000_000 : Double(value)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
