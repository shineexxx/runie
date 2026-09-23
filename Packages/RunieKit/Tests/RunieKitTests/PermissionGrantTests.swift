import Foundation
import Testing
@testable import RunieKit

@Suite("Кнопка «Всегда»")
struct PermissionGrantTests {

    private func request(_ tool: String, _ input: JSONValue) -> PermissionRequest {
        PermissionRequest(requestID: UUID().uuidString, toolUseID: nil, toolName: tool, input: input, reason: nil)
    }

    @Test("вход на сайт запоминается для этого сайта, а не для всех")
    func signIn() {
        let diary = request("mcp__runie__web_open",
                            .object(["url": .string("https://lk.skolca.ru/homework"), "sign_in": .bool(true)]))
        let bank = request("mcp__runie__web_open",
                           .object(["url": .string("https://bank.example/accounts"), "sign_in": .bool(true)]))
        #expect(PermissionGrant.key(for: diary) != PermissionGrant.key(for: bank))
        // Другая страница того же сайта — то же разрешение.
        let sameSite = request("mcp__runie__web_open",
                               .object(["url": .string("https://lk.skolca.ru/marks"), "sign_in": .bool(true)]))
        #expect(PermissionGrant.key(for: diary) == PermissionGrant.key(for: sameSite))
        // Адрес без схемы — тот же сайт.
        let noScheme = request("mcp__runie__web_open",
                               .object(["url": .string("lk.skolca.ru"), "sign_in": .bool(true)]))
        #expect(PermissionGrant.key(for: diary) == PermissionGrant.key(for: noScheme))
    }

    @Test("просто зайти и зайти под учётной записью — разные разрешения")
    func signInIsSeparate() {
        let look = request("mcp__runie__web_open", .object(["url": .string("https://lk.skolca.ru")]))
        let enter = request("mcp__runie__web_open",
                            .object(["url": .string("https://lk.skolca.ru"), "sign_in": .bool(true)]))
        #expect(PermissionGrant.key(for: look) != PermissionGrant.key(for: enter))
    }

    @Test("команды оболочки запоминаются целиком, прочее — по имени")
    func others() {
        let one = request("Bash", .object(["command": .string("git status")]))
        let two = request("Bash", .object(["command": .string("rm -rf /")]))
        #expect(PermissionGrant.key(for: one) != PermissionGrant.key(for: two))
        #expect(PermissionGrant.key(for: request("mcp__runie__web_read", .object([:]))) == "mcp__runie__web_read")
    }
}
