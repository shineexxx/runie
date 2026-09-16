import Foundation
import RunieKit

/// Ручная проверка рантайма и нормализатора на настоящем Claude Code.
///
/// Тесты гоняются на поддельном исполняемом файле и очищенных фикстурах и не тратят
/// подписку. Эта утилита — наоборот: один живой ход, чтобы увидеть события своими глазами.
///
///     swift run --package-path Packages/RunieKit runie-smoke "скажи ровно: pong"
///
/// Незнакомые события печатаются отдельно: так видно, что CLI добавил новый тип
/// и нормализатор пора учить.

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let text = prompt.isEmpty ? "Ответь ровно одним словом: pong" : prompt

let executable: URL
do {
    executable = try ClaudeCodeLocator().locate()
    print("claude: \(executable.path)\n")
} catch let ClaudeCodeLocator.Failure.notFound(searched) {
    print("Claude Code не найден. Искали в:")
    searched.forEach { print("  \($0)") }
    exit(1)
}

let runtime = AgentRuntime(configuration: .init(
    executable: executable,
    arguments: ClaudeCodeArguments().build(),
    workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
))
let normalizer = AgentEventNormalizer()

let stream = try runtime.start()
try runtime.send(UserMessage(text))
runtime.finishInput()

var unknownTypes: [String] = []

func percent(_ window: SubscriptionUsage.Window?) -> String {
    window.map { String(format: "%.0f%%", $0.utilization * 100) } ?? "—"
}

for await output in stream {
    switch output {
    case .event(let raw):
        for event in normalizer.normalize(raw) {
            switch event {
            case .sessionStarted(let info):
                print("старт      сессия \(info.sessionID), модель \(info.model ?? "?"), инструментов \(info.tools.count)")
            case .assistantText(let text):
                print("текст      \(text.text)")
            case .thinking:
                print("думает")
            case .toolUse(let use):
                print("руки       \(use.name)")
            case .toolResult(let result):
                print("результат  \(result.isError ? "ошибка" : "ок"): \(result.text.prefix(80))")
            case .permissionDenied(let denial):
                print("отказано   \(denial.toolName)")
            case .progress(let detail):
                print("занят      \(detail)")
            case .subscriptionUsage(let usage):
                print("подписка   5 часов: \(percent(usage.window("five_hour"))), 7 дней: \(percent(usage.window("seven_day")))")
            case .turnCompleted(let summary):
                print(String(format: "готово     %d мс, $%.4f",
                             summary.durationMilliseconds ?? 0, summary.costUSD ?? 0))
            case .turnFailed(let failure):
                print("сбой       \(failure.reason): \(failure.message ?? "")")
            case .unknown(let raw):
                let name = raw.subtype.map { "\(raw.type)/\($0)" } ?? raw.type
                unknownTypes.append(name)
                // Полная форма нужна, чтобы научить нормализатор, не гадая по имени.
                // Вывод остаётся в локальном терминале; в фикстуры — только через
                // scripts/sanitize-fixture.py.
                print("незнакомое \(name)\n           \(raw.payload.jsonString().prefix(600))")
            }
        }

    case .malformedLine(let line):
        print("мусор      \(line.prefix(120))")

    case .diagnostic(let line):
        print("stderr     \(line.prefix(120))")

    case .terminated(let code, let reason):
        print("\nзавершён   код \(code), \(reason)")
    }
}

if unknownTypes.isEmpty {
    print("незнакомых событий нет")
} else {
    print("незнакомые события: \(Set(unknownTypes).sorted().joined(separator: ", "))")
}
