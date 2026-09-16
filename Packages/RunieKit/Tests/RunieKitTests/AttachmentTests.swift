import Foundation
import Testing
@testable import RunieKit

@Suite("Картинки и файлы")
struct AttachmentTests {

    @Test("картинка уходит блоком image перед текстом, как в Messages API")
    func encodesImages() throws {
        let message = UserMessage("что тут?", images: [MessageImage(mediaType: "image/png", data: Data([1, 2, 3]))])
        let json = try JSONValue.decode(message.ndjsonLine())
        let content = try #require(json.path("message", "content")?.arrayValue)
        #expect(content.count == 2)
        #expect(content[0]["type"]?.stringValue == "image")
        #expect(content[0].path("source", "type")?.stringValue == "base64")
        #expect(content[0].path("source", "media_type")?.stringValue == "image/png")
        #expect(content[0].path("source", "data")?.stringValue == "AQID")
        #expect(content[1]["text"]?.stringValue == "что тут?")
    }

    @Test("без картинок формат прежний — один текстовый блок")
    func textOnlyUnchanged() throws {
        let json = try JSONValue.decode(UserMessage("привет").ndjsonLine())
        #expect(json.path("message", "content")?.arrayValue?.count == 1)
    }

    @Test("ответ агента делится на текст, картинки и файлы")
    func parsesSegments() {
        let text = """
        Вот график:
        ![продажи](/Users/me/chart.png)
        Отчёт тут: [отчёт.pdf](/Users/me/отчёт.pdf), а сайт — [Apple](https://apple.com).
        ![](https://example.com/cat.jpg)
        """
        let segments = MessageSegment.parse(text)
        #expect(segments == [
            .text("Вот график:"),
            .image(source: "/Users/me/chart.png", alt: "продажи"),
            .text("Отчёт тут: "),
            .file(path: "/Users/me/отчёт.pdf", name: "отчёт.pdf"),
            .text(", а сайт — [Apple](https://apple.com)."),
            .image(source: "https://example.com/cat.jpg", alt: ""),
        ])
    }

    @Test("обычный текст без ссылок — один сегмент; ~ и file:// раскрываются")
    func plainAndPaths() {
        #expect(MessageSegment.parse("просто [текст] и (скобки)") == [.text("просто [текст] и (скобки)")])
        let home = NSHomeDirectory()
        #expect(MessageSegment.parse("[a](~/x.txt)") == [.file(path: home + "/x.txt", name: "a")])
        #expect(MessageSegment.parse("![](file:///tmp/a%20b.png)") == [.image(source: "/tmp/a b.png", alt: "")])
    }

    @Test("сессия: картинка уходит агенту, пути — припиской, в ленте — без приписки")
    @MainActor
    func sessionSendsAttachments() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "runie-att-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appending(path: "shot.png")
        try Data([0x89, 0x50]).write(to: image)
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)

        let attachments = [Attachment(path: image.path), Attachment(path: "/tmp/отчёт.pdf")]
        session.send("", attachments: attachments)

        let message = try #require(backend.connections.first?.messages.first)
        #expect(message.images.count == 1)
        #expect(message.text.hasPrefix("Посмотри эти файлы."))
        #expect(message.text.contains("- картинка (показана выше): \(image.path)"))
        #expect(message.text.contains("- файл: /tmp/отчёт.pdf"))

        guard case .user(let item) = session.timeline.items.first else { Issue.record("нет сообщения"); return }
        #expect(item.text == "Посмотри эти файлы.")
        #expect(item.attachments == attachments)
    }
}
