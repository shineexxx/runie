import Foundation
import Testing
@testable import RunieKit

@Suite("ChatTimeline")
struct ChatTimelineTests {

    private func replay(_ fixture: String) throws -> ChatTimeline {
        var timeline = ChatTimeline()
        timeline.appendUserMessage("запрос")
        for event in try FixtureLoader.events(fixture) {
            timeline.apply(event)
        }
        return timeline
    }

    private func actions(_ timeline: ChatTimeline) -> [ActionItem] {
        timeline.items.compactMap { if case .action(let action) = $0 { action } else { nil } }
    }

    private func notices(_ timeline: ChatTimeline) -> [NoticeItem] {
        timeline.items.compactMap { if case .notice(let notice) = $0 { notice } else { nil } }
    }

    // MARK: - На живых фикстурах

    @Test("чтение файла: действие завершено, ответ в ленте, агент свободен")
    func toolUseFlow() throws {
        let timeline = try replay("tool-use")

        let action = try #require(actions(timeline).first)
        #expect(action.title == "Читает todo.txt")
        #expect(action.status == .succeeded)
        #expect(action.output?.contains("молоко") == true)

        #expect(timeline.items.contains { if case .assistant = $0 { true } else { false } })
        #expect(timeline.activity == .idle)
        #expect(timeline.sessionID == "11111111-1111-4111-8111-111111111111")
        #expect(timeline.usage?.window("five_hour") != nil)
    }

    @Test("отказ в разрешении не перетирается ошибкой результата")
    func permissionDeniedStaysDenied() throws {
        let timeline = try replay("permission")
        let action = try #require(actions(timeline).first)
        #expect(action.title == "Создаёт hello.txt")
        #expect(action.status == .denied)
        #expect(action.output?.isEmpty == false)
        #expect(timeline.activity == .idle)
    }

    @Test("сбой хода виден в ленте и освобождает агента")
    func failureBecomesNotice() throws {
        let timeline = try replay("resume-missing")
        let notice = try #require(notices(timeline).first)
        #expect(notice.kind == .error)
        #expect(notice.text.contains("No conversation found"))
        #expect(timeline.activity == .idle)
    }

    @Test("в ленте живых фикстур не остаётся зависших действий")
    func noActionLeftRunning() throws {
        for name in FixtureLoader.names {
            let running = actions(try replay(name)).filter { $0.status == .running }
            #expect(running.isEmpty, "\(name): зависли \(running.map(\.title))")
        }
    }

    // MARK: - Правила

    @Test("отправка сообщения переводит агента в ожидание")
    func userMessageStartsWaiting() {
        var timeline = ChatTimeline()
        timeline.appendUserMessage("привет")
        #expect(timeline.activity == .waiting)
        #expect(timeline.isBusy)
        guard case .user(let item) = timeline.items.first else {
            Issue.record("первым должно быть сообщение пользователя")
            return
        }
        #expect(item.text == "привет")
    }

    @Test("куски одного сообщения склеиваются, после рук текст начинается заново")
    func mergesTextOfSameMessage() {
        var timeline = ChatTimeline()
        timeline.apply(.assistantText(AssistantText(text: "Раз.", messageID: "m1", parentToolUseID: nil)))
        timeline.apply(.assistantText(AssistantText(text: "Два.", messageID: "m1", parentToolUseID: nil)))
        timeline.apply(.toolUse(ToolUse(id: "t1", name: "Read", input: .object([:]), parentToolUseID: nil)))
        timeline.apply(.assistantText(AssistantText(text: "Три.", messageID: "m1", parentToolUseID: nil)))

        let texts = timeline.items.compactMap { if case .assistant(let item) = $0 { item.text } else { nil } }
        #expect(texts == ["Раз.\n\nДва.", "Три."])
    }

    @Test("тексты разных сообщений не склеиваются")
    func doesNotMergeDifferentMessages() {
        var timeline = ChatTimeline()
        timeline.apply(.assistantText(AssistantText(text: "A", messageID: "m1", parentToolUseID: nil)))
        timeline.apply(.assistantText(AssistantText(text: "B", messageID: "m2", parentToolUseID: nil)))
        timeline.apply(.assistantText(AssistantText(text: "C", messageID: nil, parentToolUseID: nil)))
        timeline.apply(.assistantText(AssistantText(text: "D", messageID: nil, parentToolUseID: nil)))
        #expect(timeline.items.count == 4)
    }

    @Test("активность следует за агентом")
    func activityFollowsAgent() {
        var timeline = ChatTimeline()
        timeline.appendUserMessage("?")
        timeline.apply(.thinking(parentToolUseID: nil))
        #expect(timeline.activity == .thinking)
        timeline.apply(.toolUse(ToolUse(id: "t1", name: "Bash", input: .object([:]), parentToolUseID: nil)))
        #expect(timeline.activity == .working(nil))
        timeline.apply(.progress("Считаю файлы"))
        #expect(timeline.activity == .working("Считаю файлы"))
        timeline.apply(.assistantText(AssistantText(text: "3", messageID: nil, parentToolUseID: nil)))
        #expect(timeline.activity == .responding)
        timeline.apply(.turnCompleted(TurnSummary(result: "3", durationMilliseconds: 1, costUSD: 0, turnCount: 1, permissionDenialCount: 0)))
        #expect(timeline.activity == .idle)
    }

    @Test("действие без результата к концу хода помечается прерванным")
    func unfinishedActionsBecomeInterrupted() {
        var timeline = ChatTimeline()
        timeline.apply(.toolUse(ToolUse(id: "t1", name: "Bash", input: .object([:]), parentToolUseID: nil)))
        timeline.apply(.turnCompleted(TurnSummary(result: nil, durationMilliseconds: nil, costUSD: nil, turnCount: nil, permissionDenialCount: 0)))
        #expect(actions(timeline).first?.status == .interrupted)
    }

    @Test("действия субагента помечены вложенными")
    func nestedActions() {
        var timeline = ChatTimeline()
        timeline.apply(.toolUse(ToolUse(id: "p", name: "Task", input: .object([:]), parentToolUseID: nil)))
        timeline.apply(.toolUse(ToolUse(id: "c", name: "Read", input: .object([:]), parentToolUseID: "p")))
        #expect(actions(timeline).map(\.isNested) == [false, true])
    }

    @Test("остановка пользователем: пометка «Остановлено», без ошибки")
    func stoppedByUser() {
        var timeline = ChatTimeline()
        timeline.appendUserMessage("долгая задача")
        timeline.apply(.toolUse(ToolUse(id: "t1", name: "Bash", input: .object([:]), parentToolUseID: nil)))
        timeline.markConnectionEnded(exitCode: 15, stoppedByUser: true)

        #expect(notices(timeline).map(\.kind) == [.info])
        #expect(actions(timeline).first?.status == .interrupted)
        #expect(timeline.activity == .idle)
    }

    @Test("неожиданная смерть процесса посреди работы — ошибка в ленте")
    func unexpectedExitWhileBusy() {
        var timeline = ChatTimeline()
        timeline.appendUserMessage("?")
        timeline.markConnectionEnded(exitCode: 1, stoppedByUser: false)
        #expect(notices(timeline).map(\.kind) == [.error])
        #expect(timeline.activity == .idle)
    }

    @Test("тихий нормальный выход между ходами ничего не добавляет в ленту")
    func quietExitWhenIdle() {
        var timeline = ChatTimeline()
        timeline.markConnectionEnded(exitCode: 0, stoppedByUser: false)
        #expect(timeline.items.isEmpty)
    }
}

@Suite("ToolDescriber")
struct ToolDescriberTests {

    private func describe(_ name: String, _ json: String = "{}") throws -> ToolDescriber.Description {
        ToolDescriber.describe(name: name, input: try JSONValue.decode(Data(json.utf8)))
    }

    @Test("файловые операции называют файл, а не путь")
    func fileOperations() throws {
        #expect(try describe("Read", #"{"file_path":"/tmp/a/todo.txt"}"#).title == "Читает todo.txt")
        #expect(try describe("Write", #"{"file_path":"/tmp/hello.txt"}"#).title == "Создаёт hello.txt")
        #expect(try describe("Edit", #"{"file_path":"/tmp/notes.md"}"#).title == "Правит notes.md")
        #expect(try describe("Read", #"{"file_path":"/tmp/a/todo.txt"}"#).detail == "/tmp/a/todo.txt")
    }

    @Test("путь в домашней папке сокращается до тильды")
    func abbreviatesHome() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let described = try describe("Read", #"{"file_path":"\#(home)/Desktop/x.png"}"#)
        #expect(described.detail == "~/Desktop/x.png")
    }

    @Test("без пути — осмысленная замена, а не пустая строка")
    func fileOperationWithoutPath() throws {
        #expect(try describe("Read").title == "Читает файл")
    }

    @Test("команда: описание от агента в заголовке, первая строка команды в подробностях")
    func bash() throws {
        let described = try describe("Bash", #"{"command":"find . -name '*.png'\necho done","description":"Ищет скриншоты"}"#)
        #expect(described.title == "Ищет скриншоты")
        #expect(described.detail == "find . -name '*.png'")
        #expect(try describe("Bash", #"{"command":"ls"}"#).title == "Выполняет команду")
    }

    @Test("длинная подробность обрезается")
    func clipsLongDetail() throws {
        let long = String(repeating: "x", count: 500)
        let detail = try #require(try describe("Bash", #"{"command":"\#(long)"}"#).detail)
        #expect(detail.count == 160)
        #expect(detail.hasSuffix("…"))
    }

    @Test("веб: хост в заголовке")
    func web() throws {
        #expect(try describe("WebFetch", #"{"url":"https://www.dottie.ai/pricing"}"#).title == "Открывает www.dottie.ai")
        #expect(try describe("WebSearch", #"{"query":"погода"}"#).detail == "погода")
    }

    @Test("MCP-инструменты читаются как «сервер: действие»")
    func mcp() throws {
        #expect(try describe("mcp__calendar__list_events").title == "calendar: list events")
        #expect(try describe("mcp__runie_files__compress_images").title == "runie files: compress images")
    }

    @Test("незнакомый инструмент показывается как есть")
    func unknownTool() throws {
        #expect(try describe("SomethingNew").title == "SomethingNew")
    }
}
