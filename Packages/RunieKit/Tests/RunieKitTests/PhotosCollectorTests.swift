import Foundation
import Testing
@testable import RunieKit

@Suite("Сбор медиатеки")
struct PhotosCollectorTests {

    private let collector = PhotosCollector()
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("снимок экрана: в записи заголовок, надписи и альбомы")
    func screenshot() {
        let shot = PhotosCollector.Shot(
            id: "ABC-123/L0/001", kind: .screenshot, date: day,
            albums: ["Работа"], recognized: "Не удалось проверить сертификат\nПовторить"
        )
        let item = collector.item(from: shot)
        #expect(item.source == .photos)
        #expect(item.externalID == "ABC-123/L0/001")
        #expect(item.title.hasPrefix(t("Снимок экрана")))
        #expect(item.body.contains("сертификат"))
        #expect(item.body.contains("Работа"))
        #expect(item.details["kind"] == "screenshot")
        #expect(item.details["albums"] == "Работа")
    }

    @Test("обычная фотография: без надписей, но с датой и видом")
    func photo() {
        let item = collector.item(from: .init(id: "X", kind: .photo, date: day))
        #expect(item.title.hasPrefix(t("Фотография")))
        #expect(item.body.isEmpty)
        #expect(item.details["kind"] == "photo")
        #expect(item.details["albums"] == nil)
        #expect(item.date == day)

        let video = collector.item(from: .init(id: "Y", kind: .video, date: day))
        #expect(video.title.hasPrefix(t("Видео")))
    }

    @Test("длинные надписи обрезаются")
    func limits() {
        var collector = PhotosCollector()
        collector.maxTextLength = 20
        let item = collector.item(from: .init(
            id: "Z", kind: .screenshot, date: day,
            recognized: String(repeating: "текст ", count: 50)
        ))
        #expect(item.body.count == 20)
    }

    @Test("пустые надписи в тело не попадают")
    func emptyRecognition() {
        let item = collector.item(from: .init(id: "W", kind: .screenshot, date: day, recognized: "   \n  "))
        #expect(item.body.isEmpty)
    }
}
