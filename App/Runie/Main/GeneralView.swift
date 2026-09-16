import RunieKit
import SwiftUI

struct GeneralView: View {
    private let claudePath = try? ClaudeCodeLocator().locate().path
    @AppStorage(MorningBriefing.enabledKey) private var briefingEnabled = true

    var body: some View {
        Form {
            Section("Руни") {
                LabeledContent("Версия", value: Runie.version)
                LabeledContent("Как вызвать", value: "Нажмите на орб у края экрана")
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
