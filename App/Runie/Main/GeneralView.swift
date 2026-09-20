import RunieKit
import SwiftUI

struct GeneralView: View {
    private let claudePath = try? ClaudeCodeLocator().locate().path
    private let updater = UpdaterModel.shared
    @AppStorage(MorningBriefing.enabledKey) private var briefingEnabled = true

    private var lastCheck: String {
        guard let date = updater.lastCheck else { return "Ещё не проверяли" }
        return "Последняя проверка: " + date.formatted(.dateTime.day().month().hour().minute().locale(.runie))
    }

    var body: some View {
        Form {
            Section("Руни") {
                LabeledContent("Версия", value: Runie.version)
                LabeledContent("Как вызвать", value: "Нажмите на орб у края экрана")
            }
            Section("Обновления") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(updater.status ?? "Runie обновляется сам")
                        Text(lastCheck)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Проверить сейчас") { updater.check() }
                        .disabled(!updater.canCheck)
                }
                Toggle(isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Проверять обновления автоматически")
                        Text("Раз в сутки Runie заглядывает на GitHub и предлагает поставить новую версию. Каждый выпуск подписан ключом автора.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Claude Code") {
                if let claudePath {
                    LabeledContent("Найден", value: claudePath)
                } else {
                    Text("Claude Code не найден. Установите его и выполните в терминале `claude login`.")
                        .foregroundStyle(.orange)
                }
            }
            Section("Утренний разбор дня") {
                Toggle(isOn: $briefingEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Звать разобрать день по утрам")
                        Text("Когда утром вы впервые открываете Mac, орб выходит из-за края, а в чате первой подсказкой стоит «Разобрать день»: встречи, напоминания и свободные окна. Раз в день.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("История") {
                LabeledContent("Где хранится", value: "~/Library/Application Support/Runie")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandGlowBackground())
        
    }
}
