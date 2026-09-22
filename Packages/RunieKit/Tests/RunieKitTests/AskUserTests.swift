import Foundation
import Testing
@testable import RunieKit

@Suite("Вопрос человеку")
struct AskUserTests {

    @Test("спрашивать разрешение, чтобы задать вопрос, не нужно")
    func alwaysAllowed() {
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__ask_user", input: .object([:])).isEmpty)
        // AskUserQuestion в режиме --print CLI не регистрирует вовсе, но если
        // однажды появится — он тоже не должен упираться в разрешение.
        #expect(PermissionClassifier.categories(toolName: "AskUserQuestion", input: .object([:])).isEmpty)
        let request = PermissionRequest(requestID: "1", toolUseID: nil, toolName: "mcp__runie__ask_user",
                                        input: .object([:]), reason: nil)
        #expect(PermissionPolicy().allows(request))
    }

    @Test("в «руках» виден сам вопрос")
    func description() {
        let description = ToolDescriber.describe(
            name: "mcp__runie__ask_user",
            input: .object(["question": .string("Какой цвет орба вам больше нравится?")])
        )
        #expect(description.title.contains("Спрашивает"))
        #expect(description.detail == "Какой цвет орба вам больше нравится?")
    }
}
