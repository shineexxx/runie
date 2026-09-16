import AppKit
import Observation
import RunieKit

/// Утренний разбор дня по событию присутствия, а не по таймеру.
///
/// Утром, когда человек впервые будит или разблокирует Mac, Руни зовёт: орб
/// выходит из-за края и светится, а в чате первой подсказкой стоит «Разобрать
/// день». Раз в день; разобрал — до завтра не предлагает.
@MainActor
@Observable
final class MorningBriefing {

    static let prompt = """
    Разбери мой день: встречи на сегодня и напоминания на сегодня и просроченные. \
    Коротко: что главное, где свободные окна и о чём не забыть.
    """

    static let suggestion = Suggestion(label: "Разобрать день", prompt: prompt)

    private enum Key {
        static let enabled = "briefing.enabled"
        static let done = "briefing.doneDay"
        static let nudged = "briefing.nudgedDay"
    }

    /// Выключатель в настройках (`@AppStorage` с тем же ключом).
    static let enabledKey = Key.enabled

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
    }

    private(set) var doneDay: String?

    /// Позвать человека: вызывает приложение, чтобы орб вышел и засветился.
    @ObservationIgnored var onNudge: (() -> Void)?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let defaults = UserDefaults.standard
        doneDay = defaults.string(forKey: Key.done)

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for (center, name) in [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (distributed as NotificationCenter, Notification.Name("com.apple.screenIsUnlocked"))
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MorningBriefing.current?.presenceDetected() }
            }
            observers.append((center, token))
        }
        MorningBriefing.current = self
    }

    /// Единственный экземпляр — для обработчиков системных уведомлений.
    private static weak var current: MorningBriefing?

    /// Утро, разбор включён и сегодня ещё не делался.
    var isDue: Bool {
        #if DEBUG
        // `-RunieBriefingNow YES` — утро прямо сейчас, для проверки.
        if UserDefaults.standard.bool(forKey: "RunieBriefingNow") { return doneDay != Self.today() }
        #endif
        guard isEnabled, doneDay != Self.today() else { return false }
        return (5..<12).contains(Calendar.current.component(.hour, from: Date()))
    }

    /// Запуск Runie утром — тоже «человек пришёл»: например, после входа в систему.
    func appLaunched() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.presenceDetected()
        }
    }

    func markDone() {
        doneDay = Self.today()
        UserDefaults.standard.set(doneDay, forKey: Key.done)
    }

    private func presenceDetected() {
        var alreadyNudged = UserDefaults.standard.string(forKey: Key.nudged) == Self.today()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "RunieBriefingNow") { alreadyNudged = false }
        #endif
        guard isDue, !alreadyNudged else { return }
        UserDefaults.standard.set(Self.today(), forKey: Key.nudged)
        onNudge?()
    }

    private static func today() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}
