import Foundation
import Testing
@testable import RunieKit

@Suite("AgentEventNormalizer")
struct AgentEventNormalizerTests {

    private let normalizer = AgentEventNormalizer()

    // MARK: - Вспомогательное

    private func raw(_ json: String) throws -> RawAgentEvent {
        RawAgentEvent(payload: try JSONValue.decode(Data(json.utf8)))
    }

    // MARK: - Фикстуры с настоящего CLI

    @Test("вызов разрешённого инструмента: старт, руки, результат, текст, итог")
    func toolUseFixture() throws {
        let events = try FixtureLoader.events("tool-use")

        let session = try #require(events.compactMap {
            if case .sessionStarted(let info) = $0 { info } else { nil }
        }.first)
        #expect(session.sessionID == "11111111-1111-4111-8111-111111111111")
        #expect(session.tools.contains("Read"))

        let toolUse = try #require(events.compactMap {
            if case .toolUse(let use) = $0 { use } else { nil }
        }.first)
        #expect(toolUse.name == "Read")
        #expect(toolUse.input["file_path"]?.stringValue?.hasSuffix("todo.txt") == true)

        let result = try #require(events.compactMap {
            if case .toolResult(let result) = $0 { result } else { nil }
        }.first)
        #expect(result.toolUseID == toolUse.id)
        #expect(result.isError == false)
        #expect(result.text.contains("молоко"))

        #expect(events.contains { if case .assistantText = $0 { true } else { false } })
        #expect(events.contains { if case .subscriptionUsage = $0 { true } else { false } })

        guard case .turnCompleted(let summary) = events.last else {
            Issue.record("ход должен заканчиваться turnCompleted, а пришло \(String(describing: events.last))")
            return
        }
        #expect((summary.costUSD ?? 0) > 0)
        #expect(summary.permissionDenialCount == 0)
    }

    @Test("отказ в разрешении связывает вызов, отказ и результат одним идентификатором")
    func permissionDeniedFixture() throws {
        let events = try FixtureLoader.events("permission")

        let toolUse = try #require(events.compactMap {
            if case .toolUse(let use) = $0 { use } else { nil }
        }.first)
        #expect(toolUse.name == "Write")

        let denial = try #require(events.compactMap {
            if case .permissionDenied(let denial) = $0 { denial } else { nil }
        }.first)
        #expect(denial.toolUseID == toolUse.id)
        #expect(denial.toolName == "Write")
        #expect(!denial.message.isEmpty)

        let result = try #require(events.compactMap {
            if case .toolResult(let result) = $0 { result } else { nil }
        }.first)
        #expect(result.toolUseID == toolUse.id)
        #expect(result.isError)

        // Порядок важен для интерфейса: сначала руки потянулись, потом отказ.
        let useIndex = try #require(events.firstIndex { if case .toolUse = $0 { true } else { false } })
        let denialIndex = try #require(events.firstIndex { if case .permissionDenied = $0 { true } else { false } })
        #expect(useIndex < denialIndex)

        #expect(events.contains { if case .thinking = $0 { true } else { false } })

        guard case .turnCompleted(let summary) = events.last else {
            Issue.record("ход должен заканчиваться turnCompleted")
            return
        }
        #expect(summary.permissionDenialCount == 1)
    }

    @Test("несуществующая сессия даёт turnFailed с причиной из события")
    func resumeMissingFixture() throws {
        let events = try FixtureLoader.events("resume-missing")
        guard case .turnFailed(let failure) = events.first, events.count == 1 else {
            Issue.record("ожидался ровно один turnFailed, пришло \(events)")
            return
        }
        #expect(failure.reason == "error_during_execution")
        #expect(failure.message?.contains("No conversation found") == true)
    }

    @Test("чтение через Bash проходит без запроса разрешения и без отказа")
    func bashReadOnlyFixture() throws {
        // Снято в режиме manual без инструмента разрешений. CLI сам классифицирует
        // команду как безопасную для чтения и не спрашивает. Граница «что безопасно»
        // проведена внутри CLI, а не в Runie — это важно для шага 5.
        let events = try FixtureLoader.events("bash-readonly")

        let toolUse = try #require(events.compactMap {
            if case .toolUse(let use) = $0 { use } else { nil }
        }.first)
        #expect(toolUse.name == "Bash")
        #expect(toolUse.input["command"]?.stringValue?.isEmpty == false)

        let result = try #require(events.compactMap {
            if case .toolResult(let result) = $0 { result } else { nil }
        }.first)
        #expect(result.toolUseID == toolUse.id)
        #expect(result.isError == false)

        #expect(!events.contains { if case .permissionDenied = $0 { true } else { false } })
        #expect(events.contains { if case .progress = $0 { true } else { false } })
    }

    @Test("размышление приходит отдельным событием перед текстом")
    func thinkingFixture() throws {
        let events = try FixtureLoader.events("thinking")
        let thinkingIndex = try #require(events.firstIndex {
            if case .thinking = $0 { true } else { false }
        })
        let textIndex = try #require(events.firstIndex {
            if case .assistantText = $0 { true } else { false }
        })
        #expect(thinkingIndex < textIndex)

        guard case .assistantText(let text) = events[textIndex] else { return }
        #expect(text.text.contains("18"))
    }

    @Test("потоковый вывод: куски текста в сумме дают ровно полный текст")
    func partialFixtureDeltasMatchFullText() throws {
        let events = try FixtureLoader.events("partial")

        let started = events.compactMap {
            if case .messageStarted(let id, _) = $0 { id } else { nil }
        }
        #expect(started.count == 2)

        let deltas = events.compactMap { if case .textDelta(let delta) = $0 { delta.text } else { nil } }
        #expect(deltas.count > 1, "текст должен прийти несколькими кусками")

        let full = try #require(events.compactMap {
            if case .assistantText(let text) = $0 { text } else { nil }
        }.first)
        #expect(deltas.joined() == full.text)
        // Полное событие относится к последнему начатому сообщению.
        #expect(full.messageID == started.last)
    }

    @Test("кусок аргументов инструмента не превращается в событие")
    func ignoresInputJSONDelta() throws {
        let event = try raw(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"file"}}}"#)
        #expect(normalizer.normalize(event).isEmpty)
    }

    @Test("незнакомое потоковое событие приходит как unknown")
    func unknownStreamEvent() throws {
        let event = try raw(#"{"type":"stream_event","event":{"type":"brand_new_stream_thing"}}"#)
        #expect(normalizer.normalize(event) == [.unknown(event)])
    }

    @Test("в фикстурах нет событий, которые нормализатор не знает")
    func fixturesHaveNoUnknownEvents() throws {
        // Если CLI добавил новый тип и фикстуры пересняты, этот тест покажет, что
        // именно появилось, а не даст ему тихо проваливаться в unknown.
        for name in FixtureLoader.names {
            let unknown = try FixtureLoader.events(name).compactMap {
                if case .unknown(let raw) = $0 { raw.subtype.map { "\(raw.type)/\($0)" } ?? raw.type } else { nil }
            }
            #expect(unknown.isEmpty, "\(name): незнакомые события \(unknown)")
        }
    }

    // MARK: - Правила разбора

    @Test("несколько блоков одного сообщения дают несколько событий в том же порядке")
    func multipleBlocksKeepOrder() throws {
        let events = normalizer.normalize(try raw(#"""
        {"type":"assistant","message":{"id":"m1","content":[
          {"type":"thinking","thinking":""},
          {"type":"text","text":"Сейчас посмотрю."},
          {"type":"tool_use","id":"t1","name":"Glob","input":{"pattern":"*.png"}}
        ]}}
        """#))
        #expect(events.count == 3)
        guard events.count == 3 else { return }
        #expect(events[0] == .thinking(parentToolUseID: nil))
        #expect(events[1] == .assistantText(AssistantText(text: "Сейчас посмотрю.", messageID: "m1", parentToolUseID: nil)))
        guard case .toolUse(let use) = events[2] else {
            Issue.record("третьим должен быть toolUse")
            return
        }
        #expect(use.id == "t1")
        #expect(use.input["pattern"]?.stringValue == "*.png")
    }

    @Test("действия субагента несут идентификатор родительского вызова")
    func carriesParentToolUseID() throws {
        let events = normalizer.normalize(try raw(#"""
        {"type":"assistant","parent_tool_use_id":"parent-1","message":{"content":[
          {"type":"tool_use","id":"child-1","name":"Read","input":{}}
        ]}}
        """#))
        guard case .toolUse(let use) = events.first else {
            Issue.record("ожидался toolUse")
            return
        }
        #expect(use.parentToolUseID == "parent-1")
    }

    @Test("служебные события хуков отбрасываются, а не приходят как unknown")
    func dropsHookNoise() throws {
        for subtype in AgentEventNormalizer.ignoredSystemSubtypes {
            let events = normalizer.normalize(try raw(#"{"type":"system","subtype":"\#(subtype)"}"#))
            #expect(events.isEmpty, "\(subtype) должен отбрасываться")
        }
    }

    @Test("незнакомый тип и незнакомый подтип приходят как unknown")
    func unknownTypesSurvive() throws {
        let newType = try raw(#"{"type":"something_new","x":1}"#)
        #expect(normalizer.normalize(newType) == [.unknown(newType)])

        let newSubtype = try raw(#"{"type":"system","subtype":"brand_new"}"#)
        #expect(normalizer.normalize(newSubtype) == [.unknown(newSubtype)])
    }

    @Test("известный тип без обязательных полей не роняет разбор")
    func malformedKnownTypesBecomeUnknown() throws {
        let cases = [
            #"{"type":"assistant"}"#,
            #"{"type":"assistant","message":{"content":"строка вместо массива"}}"#,
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"system","subtype":"permission_denied"}"#,
            #"{"type":"rate_limit_event"}"#,
            #"{"type":"user"}"#
        ]
        for json in cases {
            let event = try raw(json)
            #expect(normalizer.normalize(event) == [.unknown(event)], "\(json)")
        }
    }

    @Test("блок вызова без идентификатора пропускается, соседние блоки живут")
    func skipsIncompleteBlockKeepsSiblings() throws {
        let events = normalizer.normalize(try raw(#"""
        {"type":"assistant","message":{"content":[
          {"type":"tool_use","name":"Read"},
          {"type":"text","text":"дальше"}
        ]}}
        """#))
        #expect(events.count == 1)
        #expect(events.first.map { if case .assistantText = $0 { true } else { false } } == true)
    }

    @Test("текст пользователя отбрасывается: приложение знает, что отправило")
    func dropsUserText() throws {
        let asString = try raw(#"{"type":"user","message":{"content":"привет"}}"#)
        #expect(normalizer.normalize(asString).isEmpty)

        let asBlocks = try raw(#"{"type":"user","message":{"content":[{"type":"text","text":"привет"}]}}"#)
        #expect(normalizer.normalize(asBlocks).isEmpty)
    }

    @Test("результат инструмента из массива блоков склеивается в текст")
    func flattensBlockContent() throws {
        let events = normalizer.normalize(try raw(#"""
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[
          {"type":"text","text":"первая"},
          {"type":"image","source":{}},
          {"type":"text","text":"вторая"}
        ]}]}}
        """#))
        guard case .toolResult(let result) = events.first else {
            Issue.record("ожидался toolResult")
            return
        }
        #expect(result.text == "первая\n[изображение]\nвторая")
        #expect(result.isError == false)
    }

    @Test("окна подписки разбираются и сортируются")
    func parsesSubscriptionWindows() throws {
        let events = normalizer.normalize(try raw(#"""
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{
          "seven_day":{"utilization":0.06,"resetsAt":1790085600},
          "five_hour":{"utilization":0.27,"resetsAt":1789551000}
        }}}
        """#))
        guard case .subscriptionUsage(let usage) = events.first else {
            Issue.record("ожидался subscriptionUsage")
            return
        }
        #expect(usage.status == "allowed")
        #expect(usage.windows.map(\.kind) == ["five_hour", "seven_day"])
        #expect(usage.window("five_hour")?.utilization == 0.27)
        #expect(usage.window("seven_day")?.resetsAt == Date(timeIntervalSince1970: 1_790_085_600))
    }

    @Test("result с is_error считается неудачей даже при подтипе success")
    func errorFlagWinsOverSubtype() throws {
        let events = normalizer.normalize(try raw(
            #"{"type":"result","subtype":"success","is_error":true,"result":"сломалось"}"#
        ))
        #expect(events == [.turnFailed(TurnFailure(reason: "success", message: "сломалось"))])
    }

    @Test("пустое описание прогресса не превращается в событие")
    func dropsEmptyProgress() throws {
        #expect(normalizer.normalize(try raw(#"{"type":"system","subtype":"task_summary","detail":""}"#)).isEmpty)
        #expect(normalizer.normalize(try raw(#"{"type":"system","subtype":"task_summary","detail":"Читаю файл"}"#))
                == [.progress("Читаю файл")])
    }
}

@Suite("JSONValue")
struct JSONValueTests {

    @Test("разбор и обратная сериализация сохраняют значение")
    func roundTrip() throws {
        let source = #"{"a":[1,2.5,"три",true,null],"b":{"c":"привет"}}"#
        let value = try JSONValue.decode(Data(source.utf8))
        let again = try JSONValue.decode(Data(value.jsonString().utf8))
        #expect(again == value)
    }

    @Test("ключи в строке отсортированы, слэши не экранируются")
    func stableString() throws {
        let value = try JSONValue.decode(Data(#"{"b":1,"a":"/tmp/x"}"#.utf8))
        #expect(value.jsonString() == #"{"a":"/tmp/x","b":1}"#)
    }

    @Test("целые числа не превращаются в дробные")
    func keepsIntegers() throws {
        let value = try JSONValue.decode(Data(#"{"n":42}"#.utf8))
        #expect(value["n"] == .int(42))
        #expect(value.jsonString() == #"{"n":42}"#)
    }
}
