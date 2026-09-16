import Foundation

/// Находит исполняемый файл `claude` на машине пользователя.
///
/// Приложение, запущенное из Finder, не наследует пользовательский `PATH` из шелла:
/// GUI-процессы получают урезанное окружение от launchd. Поэтому полагаться на
/// `which claude` нельзя — надо искать по известным местам установки, а `PATH`
/// использовать только как дополнение, если он вдруг оказался богатым.
public struct ClaudeCodeLocator: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        /// Claude Code не найден ни в одном из известных мест.
        case notFound(searched: [String])
    }

    /// Места, куда Claude Code ставится штатными установщиками, в порядке приоритета.
    /// Пути относительно домашней папки начинаются с `~`.
    public static let wellKnownPaths: [String] = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.bun/bin/claude",
        "~/.volta/bin/claude",
        "/usr/bin/claude"
    ]

    private let homeDirectory: URL
    private let pathVariable: String?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pathVariable: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.homeDirectory = homeDirectory
        self.pathVariable = pathVariable
    }

    /// Все кандидаты в порядке проверки: сначала известные места, затем записи из `PATH`.
    public var candidates: [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        func append(_ url: URL) {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }

        for path in Self.wellKnownPaths {
            append(expand(path))
        }

        for directory in (pathVariable ?? "").split(separator: ":") where !directory.isEmpty {
            append(expand(String(directory)).appendingPathComponent("claude"))
        }

        return result
    }

    /// Возвращает первый найденный исполняемый `claude`.
    public func locate() throws -> URL {
        let candidates = self.candidates
        for candidate in candidates where isExecutable(candidate) {
            return candidate
        }
        throw Failure.notFound(searched: candidates.map(\.path))
    }

    private func isExecutable(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    private func expand(_ path: String) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}
