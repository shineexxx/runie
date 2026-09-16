import Foundation

/// Собирает построчный поток из произвольно нарезанных кусков байтов.
///
/// Пайп отдаёт данные кусками, которые не совпадают с границами строк: одно событие
/// может прийти тремя чтениями, а три события — одним. Событие `system/init` со списком
/// инструментов легко переваливает за десятки килобайт, так что «прочитать строку»
/// нельзя считать атомарной операцией.
///
/// Тип намеренно не потокобезопасен: владелец обязан обращаться к нему с одной очереди.
public struct NDJSONLineSplitter: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        /// Строка превысила лимит. Так выглядит либо повреждённый поток, либо не-NDJSON
        /// вывод в stdout. Копить такое в памяти бесконечно нельзя.
        case lineTooLong(limit: Int)
    }

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    /// Предел длины одной строки. По умолчанию 8 МиБ: `system/init` бывает большим,
    /// но не настолько.
    public let maximumLineLength: Int

    private var buffer: [UInt8] = []

    public init(maximumLineLength: Int = 8 * 1024 * 1024) {
        self.maximumLineLength = maximumLineLength
    }

    /// Добавляет очередной кусок и возвращает все завершённые строки.
    ///
    /// Пустые строки отбрасываются: CLI иногда разделяет события лишним переводом строки,
    /// и это не ошибка.
    public mutating func append(_ data: Data) throws -> [Data] {
        guard !data.isEmpty else { return [] }

        var lines: [Data] = []
        // Начало текущей строки — всегда начало буфера: остаток с прошлого раза
        // переводов строк не содержит, иначе он бы уже уехал.
        var lineStart = 0
        // Искать переводы строк достаточно в новом куске: старый уже просмотрен.
        let scanFrom = buffer.count
        buffer.append(contentsOf: data)

        var index = scanFrom
        while index < buffer.count {
            if buffer[index] == Self.newline {
                var end = index
                // CRLF: сам CLI так не делает, но поток может пройти через то, что делает.
                // Возврат каретки мог прийти прошлым куском, поэтому сравниваем
                // с началом строки, а не с началом куска.
                if end > lineStart, buffer[end - 1] == Self.carriageReturn {
                    end -= 1
                }
                if end > lineStart {
                    lines.append(Data(buffer[lineStart..<end]))
                }
                lineStart = index + 1
            }
            index += 1
        }

        if lineStart > 0 {
            buffer.removeFirst(lineStart)
        }

        if buffer.count > maximumLineLength {
            buffer.removeAll(keepingCapacity: false)
            throw Failure.lineTooLong(limit: maximumLineLength)
        }

        return lines
    }

    /// Возвращает остаток, не завершённый переводом строки.
    ///
    /// Вызывается когда процесс закрыл поток: последняя строка может прийти без `\n`.
    public mutating func flush() -> Data? {
        defer { buffer.removeAll(keepingCapacity: false) }
        var end = buffer.count
        if end > 0, buffer[end - 1] == Self.carriageReturn { end -= 1 }
        guard end > 0 else { return nil }
        return Data(buffer[0..<end])
    }

    /// Сколько байт сейчас лежит в незавершённой строке.
    public var pendingByteCount: Int { buffer.count }
}
