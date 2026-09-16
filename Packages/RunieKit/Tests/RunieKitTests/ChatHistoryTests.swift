import Foundation
import Testing
@testable import RunieKit

@MainActor
@Suite("История разговоров")
struct ChatHistoryTests {

    private func temporaryStore() -> ChatHistoryStore {
        ChatHistoryStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "runie-history-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("разговор сохраняется после хода и открывается с той же сессией")
    func savesAndReopens() async throws {
        let store = temporaryStore()
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.store = store

        session.send("прочитай todo")
        let connection = try #require(backend.connections.first)
        for event in try FixtureLoader.events("tool-use") {
            connection.continuation.yield(.event(event))
        }
        #expect(await eventually { !session.isBusy })

        let records = store.list()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.title == "прочитай todo")
        #expect(record.sessionID == "11111111-1111-4111-8111-111111111111")
        #expect(record.items == session.timeline.items)

        let other = ChatSession(backend: backend)
        other.open(record)
        #expect(other.timeline.items == record.items)
        other.send("дальше")
        #expect(backend.resumedWith.last == "11111111-1111-4111-8111-111111111111")
        #expect(store.list().count == 1)
    }

    @Test("новый разговор — новый файл, пустой не сохраняется")
    func startOverCreatesNew() throws {
        let store = temporaryStore()
        let session = ChatSession(backend: FakeBackend())
        session.store = store
        session.startOver()
        #expect(store.list().isEmpty)

        session.send("раз")
        session.startOver()
        session.send("два")
        #expect(store.list().map(\.title).sorted() == ["два", "раз"])
    }

    @Test("длинный заголовок обрезается по первой строке")
    func title() {
        let items: [TimelineItem] = [.user(UserItem(id: UUID(), text: String(repeating: "а", count: 100) + "\nвторая"))]
        #expect(ConversationRecord.title(for: items).count == 71)
    }
}
