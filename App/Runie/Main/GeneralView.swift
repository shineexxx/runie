import RunieKit
import SwiftUI

struct GeneralView: View {
    let settings: AppSettings

    private let claudePath = try? ClaudeCodeLocator().locate().path
    private let updater = UpdaterModel.shared
    @AppStorage(MorningBriefing.enabledKey) private var briefingEnabled = true

    private var lastCheck: String {
        guard let date = updater.lastCheck else { return String(localized: "Ещё не проверяли") }
        return String(localized: "Последняя проверка: ") + date.formatted(.dateTime.day().month().hour().minute().locale(.runie))
    }

    var body: some View {
        Form {
            Section("Руни") {
                LabeledContent("Версия", value: Runie.version)
                LabeledContent("Как вызвать", value: String(localized: "Нажмите на орб у края экрана"))
            }
            Section("Язык") {
                Picker(selection: Binding(get: { settings.answerLanguage }, set: { settings.answerLanguage = $0 })) {
                    Text("Как в системе").tag(AnswerLanguage.system)
                    Text("Русский").tag(AnswerLanguage.russian)
                    Text("English").tag(AnswerLanguage.english)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Язык ответов")
                        Text("На этом языке Руни отвечает, придумывает подсказки и пишет даты. Язык интерфейса берётся из настроек macOS.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
            }
            Section("Обновления") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(updater.status ?? String(localized: "Runie обновляется сам"))
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
