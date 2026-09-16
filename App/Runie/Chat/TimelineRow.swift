import RunieKit
import SwiftUI

struct TimelineRow: View {
    let item: TimelineItem

    var body: some View {
        switch item {
        case .user(let user):
            UserBubble(text: user.text)
        case .assistant(let assistant):
            AssistantMessage(text: assistant.text)
        case .action(let action):
            ActionRow(action: action)
        case .notice(let notice):
            NoticeRow(notice: notice)
        }
    }
}

// MARK: - Реплики

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // Заливка, а не стекло: строка лежит внутри стеклянной панели,
                // и стекло на стекле мутнеет.
                .background(OrbPalette.teal.opacity(0.22), in: .rect(cornerRadius: 16))
        }
    }
}

private struct AssistantMessage: View {
    let text: String

    var body: some View {
        Text(MarkdownText.inline(text))
            .font(.system(size: 14))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

}

// MARK: - Руки

private struct ActionRow: View {
    let action: ActionItem

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ActionStatusIcon(status: action.status)
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(action.status == .denied ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let detail = action.detail {
                            Text(detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 0)

                    if action.output != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(action.output == nil)

            if isExpanded, let output = action.output {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                    .padding(.leading, 22)
            }
        }
        .padding(.leading, action.isNested ? 16 : 0)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(action.title), \(statusLabel)")
    }

    private var statusLabel: String {
        switch action.status {
        case .running: "выполняется"
        case .awaitingApproval: "ждёт разрешения"
        case .succeeded: "готово"
        case .failed: "ошибка"
        case .denied: "отказано в разрешении"
        case .interrupted: "прервано"
        }
    }
}

struct ActionStatusIcon: View {
    let status: ActionItem.Status

    var body: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .awaitingApproval:
            Image(systemName: "hand.raised")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OrbPalette.teal)
        case .succeeded:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
        case .denied:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .interrupted:
            Image(systemName: "pause.fill")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Пометки

private struct NoticeRow: View {
    let notice: NoticeItem

    var body: some View {
        Text(notice.text)
            .font(.system(size: 12))
            .foregroundStyle(notice.kind == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}
