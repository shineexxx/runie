import Foundation
import Observation

/// Скачивает модель смыслового поиска — по желанию человека, не сама.
///
/// Файлы лежат в релизах Runie на GitHub отдельным тегом: они меняются гораздо
/// реже приложения, и обновление Runie не тащит за собой 54 МБ.
@MainActor
@Observable
public final class MemoryModelInstaller {

    public static let shared = MemoryModelInstaller()

    public enum State: Equatable, Sendable {
        case absent
        /// Доля скачанного, от 0 до 1.
        case downloading(Double)
        case ready
        case failed(String)
    }

    public private(set) var state: State
    /// Загруженная модель. `nil`, пока файлов нет.
    public private(set) var model: MemoryModel?

    /// Сколько всего весят файлы — чтобы показать человеку до начала.
    public static let downloadSize = 55_000_000

    private static let base = URL(string: "https://github.com/shineexxx/runie/releases/download/model-1")!
    private let directory: URL
    private var task: Task<Void, Never>?

    public init(directory: URL = MemoryModel.standardDirectory) {
        self.directory = directory
        if MemoryModel.isInstalled(in: directory), let model = try? MemoryModel(directory: directory) {
            self.model = model
            self.state = .ready
        } else {
            self.state = .absent
        }
    }

    public var isBusy: Bool {
        if case .downloading = state { return true }
        return false
    }

    /// Качает оба файла и открывает модель. Повторный вызов во время загрузки
    /// ничего не делает.
    public func install() {
        guard !isBusy, model == nil else { return }
        state = .downloading(0)
        task = Task { [directory] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Матрица — почти весь вес, словарь идёт довеском.
                try await download("matrix.bin", to: MemoryModel.matrixURL(in: directory), weight: 0.98, from: 0)
                try await download("vocab.txt", to: MemoryModel.vocabURL(in: directory), weight: 0.02, from: 0.98)
                let model = try MemoryModel(directory: directory)
                self.model = model
                state = .ready
            } catch is CancellationError {
                state = .absent
            } catch {
                // Недокачанное не оставляем: иначе при следующем запуске модель
                // будет «на месте», но испорчена.
                try? FileManager.default.removeItem(at: directory)
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        try? FileManager.default.removeItem(at: directory)
        state = .absent
    }

    /// Удаляет скачанные файлы: память продолжит работать, но искать будет по словам.
    public func remove() {
        cancel()
        model = nil
        state = .absent
    }

    private func download(_ name: String, to destination: URL, weight: Double, from start: Double) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: Self.base.appendingPathComponent(name))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.badResponse(name, http.statusCode)
        }
        let expected = max(response.expectedContentLength, 1)
        let partial = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                state = .downloading(start + weight * Double(written) / Double(expected))
                try Task.checkCancellation()
            }
        }
        try handle.write(contentsOf: buffer)
        try handle.close()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    public enum Failure: Error, LocalizedError {
        case badResponse(String, Int)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let name, let code): t("Не удалось скачать \(name): ответ \(code)")
            }
        }
    }
}
