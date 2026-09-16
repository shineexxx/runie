import EventKit
import Foundation
import RunieKit

// Календарь и Напоминания через EventKit. Доступ к каждому macOS спрашивает один
// раз; просмотр и изменения — разные группы разрешений в Runie.

@MainActor
private enum Store {
    static let shared = EKEventStore()

    static func ensureAccess(to type: EKEntityType) async -> String? {
        let status = EKEventStore.authorizationStatus(for: type)
        let name = type == .event ? "Календарю" : "Напоминаниям"
        switch status {
        case .fullAccess:
            return nil
        case .notDetermined:
            let granted = type == .event
                ? (try? await shared.requestFullAccessToEvents()) ?? false
                : (try? await shared.requestFullAccessToReminders()) ?? false
            return granted ? nil : "Нет доступа к \(name)."
        default:
            return "Нет доступа к \(name): разрешите его в Системных настройках → Конфиденциальность → \(type == .event ? "Календари" : "Напоминания")."
        }
    }
}

private enum When {
    static let locale = Locale(identifier: "ru_RU")

    /// «2026-09-17T15:00», «2026-09-17 15:00», «2026-09-17» — местное время.
    static func parse(_ text: String?) -> (date: Date, hasTime: Bool)? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for (format, hasTime) in [("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true),
                                  ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false)] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return (date, hasTime) }
        }
        if let date = ISO8601DateFormatter().date(from: text) { return (date, true) }
        return nil
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
    }

    static var nowLine: String {
        "Сейчас \(day(Date())), \(time(Date()))."
    }
}

private func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string))])
}

private func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
    var schema: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
    if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
    return .object(schema)
}

// MARK: - Календарь

struct CalendarEventsTool: HostTool {
    let name = "calendar_events"
    let description = "Встречи из Календаря: на сегодня, завтра или неделю вперёд. Возвращает время, название, место и календарь."
    let inputSchema = object(["range": string("За какой период", enum: ["today", "tomorrow", "week"])])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        if let denied = await Store.ensureAccess(to: .event) { return HostToolResult(denied, isError: true) }
        let range = arguments["range"]?.stringValue ?? "today"
        return await MainActor.run {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let (start, days): (Date, Int) = switch range {
            case "tomorrow": (calendar.date(byAdding: .day, value: 1, to: today)!, 1)
            case "week": (today, 7)
            default: (today, 1)
            }
            let end = calendar.date(byAdding: .day, value: days, to: start)!
            let store = Store.shared
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .sorted { $0.startDate < $1.startDate }
            guard !events.isEmpty else { return HostToolResult("\(When.nowLine)\nВстреч нет.") }

            var lines: [String] = [When.nowLine]
            var currentDay: Date?
            for event in events.prefix(60) {
                let day = calendar.startOfDay(for: event.startDate)
                if days > 1, day != currentDay {
                    lines.append("\n\(When.day(event.startDate)):")
                    currentDay = day
                }
                let time = event.isAllDay ? "весь день" : "\(When.time(event.startDate))–\(When.time(event.endDate))"
                var line = "- \(time) \(event.title ?? "Без названия")"
                if let location = event.location, !location.isEmpty { line += " · \(location)" }
                line += " [\(event.calendar.title)]"
                if (event.attendees?.count ?? 0) > 0 { line += " · участников: \(event.attendees!.count)" }
                lines.append(line)
            }
            return HostToolResult(lines.joined(separator: "\n"))
        }
    }
}

struct CreateEventTool: HostTool {
    let name = "create_event"
    let description = """
    Добавляет встречу в Календарь. Время местное, формат 2026-09-17T15:00. \
    Если конец не указан — встреча на duration_minutes (по умолчанию 60). Дата без времени — на весь день.
    """
    let inputSchema = object([
        "title": string("Название"),
        "start": string("Начало, например 2026-09-17T15:00"),
        "end": string("Конец, необязательно"),
        "duration_minutes": .object(["type": .string("number"), "description": .string("Длительность, если нет end")]),
        "location": string("Место, необязательно"),
        "notes": string("Заметки, необязательно"),
        "calendar": string("Название календаря, необязательно")
    ], required: ["title", "start"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        if let denied = await Store.ensureAccess(to: .event) { return HostToolResult(denied, isError: true) }
        guard let title = arguments["title"]?.stringValue, !title.isEmpty,
              let start = When.parse(arguments["start"]?.stringValue)
        else { return HostToolResult("Нужны название и время начала в формате 2026-09-17T15:00.", isError: true) }
        let end = When.parse(arguments["end"]?.stringValue)?.date
        let minutes = arguments["duration_minutes"]?.intValue ?? 60
        let location = arguments["location"]?.stringValue
        let notes = arguments["notes"]?.stringValue
        let calendarName = arguments["calendar"]?.stringValue

        return await MainActor.run {
            let store = Store.shared
            let event = EKEvent(eventStore: store)
            event.title = title
            event.isAllDay = !start.hasTime
            event.startDate = start.date
            event.endDate = end ?? (start.hasTime
                ? start.date.addingTimeInterval(TimeInterval(minutes * 60))
                : Calendar.current.date(byAdding: .day, value: 1, to: start.date)!)
            event.location = location
            event.notes = notes
            event.calendar = calendarName.flatMap { name in
                store.calendars(for: .event).first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame && $0.allowsContentModifications }
            } ?? store.defaultCalendarForNewEvents
            do {
                try store.save(event, span: .thisEvent)
            } catch {
                return HostToolResult("Не удалось сохранить: \(error.localizedDescription)", isError: true)
            }
            let when = event.isAllDay ? When.day(event.startDate) : "\(When.day(event.startDate)), \(When.time(event.startDate))–\(When.time(event.endDate))"
            return HostToolResult("Добавил «\(title)» — \(when) [\(event.calendar.title)].")
        }
    }
}

// MARK: - Напоминания

struct RemindersTool: HostTool {
    let name = "reminders"
    let description = "Невыполненные напоминания: на сегодня и просроченные, или все. Возвращает id, срок, список."
    let inputSchema = object([
        "scope": string("Какие", enum: ["today", "all"]),
        "list": string("Название списка, необязательно")
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        if let denied = await Store.ensureAccess(to: .reminder) { return HostToolResult(denied, isError: true) }
        let scope = arguments["scope"]?.stringValue ?? "today"
        let listName = arguments["list"]?.stringValue

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let store = Store.shared
                let calendars = listName.flatMap { name in
                    store.calendars(for: .reminder).filter { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
                }
                let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
                let predicate = scope == "today"
                    ? store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: calendars)
                    : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
                // EventKit зовёт обработчик в фоновом потоке: он не должен быть
                // закреплён за главным, иначе проверка изоляции роняет приложение.
                store.fetchReminders(matching: predicate) { @Sendable reminders in
                    let items = (reminders ?? []).sorted {
                        ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                    }
                    guard !items.isEmpty else {
                        continuation.resume(returning: HostToolResult("\(When.nowLine)\nНапоминаний нет."))
                        return
                    }
                    let now = Date()
                    let lines = items.prefix(60).map { reminder -> String in
                        var line = "- \(reminder.title ?? "Без названия")"
                        if let due = reminder.dueDateComponents?.date {
                            let overdue = due < now ? " (просрочено)" : ""
                            line += " — до \(When.day(due))\(reminder.dueDateComponents?.hour != nil ? ", " + When.time(due) : "")\(overdue)"
                        }
                        line += " [\(reminder.calendar.title)] id: \(reminder.calendarItemIdentifier)"
                        return line
                    }
                    continuation.resume(returning: HostToolResult(([When.nowLine] + lines).joined(separator: "\n")))
                }
            }
        }
    }
}

struct CreateReminderTool: HostTool {
    let name = "create_reminder"
    let description = "Добавляет напоминание. Срок — местное время, 2026-09-17T15:00 или просто дата."
    let inputSchema = object([
        "title": string("Что напомнить"),
        "due": string("Срок, необязательно"),
        "list": string("Название списка, необязательно"),
        "notes": string("Заметки, необязательно")
    ], required: ["title"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        if let denied = await Store.ensureAccess(to: .reminder) { return HostToolResult(denied, isError: true) }
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            return HostToolResult("Нужно, что напомнить.", isError: true)
        }
        let due = When.parse(arguments["due"]?.stringValue)
        let listName = arguments["list"]?.stringValue
        let notes = arguments["notes"]?.stringValue

        return await MainActor.run {
            let store = Store.shared
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.notes = notes
            reminder.calendar = listName.flatMap { name in
                store.calendars(for: .reminder).first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
            } ?? store.defaultCalendarForNewReminders()
            if let due {
                let components: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                reminder.dueDateComponents = Calendar.current.dateComponents(components, from: due.date)
                if due.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
            }
            do {
                try store.save(reminder, commit: true)
            } catch {
                return HostToolResult("Не удалось сохранить: \(error.localizedDescription)", isError: true)
            }
            let when = due.map { " — до \(When.day($0.date))\($0.hasTime ? ", " + When.time($0.date) : "")" } ?? ""
            return HostToolResult("Добавил напоминание «\(title)»\(when) [\(reminder.calendar?.title ?? "")].")
        }
    }
}

struct CompleteReminderTool: HostTool {
    let name = "complete_reminder"
    let description = "Отмечает напоминание выполненным. id — из инструмента reminders."
    let inputSchema = object([
        "id": string("id напоминания"),
        "title": string("Название — для подписи в интерфейсе")
    ], required: ["id"])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        if let denied = await Store.ensureAccess(to: .reminder) { return HostToolResult(denied, isError: true) }
        guard let id = arguments["id"]?.stringValue else { return HostToolResult("Нужен id.", isError: true) }
        return await MainActor.run {
            let store = Store.shared
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                return HostToolResult("Нет напоминания с таким id.", isError: true)
            }
            reminder.isCompleted = true
            do {
                try store.save(reminder, commit: true)
            } catch {
                return HostToolResult("Не удалось сохранить: \(error.localizedDescription)", isError: true)
            }
            return HostToolResult("Отметил выполненным: «\(reminder.title ?? "")».")
        }
    }
}
