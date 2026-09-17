import Foundation
import JavaScriptCore
import Testing
@testable import RunieKit

@Suite("Скрипты браузера")
struct BrowserScriptTests {

    @Test("кавычки и обратные слэши не ломают строку AppleScript")
    func quoting() {
        #expect(BrowserScript.quoted(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(BrowserScript.jsString(#"он сказал "привет"\n"#) == #""он сказал \"привет\"\\n""#)
        #expect(BrowserScript.jsString(nil) == "null")
    }

    @Test("вредный ввод остаётся строкой, а не кодом")
    func injection() {
        let js = BrowserScript.clickJS(selector: nil, text: "'); alert(1); ('")
        #expect(js.contains(#"null,"'); alert(1); ('")"#))
        let script = BrowserScript.runJavaScript(.chrome, js, window: nil, tab: nil)
        // Внутри AppleScript-строки все кавычки экранированы.
        let body = script.components(separatedBy: "javascript ").last ?? ""
        #expect(body.hasPrefix("\"") && body.hasSuffix("\""))
        #expect(!body.dropFirst().dropLast().contains(#"" "#))
    }

    @Test("нужные цели для Safari и Chrome")
    func targets() {
        #expect(BrowserScript.runJavaScript(.safari, "1", window: nil, tab: nil).contains("in current tab of front window"))
        #expect(BrowserScript.runJavaScript(.chrome, "1", window: 2, tab: 3).contains("execute tab 3 of window 2"))
        #expect(BrowserScript.open(.chrome, url: "https://a.b", newTab: true).contains("make new tab with properties {URL:\"https://a.b\"}"))
    }

    @Test("группы разрешений и подписи")
    func describe() {
        let input: JSONValue = .object(["browser": .string("chrome"), "text": .string("Войти")])
        #expect(ToolDescriber.describe(name: "mcp__runie__browser_click", input: input).title == "Нажимает «Войти» в Chrome")
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__browser_page_text", input: input) == [.browserRead])
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__browser_fill", input: input) == [.browserControl])
        #expect(!PermissionCategory.browserRead.isRisky)
        #expect(PermissionCategory.browserControl.isRisky)
    }

    @Test("свой код: результат — строка, ошибка — строка")
    func userScript() throws {
        let context = try #require(JSContext())
        func run(_ body: String) -> String? {
            context.evaluateScript(BrowserScript.wrapUserScript(body))?.toString()
        }
        #expect(run("return 1 + 2") == "3")
        #expect(run("return 'привет \"мир\"'") == "привет \"мир\"")
        #expect(run("return {a: [1]}")?.contains("\"a\"") == true)
        #expect(run("// комментарий в конце\nvar x = 1") == "undefined")
        #expect(run("throw new Error('упс')")?.hasPrefix("JS error: ") == true)
        #expect(run("return 'x'.repeat(50)").map { _ in true } == true)
        #expect(context.evaluateScript(BrowserScript.wrapUserScript("return 'abcdef'", limit: 3))?.toString() == "abc")
    }

    @Test("свой код не трогает cookie, хранилища, пароли и сеть")
    func forbidden() {
        #expect(BrowserScript.forbiddenReason(inScript: "return document . cookie") != nil)
        #expect(BrowserScript.forbiddenReason(inScript: "localStorage.getItem('t')") != nil)
        #expect(BrowserScript.forbiddenReason(inScript: "document.querySelector('input[type=password]')") != nil)
        #expect(BrowserScript.forbiddenReason(inScript: "fetch ('https://x')") != nil)
        #expect(BrowserScript.forbiddenReason(inScript: "document.forms[0].submit()") != nil)
        #expect(BrowserScript.forbiddenReason(inScript: "return [...document.links].map(a => a.href)") == nil)
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__browser_run_js", input: .object([:])) == [.pageScript])
        #expect(PermissionCategory.pageScript.isRisky)
        let code = "return document.title"
        let described = ToolDescriber.describe(name: "mcp__runie__browser_run_js", input: .object(["code": .string(code)]))
        #expect(described.title == "Выполняет JavaScript на странице в Safari")
        #expect(described.detail == code)
    }
}
