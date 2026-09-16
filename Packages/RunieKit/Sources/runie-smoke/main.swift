import Foundation
import RunieKit

/// Ручная проверка рантайма на настоящем Claude Code.
///
/// Тесты гоняются на поддельном исполняемом файле и не тратят подписку. Эта утилита —
/// наоборот: один живой ход, чтобы увидеть реальные события своими глазами.
///
///     swift run --package-path Packages/RunieKit runie-smoke "скажи ровно: pong"

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

let stream = try runtime.start()
try runtime.send(UserMessage(text))
runtime.finishInput()

var eventCounts: [String: Int] = [:]

for await output in stream {
    switch output {
    case .event(let event):
        let key = event.subtype.map { "\(event.type)/\($0)" } ?? event.type
        eventCounts[key, default: 0] += 1

        switch event.type {
        case "system" where event.subtype == "init":
            let tools = event.payload["tools"]?.arrayValue?.count ?? 0
            print("init      сессия \(event.sessionID ?? "?"), инструментов: \(tools)")

        case "assistant":
            let blocks = event.payload.path("message", "content")?.arrayValue ?? []
            for block in blocks {
                if let text = block["text"]?.stringValue {
                    print("текст     \(text)")
                } else if let name = block["name"]?.stringValue {
                    print("инструмент \(name)")
                }
            }

        case "rate_limit_event":
            let info = event.payload["rate_limit_info"]
            let fiveHour = info?.path("unifiedWindows", "five_hour", "utilization")?.doubleValue
            let sevenDay = info?.path("unifiedWindows", "seven_day", "utilization")?.doubleValue
            print(String(
                format: "подписка  5 часов: %.0f%%, 7 дней: %.0f%%",
                (fiveHour ?? 0) * 100,
                (sevenDay ?? 0) * 100
            ))

        case "result":
            let cost = event.payload["total_cost_usd"]?.doubleValue ?? 0
            let duration = event.payload["duration_ms"]?.intValue ?? 0
            print(String(format: "result    %@, %d мс, $%.4f",
                         event.subtype ?? "?", duration, cost))

        default:
            break
        }

    case .malformedLine(let line):
        print("мусор     \(line.prefix(120))")

    case .diagnostic(let line):
        print("stderr    \(line.prefix(120))")

    case .terminated(let code, let reason):
        print("\nзавершён  код \(code), \(reason)")
    }
}

print("\nсобытий по типам:")
for (key, count) in eventCounts.sorted(by: { $0.key < $1.key }) {
    print("  \(key): \(count)")
}
