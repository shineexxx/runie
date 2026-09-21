import Foundation
import Testing
@testable import RunieKit

@Suite("Группы разрешений")
struct PermissionClassifierTests {

    private func bash(_ command: String) -> Set<PermissionCategory> {
        PermissionClassifier.categories(toolName: "Bash", input: .object(["command": .string(command)]))
    }

    @Test("инструменты Claude Code раскладываются по группам")
    func tools() {
        #expect(PermissionClassifier.categories(toolName: "Read", input: .object([:])) == [.readFiles])
        #expect(PermissionClassifier.categories(toolName: "Write", input: .object([:])) == [.editFiles])
        #expect(PermissionClassifier.categories(toolName: "WebFetch", input: .object([:])) == [.internet])
        #expect(PermissionClassifier.categories(toolName: "mcp__notion__search", input: .object([:])) == [.services])
        #expect(PermissionClassifier.categories(toolName: "Unknown", input: .object([:])) == [.otherCommands])
    }

    @Test("простые команды", arguments: [
        ("cat ~/todo.txt", PermissionCategory.readFiles),
        ("ls -la ~/Downloads", .browseFolders),
        ("sw_vers", .systemInfo),
        ("mkdir -p ~/Отчёты", .editFiles),
        ("rm ~/old.txt", .moveDelete),
        ("open -a Safari", .openApps),
        ("curl -s https://example.com", .internet),
        ("osascript -e 'tell application \"Music\" to play'", .automation),
        ("brew install ffmpeg", .install),
        ("/bin/ls /tmp", .browseFolders),
        ("defaults read com.apple.dock", .systemInfo),
        ("sed -n 1,5p file.txt", .readFiles),
    ])
    func simple(command: String, expected: PermissionCategory) {
        #expect(bash(command) == [expected])
    }

    @Test("цепочка команд затрагивает все свои группы")
    func pipelines() {
        #expect(bash("ls ~/Downloads | head -n 5") == [.browseFolders, .readFiles])
        #expect(bash("cd ~/Documents && rm -rf old") == [.moveDelete])
        #expect(bash("df -h; sw_vers") == [.systemInfo])
        #expect(bash("cat a.txt 2>&1 | wc -l") == [.readFiles])
    }

    @Test("запись в файл через > — это правка, а в /dev/null — нет")
    func redirects() {
        #expect(bash("echo hi > note.txt") == [.editFiles])
        #expect(bash("cat a >> b") == [.readFiles, .editFiles])
        #expect(bash("ls missing 2>/dev/null") == [.browseFolders])
    }

    @Test("опасное не проходит под видом безопасного")
    func dangerousStaysOther() {
        #expect(bash("cat $(rm -rf ~)").contains(.otherCommands))
        #expect(bash("ls `whoami`") == [.otherCommands])
        #expect(bash("sudo cat /etc/hosts") == [.otherCommands])
        #expect(bash("find . -name '*.log' -delete") == [.moveDelete])
        #expect(bash("find . -exec rm {} +").contains(.otherCommands))
        #expect(bash("sed -i '' s/a/b/ file") == [.editFiles])
        #expect(bash("defaults write com.apple.dock autohide -bool true") == [.otherCommands])
        #expect(bash("env rm file") == [.moveDelete])
        #expect(bash("cat 'unterminated") == [.otherCommands])
        #expect(bash("echo 'a | rm -rf /'") == [])
    }
}

@Suite("Правила разрешений")
struct PermissionPolicyTests {

    private func request(_ tool: String, _ command: String? = nil) -> PermissionRequest {
        PermissionRequest(
            requestID: "r", toolUseID: nil, toolName: tool,
            input: .object(command.map { ["command": .string($0)] } ?? [:]), reason: nil
        )
    }

    @Test("по умолчанию спрашивать обо всём")
    func defaultsAsk() {
        #expect(!PermissionPolicy().allows(request("Read")))
    }

    @Test("разрешено, только если разрешены все затронутые группы")
    func allRequired() {
        let policy = PermissionPolicy(rules: [.readFiles: .allow, .browseFolders: .allow])
        #expect(policy.allows(request("Bash", "ls ~ | head")))
        #expect(!policy.allows(request("Bash", "ls ~ && rm x")))
        #expect(policy.allows(request("Read")))
    }

    @Test("правила переживают сохранение")
    func codable() throws {
        let policy = PermissionPolicy(rules: [.readFiles: .allow, .moveDelete: .ask])
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(PermissionPolicy.self, from: data) == policy)
    }

    @Test("сессия разрешает по правилам без вопроса")
    @MainActor
    func sessionUsesPolicy() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.policy = PermissionPolicy(rules: [.systemInfo: .allow])
        var asked = 0
        session.onPermissionRequest = { asked += 1 }
        session.send("версия")
        let connection = try #require(backend.connections.first)
        connection.continuation.yield(.event(.permissionRequested(request("Bash", "sw_vers"))))

        let deadline = ContinuousClock.now + .seconds(5)
        while connection.responses.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.responses.first?.1 == .allow)
        #expect(asked == 0)
        #expect(session.pendingPermission == nil)
    }
}

@Suite("Инструменты Runie")
struct RunieToolDescriptionTests {

    @Test("свои инструменты — по-русски и в своих группах разрешений")
    func describedAndClassified() {
        let paths: JSONValue = .object(["paths": .array([.string("/a/1.png"), .string("/a/2.png")]), "via": .string("mail")])
        #expect(ToolDescriber.describe(name: "mcp__runie__compress_images", input: paths).title == t("Сжимает картинки (\(2))"))
        #expect(ToolDescriber.describe(name: "mcp__runie__share_files", input: paths).title == t("Готовит отправку через \(t("Почту"))"))
        #expect(ToolDescriber.describe(name: "mcp__runie__find_files", input: .object(["query": .string("отчёт")])).title == t("Ищет «\("отчёт")»"))
        #expect(ToolDescriber.describe(name: "mcp__runie__compress_images", input: paths).detail == "1.png, 2.png")

        #expect(PermissionClassifier.categories(toolName: "mcp__runie__find_files", input: paths) == [.browseFolders])
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__zip_files", input: paths) == [.editFiles])
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__share_files", input: paths) == [.sharing])
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__find_contact", input: paths) == [.contacts])
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__unknown", input: paths) == [.otherCommands])
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__calendar_events", input: paths) == [.calendarRead])
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__create_reminder", input: paths) == [.calendarEdit])
        #expect(!PermissionCategory.calendarRead.isRisky)
        #expect(PermissionCategory.calendarEdit.isRisky)
        #expect(ToolDescriber.describe(name: "mcp__runie__calendar_events", input: .object(["range": .string("week")])).title
                == t("Смотрит встречи \(t("на неделю"))"))
        #expect(PermissionClassifier.categories(toolName: "mcp__notion__search", input: paths) == [.services])
    }
}
