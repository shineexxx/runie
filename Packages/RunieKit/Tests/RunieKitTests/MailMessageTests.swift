import Foundation
import Testing
@testable import RunieKit

@Suite("Разбор писем")
struct MailMessageTests {

    /// Письмо в файле Почты: первая строка — длина, дальше само письмо.
    private func emlx(_ message: String) -> Data {
        let body = Data(message.utf8)
        return Data("\(body.count)\n".utf8) + body + Data("<?xml version=\"1.0\"?><plist></plist>".utf8)
    }

    @Test("простое письмо: тема, отправитель, дата, текст")
    func plain() throws {
        let data = emlx("""
        From: Саша <sasha@example.com>
        To: arseny@example.com
        Subject: Смета на кухню
        Date: Mon, 21 Sep 2026 14:32:10 +0300
        Content-Type: text/plain; charset=utf-8

        Плитка — 40 000 ₽, работа — 25 000 ₽.
        Столешницу привезут в октябре.
        """)
        let message = try #require(MailMessage.parse(emlx: data))
        #expect(message.subject == "Смета на кухню")
        #expect(message.sender == "Саша <sasha@example.com>")
        #expect(message.body.contains("Плитка — 40 000 ₽"))
        #expect(message.body.contains("октябре"))
        let date = try #require(message.date)
        #expect(abs(date.timeIntervalSince1970 - 1_789_990_330) < 1)
    }

    @Test("тема в кодировке заголовков: base64 и quoted-printable")
    func encodedSubjects() {
        #expect(MailMessage.decodeWords("=?UTF-8?B?0KHQvNC10YLQsA==?=") == "Смета")
        #expect(MailMessage.decodeWords("=?utf-8?Q?=D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82?=") == "Привет")
        // Подчёркивание в заголовке — пробел.
        #expect(MailMessage.decodeWords("=?utf-8?Q?Hello_world?=") == "Hello world")
        // Смесь обычного текста и кодированных кусков.
        #expect(MailMessage.decodeWords("Re: =?UTF-8?B?0KHQvNC10YLQsA==?= (важно)").contains("Смета"))
        // Не тронутое остаётся собой.
        #expect(MailMessage.decodeWords("Обычная тема") == "Обычная тема")
        // Незнакомый вид кодировки: оставляем как есть, не теряя текст.
        #expect(MailMessage.decodeWords("=?UTF-8?X?что-то?=").contains("что-то"))
    }

    @Test("тело в base64 и quoted-printable")
    func encodedBodies() throws {
        let base64 = Data("Привет, это тело письма".utf8).base64EncodedString()
        let message = try #require(MailMessage.parse(message: Data("""
        Subject: Тест
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        \(base64)
        """.utf8)))
        #expect(message.body == "Привет, это тело письма")

        let quoted = try #require(MailMessage.parse(message: Data("""
        Subject: Тест
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        =D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82 =
        =D0=BC=D0=B8=D1=80
        """.utf8)))
        #expect(quoted.body.contains("Привет"))
        #expect(quoted.body.contains("мир"))
    }

    @Test("составное письмо: берём текст, а не разметку")
    func multipart() throws {
        let message = try #require(MailMessage.parse(message: Data("""
        Subject: Отчёт
        Content-Type: multipart/alternative; boundary="ГРАНИЦА"

        --ГРАНИЦА
        Content-Type: text/plain; charset=utf-8

        Это простой текст.
        --ГРАНИЦА
        Content-Type: text/html; charset=utf-8

        <html><body><p>Это разметка.</p></body></html>
        --ГРАНИЦА--
        """.utf8)))
        #expect(message.body.contains("Это простой текст"))
        #expect(!message.body.contains("разметка"))
    }

    @Test("если текста нет — вытаскиваем его из разметки")
    func htmlOnly() throws {
        let message = try #require(MailMessage.parse(message: Data("""
        Subject: Только HTML
        Content-Type: text/html; charset=utf-8

        <html><head><style>p { color: red }</style></head>
        <body><p>Привет,&nbsp;Арсений!</p><p>Счёт на 40&#160;000 &#8381;</p>
        <script>alert(1)</script></body></html>
        """.utf8)))
        #expect(message.body.contains("Привет"))
        #expect(message.body.contains("Арсений"))
        #expect(!message.body.contains("color: red"))
        #expect(!message.body.contains("alert"))
        #expect(!message.body.contains("<p>"))
    }

    @Test("кривое письмо не роняет разбор")
    func broken() {
        #expect(MailMessage.parse(emlx: Data()) == nil)
        #expect(MailMessage.parse(emlx: Data("не письмо вовсе".utf8)) == nil)
        #expect(MailMessage.parse(message: Data("Subject: без тела".utf8))?.body == "")
        // Длина в шапке больше самого файла — берём, сколько есть.
        let short = Data("999999\nSubject: Тема\n\nТело".utf8)
        #expect(MailMessage.parse(emlx: short)?.subject == "Тема")
    }

    @Test("дата в разных видах")
    func dates() {
        #expect(MailMessage.parseDate("Mon, 21 Sep 2026 14:32:10 +0300") != nil)
        #expect(MailMessage.parseDate("21 Sep 2026 14:32:10 +0000") != nil)
        #expect(MailMessage.parseDate("Mon, 21 Sep 2026 14:32:10 +0300 (MSK)") != nil)
        #expect(MailMessage.parseDate("вчера вечером") == nil)
    }

    @Test("заголовки: регистр, переносы, двоеточия внутри")
    func headers() {
        let headers = MailMessage.parseHeaders("""
        Subject: Тема: с двоеточием
        FROM: Саша
        X-Long: первая часть
         вторая часть
        """)
        #expect(headers["subject"] == "Тема: с двоеточием")
        #expect(headers["from"] == "Саша")
        #expect(headers["x-long"] == "первая часть вторая часть")
    }
}
