import Foundation
import Testing
@testable import RunieKit

@Suite("NDJSONLineSplitter")
struct NDJSONLineSplitterTests {

    private func text(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("несколько строк в одном куске")
    func multipleLinesInOneChunk() throws {
        var splitter = NDJSONLineSplitter()
        let lines = try splitter.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        #expect(text(lines) == ["{\"a\":1}", "{\"b\":2}"])
        #expect(splitter.pendingByteCount == 0)
    }

    @Test("строка, разрезанная между кусками, собирается обратно")
    func lineSplitAcrossChunks() throws {
        var splitter = NDJSONLineSplitter()
        #expect(try splitter.append(Data("{\"ty".utf8)).isEmpty)
        #expect(try splitter.append(Data("pe\":\"as".utf8)).isEmpty)
        let lines = try splitter.append(Data("sistant\"}\n".utf8))
        #expect(text(lines) == ["{\"type\":\"assistant\"}"])
    }

    @Test("байт за байтом собирается в одну строку")
    func byteByByte() throws {
        var splitter = NDJSONLineSplitter()
        let source = "{\"x\":true}\n"
        var collected: [Data] = []
        for byte in Array(source.utf8) {
            collected += try splitter.append(Data([byte]))
        }
        #expect(text(collected) == ["{\"x\":true}"])
    }

    @Test("пустые строки отбрасываются")
    func dropsEmptyLines() throws {
        var splitter = NDJSONLineSplitter()
        let lines = try splitter.append(Data("\n\n{\"a\":1}\n\n".utf8))
        #expect(text(lines) == ["{\"a\":1}"])
    }

    @Test("CRLF обрезается, даже если возврат каретки пришёл прошлым куском")
    func handlesCarriageReturnAcrossChunkBoundary() throws {
        var splitter = NDJSONLineSplitter()
        #expect(try splitter.append(Data("{\"a\":1}\r".utf8)).isEmpty)
        let lines = try splitter.append(Data("\n".utf8))
        #expect(text(lines) == ["{\"a\":1}"])
    }

    @Test("незавершённая строка возвращается через flush")
    func flushReturnsTail() throws {
        var splitter = NDJSONLineSplitter()
        _ = try splitter.append(Data("{\"a\":1}\n{\"b\":2}".utf8))
        let tail = splitter.flush()
        #expect(tail.map { String(decoding: $0, as: UTF8.self) } == "{\"b\":2}")
        #expect(splitter.flush() == nil)
    }

    @Test("flush на пустом буфере ничего не возвращает")
    func flushOnEmptyBuffer() throws {
        var splitter = NDJSONLineSplitter()
        _ = try splitter.append(Data("{\"a\":1}\n".utf8))
        #expect(splitter.flush() == nil)
    }

    @Test("слишком длинная строка не копится в памяти бесконечно")
    func rejectsOverlongLine() throws {
        var splitter = NDJSONLineSplitter(maximumLineLength: 64)
        #expect(throws: NDJSONLineSplitter.Failure.lineTooLong(limit: 64)) {
            _ = try splitter.append(Data(repeating: UInt8(ascii: "x"), count: 128))
        }
        #expect(splitter.pendingByteCount == 0)
    }

    @Test("длинная строка проходит, если укладывается в лимит")
    func acceptsLargeLineWithinLimit() throws {
        var splitter = NDJSONLineSplitter(maximumLineLength: 1024)
        var payload = Data(repeating: UInt8(ascii: "y"), count: 1000)
        payload.append(UInt8(ascii: "\n"))
        let lines = try splitter.append(payload)
        #expect(lines.count == 1)
        #expect(lines[0].count == 1000)
    }

    @Test("пустой кусок ничего не меняет")
    func emptyChunkIsNoop() throws {
        var splitter = NDJSONLineSplitter()
        _ = try splitter.append(Data("{\"a\":".utf8))
        #expect(try splitter.append(Data()).isEmpty)
        #expect(splitter.pendingByteCount == 5)
    }

    @Test("многобайтовые символы переживают разрез по границе куска")
    func handlesMultibyteAcrossChunks() throws {
        var splitter = NDJSONLineSplitter()
        let source = Array("{\"t\":\"привет\"}\n".utf8)
        let middle = source.count / 2
        #expect(try splitter.append(Data(source[0..<middle])).isEmpty)
        let lines = try splitter.append(Data(source[middle...]))
        #expect(text(lines) == ["{\"t\":\"привет\"}"])
    }
}
