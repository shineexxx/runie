import RunieKit
import SwiftUI

struct GeneralView: View {
    private let claudePath = try? ClaudeCodeLocator().locate().path

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
            Section("История") {
                LabeledContent("Где хранится", value: "~/Library/Application Support/Runie")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandGlowBackground())
        
    }
}
