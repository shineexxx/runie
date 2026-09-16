import RunieKit
import SwiftUI

/// Выбор модели прямо в поле ввода. Список — из самого Claude Code: новые модели
/// появляются здесь сами.
struct ModelMenu: View {
    let session: ChatSession
    let settings: AppSettings
    var compact = true

    var body: some View {
        Menu {
            if session.availableModels.isEmpty {
                Text("Загружаю модели Claude Code…")
            }
            ForEach(session.availableModels) { model in
                Button {
                    select(model)
                } label: {
                    // Галочка у выбранной, описание второй строкой.
                    if isSelected(model) {
                        Label {
                            modelLabel(model)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        modelLabel(model)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentTitle)
                    .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Модель Claude")
        .accessibilityLabel("Модель: \(currentTitle)")
    }

    private func modelLabel(_ model: AgentModel) -> some View {
        VStack(alignment: .leading) {
            Text(ModelNames.title(model))
            Text(ModelNames.detail(model))
        }
    }

    private func isSelected(_ model: AgentModel) -> Bool {
        (session.selectedModel ?? "default") == model.value
    }

    private func select(_ model: AgentModel) {
        // «По умолчанию» — значит, как настроено в самом Claude Code.
        let value = model.value == "default" ? nil : model.value
        session.selectModel(value)
        settings.selectedModel = value
    }

    private var currentTitle: String {
        let value = session.selectedModel ?? "default"
        guard let model = session.availableModels.first(where: { $0.value == value }) else {
            return session.selectedModel ?? "Модель"
        }
        return ModelNames.short(model)
    }
}

/// Русские подписи к моделям. CLI отдаёт их по-английски; знакомые фразы
/// переводятся, незнакомые — например, у только что вышедшей модели — остаются как есть.
enum ModelNames {

    private static let phrases: [String: String] = [
        "Best for everyday, complex tasks": "для повседневных и сложных задач",
        "Most capable for your hardest and longest-running tasks": "самая способная — для самых трудных и долгих задач",
        "Efficient for routine tasks": "экономная — для обычных задач",
        "Fastest for quick answers": "самая быстрая — для коротких ответов",
    ]

    /// «Opus 5 with 1M context» → «Opus 5».
    private static func baseName(_ model: AgentModel) -> String {
        let head = model.description.components(separatedBy: " · ").first ?? ""
        let name = head.components(separatedBy: " with ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? model.displayName : name
    }

    private static func hasLongContext(_ model: AgentModel) -> Bool {
        model.description.contains("1M context") || model.value.contains("[1m]")
    }

    /// Коротко для кнопки: «Opus 5».
    static func short(_ model: AgentModel) -> String {
        baseName(model)
    }

    /// Строка меню: «По умолчанию — Opus 5, контекст 1M».
    static func title(_ model: AgentModel) -> String {
        var name = baseName(model)
        if hasLongContext(model) { name += ", контекст 1M" }
        return model.value == "default" ? "Как в Claude Code — \(name)" : name
    }

    static func detail(_ model: AgentModel) -> String {
        let parts = model.description.components(separatedBy: " · ")
        guard parts.count > 1 else { return model.description }
        let tail = parts.dropFirst().joined(separator: " · ")
        let translated = phrases[tail] ?? tail
        return translated.prefix(1).uppercased() + translated.dropFirst()
    }
}
