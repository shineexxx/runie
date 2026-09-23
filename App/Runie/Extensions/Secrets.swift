import Foundation
import Observation
import RunieKit
import Security
import SwiftUI

/// Ключи API подключённых сервисов — в Связке ключей, а не в файлах.
enum SecretStore {

    private static let service = "app.runie.Runie.secrets"

    static func value(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            // Ключ есть, но Связка не отдала — это не «сервис не подключён», и
            // молчать об этом нельзя: сбор просто не начнётся, а почему —
            // непонятно ни человеку, ни мне.
            lastFailure = status == errSecItemNotFound ? nil : describe(status)
            return nil
        }
        lastFailure = nil
        return String(data: data, encoding: .utf8)
    }

    /// Почему последнее чтение не удалось. `nil` — всё в порядке или ключа
    /// просто нет.
    nonisolated(unsafe) private(set) static var lastFailure: String?

    private static func describe(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
        return String(localized: "Связка ключей не отдала ключ: \(text)")
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Runie — \(account)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    /// Переменные окружения для Claude Code: ключи всех серверов Руни и PATH, в котором
    /// находятся npx, uvx и сам Claude Code, — у приложения из Finder он короткий.
    static func environment(for plugin: RuniePlugin) -> [String: String] {
        var environment: [String: String] = [:]
        for server in plugin.servers() {
            for secret in server.secrets {
                let variable = RuniePlugin.environmentVariable(server: server.name, variable: secret.variable)
                if let value = value(for: variable) { environment[variable] = value }
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin"]
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let parts = current.split(separator: ":").map(String.init)
        environment["PATH"] = (parts + extra.filter { !parts.contains($0) }).joined(separator: ":")
        return environment
    }
}

/// Запрос ключей у человека: инструмент ждёт, пока тот введёт их в карточке
/// или откажется. Модель значений не видит — только «сохранено» или «нет».
@MainActor
@Observable
final class SecretBroker {

    static let shared = SecretBroker()

    struct Request: Identifiable {
        let id = UUID()
        let serverTitle: String
        let serverName: String
        let fields: [RuniePlugin.SecretField]
    }

    private(set) var pending: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?
    /// Появился запрос — приложение открывает чат, если он закрыт.
    @ObservationIgnored var onRequest: (() -> Void)?

    /// `true`, если человек ввёл все ключи.
    func request(serverName: String, title: String, fields: [RuniePlugin.SecretField]) async -> Bool {
        // Прежний запрос, на который так и не ответили, считается отменённым.
        finish(false)
        pending = Request(serverTitle: title, serverName: serverName, fields: fields)
        onRequest?()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func submit(_ values: [String: String]) {
        guard let request = pending else { return }
        for field in request.fields {
            let value = values[field.variable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { continue }
            SecretStore.set(value, for: RuniePlugin.environmentVariable(server: request.serverName, variable: field.variable))
        }
        finish(true)
    }

    func cancel() {
        finish(false)
    }

    private func finish(_ result: Bool) {
        pending = nil
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Карточка ввода ключей: поля скрытые, значение уходит в Связку ключей, мимо модели.
struct SecretCard: View {
    let request: SecretBroker.Request
    let broker: SecretBroker

    @State private var values: [String: String] = [:]

    private var isComplete: Bool {
        request.fields.allSatisfy { !(values[$0.variable] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Нужен ключ для «\(request.serverTitle)»", systemImage: "key.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OrbPalette.teal)

            ForEach(request.fields, id: \.variable) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(.system(size: 13, weight: .semibold))
                    SecureField("Вставьте сюда", text: Binding(
                        get: { values[field.variable] ?? "" },
                        set: { values[field.variable] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if isComplete { broker.submit(values) } }
                    if let hint = field.hint, !hint.isEmpty {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("Ключ сохранится в Связке ключей этого Mac. Руни его не видит — он передаётся только самому сервису.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Не сейчас") { broker.cancel() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Сохранить") { broker.submit(values) }
                    .buttonStyle(.borderedProminent)
                    .tint(OrbPalette.deep)
                    .disabled(!isComplete)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .readableSurface(RoundedRectangle(cornerRadius: 20))
    }
}
