import Foundation
import RunieKit

// Живая проверка подсказок: печатает запрос и ответ модели.
// `runie-suggest digest "claude.ai Slack"` — сводка из одного MCP-сервера.
let executable = try ClaudeCodeLocator().locate()
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "digest" {
    let server = CommandLine.arguments[2]
    let query = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : (MCPSourcePresets.query(forServer: server) ?? "что нового")
    let backend = ClaudeCodeBackend(
        executable: executable,
        workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
        arguments: ClaudeCodeArguments(additionalArguments: MCPDigest.arguments())
    )
    let started = Date()
    let summary = await MCPDigest(backend: backend).collect(server: server, query: query) { print("  \($0)") }
    print("за \(Int(Date().timeIntervalSince(started))) с, запрос: \(query)")
    print(summary ?? "— ничего")
    exit(0)
}
let context = SuggestionContext(
    appName: "Claude",
    recentFiles: [.init(name: "Eney-Preview.dmg", folder: "Загрузки", modified: Date().addingTimeInterval(-3600))],
    recentConversations: ["Сколько файлов у меня в папке Загрузки?"]
)
let generator = ClaudeSuggestionGenerator(executable: executable)
let started = Date()
do {
    let set = try await generator.generate(context)
    print("за \(Int(Date().timeIntervalSince(started))) с")
    print("приветствие:", set.greeting ?? "—")
    for s in set.suggestions { print("•", s.label, "→", s.prompt) }
} catch {
    print("ошибка за \(Int(Date().timeIntervalSince(started))) с:", error)
}
