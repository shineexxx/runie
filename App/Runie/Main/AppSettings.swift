import Foundation
import Observation
import RunieKit

extension Locale {
    /// Runie говорит по-русски, даже если система на другом языке: даты и числа
    /// в окне не должны переходить на английский посреди русского текста.
    static let runie = Locale(identifier: "ru_RU")
}

/// Настройки, которые человек меняет в окне Runie.
@MainActor
@Observable
final class AppSettings {

    private enum Key {
        static let policy = "permissions.policy"
    }

    /// Какие группы действий разрешать без вопроса. Сессия получает правила сразу:
    /// следующий же вопрос агента решается по новым правилам.
    var policy: PermissionPolicy {
        didSet {
            save()
            onPolicyChange?(policy)
        }
    }

    @ObservationIgnored var onPolicyChange: ((PermissionPolicy) -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Key.policy),
           let stored = try? JSONDecoder().decode(PermissionPolicy.self, from: data) {
            policy = stored
        } else {
            policy = PermissionPolicy()
        }
    }

    func setRule(_ rule: PermissionPolicy.Rule, for category: PermissionCategory) {
        policy.rules[category] = rule
    }

    private func save() {
        if let data = try? JSONEncoder().encode(policy) {
            UserDefaults.standard.set(data, forKey: Key.policy)
        }
    }
}
