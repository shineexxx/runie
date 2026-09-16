import Foundation
import RunieKit

// Живая проверка подсказок: печатает запрос и ответ модели.
let executable = try ClaudeCodeLocator().locate()
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
