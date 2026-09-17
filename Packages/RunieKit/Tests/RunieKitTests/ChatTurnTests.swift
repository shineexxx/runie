import Foundation
import Testing
@testable import RunieKit

@Suite("Ходы разговора")
struct ChatTurnTests {

    private func user(_ text: String) -> TimelineItem { .user(UserItem(id: UUID(), text: text)) }
    private func reply(_ text: String) -> TimelineItem { .assistant(AssistantItem(messageID: nil, text: text)) }
    private func notice(_ kind: NoticeItem.Kind, _ text: String) -> TimelineItem {
        .notice(NoticeItem(id: UUID(), kind: kind, text: text))
    }

    @Test("лента делится на ходы по сообщениям человека")
    func split() {
        let turns = ChatTurn.split([user("а"), reply("1"), reply("2"), user("б"), notice(.error, "сбой")])
        #expect(turns.count == 2)
        #expect(turns[0].user?.text == "а")
        #expect(turns[0].reply == "2")
        #expect(turns[0].failure == nil)
        #expect(turns[1].reply == nil)
        #expect(turns[1].failure?.text == "сбой")
        #expect(ChatTurn.split([]).isEmpty)
    }

    @Test("ошибка, после которой Руни ответил, — не итог хода")
    func recoveredError() {
        let turn = ChatTurn.split([user("а"), notice(.error, "сбой"), reply("всё же вот")]).first
        #expect(turn?.failure == nil)
        #expect(turn?.reply == "всё же вот")
    }

    @Test("повтор отправляет последнее сообщение ещё раз")
    @MainActor
    func retry() throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        #expect(session.lastUserMessage == nil)
        session.send("привет")
        #expect(session.lastUserMessage?.text == "привет")
    }
}
