import Foundation

/// Модель смыслового поиска по памяти: многоязычная матрица эмбеддингов.
///
/// Трансформера здесь нет. Это статическая модель (sentence-transformers
/// `static-similarity-mrl-multilingual-v1`, Apache 2.0): вектор фразы —
/// среднее строк матрицы по её токенам. Поэтому поиск работает мгновенно и
/// без Core ML, а всё хозяйство — два файла, которые человек скачивает по
/// своему желанию: `matrix.bin` (54 МБ) и `vocab.txt`.
///
/// Матрица читается с диска отображением в память: 54 МБ не поднимаются в
/// оперативную целиком, система подтягивает нужные строки сама.
public struct MemoryModel: Sendable {

    public static let magic = "RUNIEMB1"

    /// `~/Library/Application Support/Runie/Model`.
    public static var standardDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Runie/Model", directoryHint: .isDirectory)
    }

    public static func matrixURL(in directory: URL) -> URL { directory.appendingPathComponent("matrix.bin") }
    public static func vocabURL(in directory: URL) -> URL { directory.appendingPathComponent("vocab.txt") }

    /// Скачана ли модель.
    public static func isInstalled(in directory: URL = standardDirectory) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: matrixURL(in: directory).path)
            && fileManager.fileExists(atPath: vocabURL(in: directory).path)
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notInstalled
        case damaged(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: t("Модель смыслового поиска не скачана.")
            case .damaged(let reason): t("Файл модели испорчен: \(reason)")
            }
        }
    }

    private let matrix: Data
    /// Смещение матрицы в файле: за шапкой.
    private let offset: Int
    public let dimensions: Int
    public let tokenCount: Int
    let tokenizer: MemoryTokenizer

    public init(directory: URL = MemoryModel.standardDirectory) throws {
        guard Self.isInstalled(in: directory) else { throw Failure.notInstalled }
        let data = try Data(contentsOf: Self.matrixURL(in: directory), options: .mappedIfSafe)
        let header = Self.magic.count + 8
        guard data.count > header, String(data: data.prefix(Self.magic.count), encoding: .utf8) == Self.magic else {
            throw Failure.damaged(t("не та шапка"))
        }
        let dimensions = Int(data.uint32(at: Self.magic.count))
        let tokenCount = Int(data.uint32(at: Self.magic.count + 4))
        guard dimensions > 0, tokenCount > 0,
              data.count >= header + dimensions * tokenCount * 2 else {
            throw Failure.damaged(t("не сходятся размеры"))
        }
        let vocabulary = try String(contentsOf: Self.vocabURL(in: directory), encoding: .utf8)
        let tokens = vocabulary.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count == tokenCount else {
            throw Failure.damaged(t("в словаре \(tokens.count) строк вместо \(tokenCount)"))
        }
        self.matrix = data
        self.offset = header
        self.dimensions = dimensions
        self.tokenCount = tokenCount
        self.tokenizer = MemoryTokenizer(tokens: tokens)
    }

    /// Вектор фразы единичной длины. Пустой текст — `nil`.
    public func embed(_ text: String) -> [Float]? {
        // Пустая строка или одни пробелы: остались бы только [CLS] и [SEP],
        // а их вектор ничего не значит.
        guard !MemoryTokenizer.split(text).isEmpty else { return nil }
        let ids = tokenizer.encode(text)
        guard !ids.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: dimensions)
        matrix.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Float16.self)
            for id in ids where id < tokenCount {
                let row = base.advanced(by: id * dimensions)
                for index in 0..<dimensions {
                    sum[index] += Float(row[index])
                }
            }
        }
        var norm: Float = 0
        for value in sum { norm += value * value }
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        return sum.map { $0 / norm }
    }

    /// Косинус между векторами единичной длины: от −1 до 1.
    public static func similarity(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count else { return 0 }
        var sum: Float = 0
        for index in 0..<first.count { sum += first[index] * second[index] }
        return sum
    }
}

private extension Data {
    func uint32(at index: Int) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeBytes { raw in
            for byte in 0..<4 { value |= UInt32(raw[index + byte]) << (8 * byte) }
        }
        return value
    }
}

/// Токенизатор WordPiece, как у BERT multilingual: нормализация, разбивка по
/// пробелам и пунктуации, жадный разбор слова на куски со знаком `##`.
///
/// Разбор должен совпадать с библиотечным до идентификатора — иначе векторы
/// будут чужие; за этим следит тест на эталонных фразах.
struct MemoryTokenizer: Sendable {

    private let ids: [String: Int]
    private let unknown: Int
    private let start: Int
    private let end: Int
    /// Слово длиннее — сразу `[UNK]`, как в библиотеке.
    private static let maxWordLength = 100

    init(tokens: [String]) {
        var ids = [String: Int](minimumCapacity: tokens.count)
        for (index, token) in tokens.enumerated() where ids[token] == nil {
            ids[token] = index
        }
        self.ids = ids
        self.unknown = ids["[UNK]"] ?? 0
        self.start = ids["[CLS]"] ?? 0
        self.end = ids["[SEP]"] ?? 0
    }

    /// Номера токенов фразы вместе с `[CLS]` и `[SEP]` по краям.
    func encode(_ text: String) -> [Int] {
        var result = [start]
        for word in Self.split(text) {
            result.append(contentsOf: pieces(of: word))
        }
        result.append(end)
        return result
    }

    /// Слово → его куски. Жадно берём самый длинный кусок из словаря, продолжения
    /// ищем со знаком `##`. Не разобралось целиком — всё слово `[UNK]`.
    private func pieces(of word: [Character]) -> [Int] {
        guard word.count <= Self.maxWordLength else { return [unknown] }
        var result: [Int] = []
        var start = 0
        while start < word.count {
            var end = word.count
            var found: Int?
            while start < end {
                let piece = String(word[start..<end])
                if let id = ids[start == 0 ? piece : "##" + piece] {
                    found = id
                    break
                }
                end -= 1
            }
            guard let id = found else { return [unknown] }
            result.append(id)
            start = end
        }
        return result
    }

    /// Нормализация и разбивка: как `BertNormalizer` с `lowercase` плюс
    /// `BertPreTokenizer`. Иероглифы стоят каждый сам по себе, пунктуация — тоже.
    static func split(_ text: String) -> [[Character]] {
        var words: [[Character]] = []
        var current: [Character] = []
        func flush() {
            if !current.isEmpty { words.append(current); current = [] }
        }
        for scalarsChar in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            // Диакритика уходит вместе с составными знаками: «ё» → «е», «é» → «e».
            if scalarsChar.properties.generalCategory == .nonspacingMark { continue }
            if isIgnored(scalarsChar) { continue }
            let character = Character(scalarsChar)
            if scalarsChar.properties.isWhitespace || scalarsChar == " " {
                flush()
            } else if isPunctuation(scalarsChar) || isChinese(scalarsChar) {
                flush()
                words.append([character])
            } else {
                current.append(character)
            }
        }
        flush()
        return words
    }

    /// Управляющие символы и замена — выбрасываются (`clean_text`).
    private static func isIgnored(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0 || scalar.value == 0xFFFD { return true }
        guard scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format else {
            return false
        }
        // Перевод строки и табуляция считаются пробелом, а не мусором.
        return scalar != "\n" && scalar != "\r" && scalar != "\t"
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        // ASCII-знаки вокруг букв и цифр библиотека считает пунктуацией целиком,
        // даже те, что Unicode относит к символам: `+`, `<`, `$`, `^`.
        switch scalar.value {
        case 33...47, 58...64, 91...96, 123...126: return true
        default: break
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func isChinese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F,
             0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0xF900...0xFAFF, 0x2F800...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
