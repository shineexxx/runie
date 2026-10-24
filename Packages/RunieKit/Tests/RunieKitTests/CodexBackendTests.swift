import Foundation
import Testing
@testable import RunieKit

@MainActor
@Suite("Codex")
struct CodexBackendTests {

    /// Подставной `codex app-server` из фикстур — исполняемый файл во временной папке.
    private func fakeCodex() throws -> URL {
        let source = try #require(Bundle.module.url(forResource: "fake-codex", withExtension: "py", subdirectory: "Fixtures"))
        let target = FileManager.default.temporaryDirectory.appending(path: "fake-codex-\(UUID().uuidString).py")
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("ход Codex: разговор, команда с разрешением, ответ кусками, контекст")
    func turnThroughChatSession() async throws {
        let session = ChatSession(backend: CodexBackend(executable: try fakeCodex()))
        session.send("убери временную папку")

        // Удаление — правила по умолчанию спрашивают человека.
        #expect(await eventually { session.pendingPermission != nil })
        let request = try #require(session.pendingPermission)
        #expect(request.toolName == "Bash")
        #expect(request.input["command"]?.stringValue == "rm -rf /tmp/x")

        session.answer(request, allow: true)
        #expect(await eventually { !session.isBusy })
        #expect(session.timeline.sessionID == "01aa0000-0000-7000-8000-000000000001")
        #expect(session.timeline.items.contains { if case .assistant(let reply) = $0 { reply.text == "Готово" } else { false } })
        #expect(session.timeline.context == ContextUsage(used: 5000, window: 200_000))
        #expect(session.timeline.usage?.window("five_hour")?.utilization == 0.12)
    }

    @Test("модели Codex приходят в том же виде, что у Claude Code")
    func modelsFromCodex() async throws {
        let session = ChatSession(backend: CodexBackend(executable: try fakeCodex()))
        session.prepare()
        #expect(await eventually { !session.availableModels.isEmpty })
        #expect(session.availableModels.first?.value == "gpt-test")
        #expect(session.availableModels.first?.displayName == "GPT Test")
    }

    @Test("обёртка оболочки снимается: правила видят саму команду")
    func unwrapsShell() {
        #expect(CodexConnection.unwrapShell("/bin/zsh -lc 'ls -la ~'") == "ls -la ~")
        #expect(CodexConnection.unwrapShell("bash -lc \"echo hi\"") == "echo hi")
        #expect(CodexConnection.unwrapShell("git status") == "git status")
    }
}

/// Настоящий Codex: только знакомство, разговор и модели — без обращения к модели.
/// Запуск: `RUNIE_LIVE_CODEX=1 swift test --filter CodexLive`.
@MainActor
@Suite("CodexLive", .enabled(if: ProcessInfo.processInfo.environment["RUNIE_LIVE_CODEX"] == "1"))
struct CodexLiveTests {
    @Test("настоящий codex app-server: разговор начат, модели получены")
    func handshake() async throws {
        let executable = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin/codex")
        let session = ChatSession(backend: CodexBackend(executable: executable))
        session.prepare()
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, session.availableModels.isEmpty || session.timeline.sessionID == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("thread:", session.timeline.sessionID ?? "nil")
        print("models:", session.availableModels.map(\.value))
        print("limits:", session.timeline.usage?.windows.map { "\($0.kind) \($0.utilization)" } ?? [])
        print("diagnostics:", session.diagnostics.suffix(5))
        #expect(session.timeline.sessionID != nil)
        #expect(!session.availableModels.isEmpty)
        session.stop()
    }
}
