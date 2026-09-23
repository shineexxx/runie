import Foundation
import Testing
@testable import RunieKit

@Suite("Готовые наборы разрешений")
struct PermissionPresetTests {

    private func request(_ tool: String, _ input: JSONValue = .object([:])) -> PermissionRequest {
        PermissionRequest(requestID: UUID().uuidString, toolUseID: nil, toolName: tool, input: input, reason: nil)
    }

    private func shell(_ command: String) -> PermissionRequest {
        request("Bash", .object(["command": .string(command)]))
    }

    @Test("«спрашивать обо всём» не разрешает ничего заранее")
    func strict() {
        let policy = PermissionPolicy.strict
        for category in PermissionCategory.allCases {
            #expect(policy.rule(for: category) == .ask, "\(category.rawValue)")
        }
        // Даже память, которая обычно разрешена сама по себе.
        #expect(policy.rule(for: .memory) == .ask)
    }

    @Test("«безопасное» разрешает только то, что ничего не меняет")
    func safe() {
        let policy = PermissionPolicy.safe
        #expect(policy.allows(shell("cat todo.txt")))
        #expect(policy.allows(request("mcp__runie__calendar_events")))
        #expect(!policy.allows(shell("rm старое.txt")))
        #expect(!policy.allows(request("Write", .object(["file_path": .string("/tmp/a")]))))
        #expect(!policy.allows(request("WebFetch")))
    }

    @Test("«почти всё» разрешает работу, но не удаление и установку")
    func permissive() {
        let policy = PermissionPolicy.permissive
        // Ради этого режим и нужен: обычная работа идёт без вопросов.
        #expect(policy.allows(request("Write", .object(["file_path": .string("/tmp/a")]))))
        #expect(policy.allows(request("WebFetch")))
        #expect(policy.allows(request("mcp__runie__share_files")))
        #expect(policy.allows(request("mcp__runie__browser_run_js")))
        #expect(policy.allows(request("mcp__runie__create_event")))
        #expect(policy.allows(shell("git status")))
        #expect(policy.allows(shell("osascript -e beep")))

        // А вот это по-прежнему через вопрос.
        #expect(!policy.allows(shell("rm -rf ~/Загрузки/старое")))
        #expect(!policy.allows(shell("mv отчёт.pdf /tmp")))
        #expect(!policy.allows(shell("brew install jq")))
        #expect(policy.rule(for: .moveDelete) == .ask)
        #expect(policy.rule(for: .install) == .ask)
    }

    @Test("разрешённый сайт больше не спрашивает, остальные — спрашивают")
    func signedInSites() {
        let diary = request("mcp__runie__web_open",
                            .object(["url": .string("https://lk.skolca.ru/homework"), "sign_in": .bool(true)]))
        let bank = request("mcp__runie__web_open",
                           .object(["url": .string("https://bank.example"), "sign_in": .bool(true)]))
        var policy = PermissionPolicy.permissive
        #expect(!policy.allows(diary))

        policy.signedInSites.insert("lk.skolca.ru")
        #expect(policy.allows(diary))
        // Разрешив дневник, человек не разрешил банк.
        #expect(!policy.allows(bank))

        // В строгом режиме сам заход в браузер всё равно через вопрос.
        var strict = PermissionPolicy.strict
        strict.signedInSites.insert("lk.skolca.ru")
        #expect(!strict.allows(diary))
    }

    @Test("старые настройки читаются: про сайты там ничего нет")
    func oldSettings() throws {
        // Так выглядели сохранённые разрешения до появления списка сайтов:
        // словарь с ключом-перечислением Swift записывает парами в массив.
        let old = Data("""
            {"rules":["readFiles","allow"]}
            """.utf8)
        let policy = try JSONDecoder().decode(PermissionPolicy.self, from: old)
        #expect(policy.rule(for: .readFiles) == .allow)
        #expect(policy.signedInSites.isEmpty)
        // И записывается обратно вместе с сайтами.
        var updated = policy
        updated.signedInSites.insert("lk.skolca.ru")
        let restored = try JSONDecoder().decode(PermissionPolicy.self, from: JSONEncoder().encode(updated))
        #expect(restored.signedInSites == ["lk.skolca.ru"])
    }

    @Test("заранее не разрешается только необратимое и вход под учётной записью")
    func alwaysAsks() {
        let asking = PermissionCategory.allCases.filter(\.alwaysAsks)
        #expect(Set(asking) == [.moveDelete, .install, .signInAsYou])
        // Куки дают сайту думать, что за экраном сам человек, — это всегда с его ведома.
        #expect(!PermissionPolicy.permissive.allows(
            request("mcp__runie__web_open", .object(["url": .string("https://dnevnik.ru"), "sign_in": .bool(true)]))
        ))
        // А просто сходить на сайт своим браузером в этом режиме можно.
        #expect(PermissionPolicy.permissive.allows(
            request("mcp__runie__web_open", .object(["url": .string("https://dnevnik.ru")]))
        ))
        // Команда из двух групп: удаление тянет за собой вопрос целиком.
        #expect(!PermissionPolicy.permissive.allows(shell("find . -name '*.tmp' -delete")))
    }
}
