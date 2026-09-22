import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Запуск AppleScript отдельным процессом.
///
/// Отдельным — потому что чужое приложение может думать долго, а `NSAppleScript`
/// держал бы поток. Для сборщиков это важно: обход идёт в фоне и может длиться
/// минуты.
public enum AppleScriptRunner {

    public enum Failure: Error, Equatable, LocalizedError {
        case notRunning(String)
        case notAuthorized(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning(let app): t("\(app) не запущен — Руни его не открывает сам.")
            case .notAuthorized(let app): t("macOS не разрешила Runie управлять приложением «\(app)». Разрешите: Системные настройки → Конфиденциальность и безопасность → Автоматизация → Runie.")
            case .failed(let reason): reason
            }
        }
    }

    /// Выполняет скрипт и возвращает то, что он напечатал.
    public static func run(_ source: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let result: (code: Int32, out: Data, err: String) = try await withCheckedThrowingContinuation { continuation in
            // Выход читаем до завершения: у большого ответа труба переполняется,
            // и процесс встаёт намертво, не дождавшись, пока его прочитают.
            let collector = Task.detached {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return (data, error)
            }
            process.terminationHandler = { process in
                Task {
                    let (data, error) = await collector.value
                    continuation.resume(returning: (process.terminationStatus, data, error))
                }
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(source.utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: Failure.failed(error.localizedDescription))
            }
        }

        guard result.code == 0 else {
            let error = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            if error.contains("-1743") || error.lowercased().contains("not authorized") {
                throw Failure.notAuthorized(Self.appName(in: error) ?? "")
            }
            throw Failure.failed(error)
        }
        return String(decoding: result.out, as: UTF8.self)
    }

    /// Запущено ли приложение. Руни не открывает чужие программы сам: человек
    /// не просил, а Почта или Заметки на весь экран — заметная неожиданность.
    public static func isRunning(bundleID: String) -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
        #else
        return false
        #endif
    }

    /// Имя приложения из текста ошибки — для понятного объяснения человеку.
    private static func appName(in error: String) -> String? {
        guard let range = error.range(of: "«(.+?)»", options: .regularExpression) else { return nil }
        return String(error[range].dropFirst().dropLast())
    }

    // MARK: Разбор ответа

    /// Поля внутри записи.
    public static let fieldSeparator = "\u{1}"
    /// Записи между собой.
    public static let recordSeparator = "\u{2}"

    /// Делит ответ скрипта на записи с полями.
    public static func parse(_ output: String) -> [[String]] {
        output
            .components(separatedBy: recordSeparator)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.components(separatedBy: fieldSeparator) }
    }

    /// Дата из `«class isot»`: «2026-09-22T17:55:09» в местном времени.
    public static func date(fromISO text: String) -> Date? {
        isoFormatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()
}
