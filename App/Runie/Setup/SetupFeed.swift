import SwiftUI

/// Знакомство в чате: Руни пишет облачками, а шаги — карточки с кнопками под ними.
struct SetupFeed: View {
    let setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            switch setup.stage {
            case .checking, .ready:
                SetupBubble {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Секунду…").foregroundStyle(.secondary)
                    }
                }
            case .needsClaude:
                SetupBubble(text: "Привет! Я Руни. Я работаю на Claude Code — его нужно один раз установить.")
                SetupCard {
                    Text("Откройте Терминал, вставьте команду и нажмите Return:")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text(SetupModel.installCommand)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        CopyButton(text: SetupModel.installCommand, label: "Скопировать команду", size: 12)
                    }
                    .padding(.leading, 10)
                    .padding(.vertical, 4)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Waiting(text: "Жду установку…")
                        Spacer()
                        Button("Открыть Терминал") {
                            setup.copyInstallCommand()
                            setup.openTerminal()
                        }
                        .buttonStyle(SetupButtonStyle(primary: true))
                        .help("Команда уже будет в буфере обмена")
                    }
                }
            case .needsLogin:
                SetupBubble(text: "Привет! Я Руни. Чтобы начать, войдите в аккаунт Claude — подойдёт подписка Pro или Max.")
                SetupCard {
                    HStack {
                        Spacer()
                        Button("Войти в Claude", action: setup.login)
                            .buttonStyle(SetupButtonStyle(primary: true))
                    }
                }
            case .loggingIn:
                SetupBubble(text: "Открыл страницу входа в браузере. Как только войдёте, я продолжу.")
                SetupCard {
                    HStack {
                        Waiting(text: "Жду вход…")
                        Spacer()
                        if setup.loginURL != nil {
                            Button("Открыть страницу", action: setup.openLoginPage)
                                .buttonStyle(SetupButtonStyle(primary: false))
                        }
                        Button("Отмена", action: setup.cancelLogin)
                            .buttonStyle(SetupButtonStyle(primary: false))
                    }
                }
            case .chooseTrust:
                SetupBubble(text: "Готово, я на связи! Последний вопрос: как мне действовать?")
                SetupCard {
                    TrustOption(
                        title: "Спрашивать только о рискованном",
                        detail: "Смотреть файлы, календарь и вкладки буду сам. Менять, удалять и отправлять — только с вашего разрешения.",
                        symbol: "hand.raised",
                        recommended: true
                    ) { setup.chooseTrust(cautious: true) }
                    TrustOption(
                        title: "Спрашивать обо всём",
                        detail: "Перед каждым действием покажу, что собираюсь сделать.",
                        symbol: "checkmark.shield",
                        recommended: false
                    ) { setup.chooseTrust(cautious: false) }
                    Text("Поменять можно в настройках, раздел «Разрешения».")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: setup.stage)
    }
}

private struct SetupBubble<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 14, weight: .medium))
            // Текст переносится по словам, а не обрезается многоточием.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            // Во всю ширину карточки под облачком: шаги читаются одним столбцом.
            .frame(width: 360, alignment: .leading)
            .readableSurface(MessageBubbleShape(tail: .leading))
            .padding(.leading, MessageBubbleShape.tailReach)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

extension SetupBubble where Content == Text {
    init(text: String) {
        self.init { Text(text) }
    }
}

private struct SetupCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .font(.system(size: 13))
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .readableSurface(RoundedRectangle(cornerRadius: 20))
        .padding(.leading, MessageBubbleShape.tailReach)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
    }
}

private struct Waiting: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}

private struct TrustOption: View {
    let title: String
    let detail: String
    let symbol: String
    let recommended: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OrbPalette.teal)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if recommended {
                            Text("советую")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(OrbPalette.teal)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(OrbPalette.teal.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.primary.opacity(hovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SetupButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(primary ? AnyShapeStyle(OrbPalette.deep.gradient) : AnyShapeStyle(.primary.opacity(0.08)))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
