import Foundation
import Testing
@testable import RunieKit

/// Тесты гоняют рантайм на поддельном исполняемом файле вместо настоящего Claude Code:
/// проверяется пломбировка процесса и разбор потока, а не поведение агента. Ни сети,
/// ни расхода подписки.
@Suite("AgentRuntime")
struct AgentRuntimeTests {

    // MARK: - Поддельный агент

    private func makeScript(_ body: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runie-fake-agent-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func runtime(script: URL, arguments: [String] = []) -> AgentRuntime {
        AgentRuntime(configuration: .init(executable: script, arguments: arguments))
    }

    /// Собирает поток целиком, с общим потолком по времени.
    private func drain(
        _ stream: AsyncStream<RuntimeOutput>,
        timeout: Duration = .seconds(20)
    ) async throws -> [RuntimeOutput] {
        try await withThrowingTaskGroup(of: [RuntimeOutput].self) { group in
            group.addTask {
                var collected: [RuntimeOutput] = []
                for await output in stream { collected.append(output) }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func events(_ outputs: [RuntimeOutput]) -> [RawAgentEvent] {
        outputs.compactMap { if case .event(let event) = $0 { event } else { nil } }
    }

    // MARK: - Тесты

    @Test("события разбираются и приходят в порядке выдачи")
    func parsesEventsInOrder() async throws {
        let script = try makeScript(#"""
        printf '{"type":"system","subtype":"init","session_id":"s1"}\n'
        printf '{"type":"assistant","session_id":"s1"}\n'
        printf '{"type":"result","subtype":"success","session_id":"s1"}\n'
        """#)
        defer { try? FileManager.default.removeItem(at: script) }

        let runtime = runtime(script: script)
        let outputs = try await drain(try runtime.start())
        let events = events(outputs)

        #expect(events.map(\.type) == ["system", "assistant", "result"])
        #expect(events[0].subtype == "init")
        #expect(events[2].subtype == "success")
        #expect(events.allSatisfy { $0.sessionID == "s1" })
    }

    @Test("финальное событие не теряется, даже если пришло перед самым выходом")
    func doesNotLoseFinalEvent() async throws {
        // terminationHandler часто опережает пайп. Если рантайм не дочитывает хвост,
        // result исчезает — а это единственный признак завершения хода.
        let script = try makeScript(#"""
        printf '{"type":"assistant"}\n{"type":"result","subtype":"success"}\n'
        exit 0
        """#)
        defer { try? FileManager.default.removeItem(at: script) }

        let outputs = try await drain(try runtime(script: script).start())
        #expect(events(outputs).map(\.type) == ["assistant", "result"])
    }

    @Test("последняя строка без перевода строки всё равно доходит")
    func handlesUnterminatedFinalLine() async throws {
        let script = try makeScript(#"printf '{"type":"result","subtype":"success"}'"#)
        defer { try? FileManager.default.removeItem(at: script) }

        let outputs = try await drain(try runtime(script: script).start())
        #expect(events(outputs).map(\.type) == ["result"])
    }

    @Test("мусор в stdout не роняет чтение потока")
    func malformedLineDoesNotStopStream() async throws {
        let script = try makeScript(#"""
        printf 'это не json\n'
        printf '{"type":"assistant"}\n'
        printf '[1,2,3]\n'
        printf '{"type":"result"}\n'
        """#)
        defer { try? FileManager.default.removeItem(at: script) }

        let outputs = try await drain(try runtime(script: script).start())
        let malformed = outputs.compactMap {
            if case .malformedLine(let line) = $0 { line } else { nil }
        }
        // Массив верхнего уровня — валидный JSON, но не событие, поэтому тоже мусор.
        #expect(malformed == ["это не json", "[1,2,3]"])
        #expect(events(outputs).map(\.type) == ["assistant", "result"])
    }

    @Test("stderr идёт отдельным каналом и не смешивается с событиями")
    func stderrIsSeparate() async throws {
        let script = try makeScript(#"""
        printf 'предупреждение\n' >&2
        printf '{"type":"result"}\n'
        """#)
        defer { try? FileManager.default.removeItem(at: script) }

        let outputs = try await drain(try runtime(script: script).start())
        let diagnostics = outputs.compactMap {
            if case .diagnostic(let line) = $0 { line } else { nil }
        }
        #expect(diagnostics.contains("предупреждение"))
        #expect(events(outputs).map(\.type) == ["result"])
    }

    @Test("сообщение доезжает до stdin и процесс отвечает")
    func sendsMessageToStdin() async throws {
        // Поддельный агент эхом возвращает то, что прочитал, обёрнутое в событие.
        let script = try makeScript(#"""
        while IFS= read -r line; do
          printf '{"type":"assistant","echo":%s}\n' "$line"
        done
        printf '{"type":"result","subtype":"success"}\n'
        """#)
        defer { try? FileManager.default.removeItem(at: script) }

        let runtime = runtime(script: script)
        let stream = try runtime.start()
        try runtime.send(UserMessage("привет"))
        try runtime.send(UserMessage("второй ход"))
        runtime.finishInput()

        let events = events(try await drain(stream))
        let echoed = events.compactMap {
            $0.payload.path("echo", "message", "content", 0, "text")?.stringValue
        }
        #expect(echoed == ["привет", "второй ход"])
        #expect(events.last?.type == "result")
    }

    @Test("остановка убивает процесс и закрывает поток")
    func stopTerminatesProcess() async throws {
        let script = try makeScript(#"""
        printf '{"type":"system","subtype":"init"}\n'
        sleep 60
        """#)
        defer { try? FileManager.default.removeItem(at: script) }

        let runtime = runtime(script: script)
        let stream = try runtime.start()

        let collector = Task { try await drain(stream, timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(runtime.isRunning)
        runtime.stop()

        let outputs = try await collector.value
        #expect(runtime.isRunning == false)
        let terminations = outputs.compactMap {
            if case .terminated(_, let reason) = $0 { reason } else { nil }
        }
        #expect(terminations == [.stopped])
    }

    @Test("ненулевой код возврата доходит как обычное завершение")
    func reportsExitCode() async throws {
        let script = try makeScript("exit 7")
        defer { try? FileManager.default.removeItem(at: script) }

        let outputs = try await drain(try runtime(script: script).start())
        let terminations = outputs.compactMap {
            if case .terminated(let code, let reason) = $0 { (code, reason) } else { nil }
        }
        #expect(terminations.count == 1)
        #expect(terminations.first?.0 == 7)
        #expect(terminations.first?.1 == .exited)
    }

    @Test("несуществующий исполняемый файл даёт понятную ошибку, а не падение")
    func failsToLaunchMissingExecutable() {
        let runtime = AgentRuntime(configuration: .init(
            executable: URL(fileURLWithPath: "/nonexistent/claude"),
            arguments: []
        ))
        #expect(throws: AgentRuntime.Failure.self) { _ = try runtime.start() }
        #expect(runtime.isRunning == false)
    }

    @Test("отправка в незапущенный рантайм не проходит")
    func sendBeforeStartFails() throws {
        let runtime = AgentRuntime(configuration: .init(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        ))
        #expect(throws: AgentRuntime.Failure.self) { try runtime.send(UserMessage("привет")) }
    }

    @Test("повторный запуск того же рантайма запрещён")
    func doubleStartFails() async throws {
        let script = try makeScript("sleep 5")
        defer { try? FileManager.default.removeItem(at: script) }

        let runtime = runtime(script: script)
        _ = try runtime.start()
        defer { runtime.stop() }
        #expect(throws: AgentRuntime.Failure.self) { _ = try runtime.start() }
    }

    @Test("запись в умерший процесс даёт ошибку, а не убивает приложение")
    func writeToDeadProcessDoesNotCrash() async throws {
        // Без глушения SIGPIPE этот тест снёс бы весь тестовый процесс.
        let script = try makeScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let runtime = runtime(script: script)
        let stream = try runtime.start()
        _ = try await drain(stream)

        #expect(throws: AgentRuntime.Failure.self) { try runtime.send(UserMessage("привет")) }
    }

    @Test("поток живёт, даже если на рантайм не осталось ссылок")
    func streamSurvivesWithoutCallerReference() async throws {
        // Пока процесс жив, рантайм обязан держать сам себя. Иначе временный объект
        // умирает сразу после start(), слабые захваты обнуляются, и поток молча
        // не закрывается никогда — самая неприятная разновидность зависания.
        let script = try makeScript(#"printf '{"type":"result","subtype":"success"}\n'"#)
        defer { try? FileManager.default.removeItem(at: script) }

        let stream = try AgentRuntime(
            configuration: .init(executable: script, arguments: [])
        ).start()

        let outputs = try await drain(stream, timeout: .seconds(10))
        #expect(events(outputs).map(\.type) == ["result"])
        #expect(outputs.contains { if case .terminated = $0 { true } else { false } })
    }

    @Test("крупное событие собирается целиком")
    func handlesLargeEvent() async throws {
        // system/init со списком инструментов легко переваливает за размер куска пайпа.
        let script = try makeScript(#"""
        big=$(head -c 200000 /dev/zero | tr '\0' 'x')
        printf '{"type":"system","subtype":"init","blob":"%s"}\n' "$big"
        """#)
        defer { try? FileManager.default.removeItem(at: script) }

        let outputs = try await drain(try runtime(script: script).start())
        let events = events(outputs)
        #expect(events.count == 1)
        #expect(events.first?.payload["blob"]?.stringValue?.count == 200_000)
    }
}
