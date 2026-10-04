import AppKit
import RunieKit
import SwiftUI

// MARK: - Быстрый вопрос

/// «⚡» у поля ввода: спросить что-то в новом разговоре, не уходя из текущего.
struct QuickAskButton: View {
    let layout: ChatLayout

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { layout.isQuickAskOpen.toggle() }
        } label: {
            Image(systemName: "bolt")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(layout.isQuickAskOpen ? AnyShapeStyle(OrbPalette.teal) : AnyShapeStyle(.primary))
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .readableSurface(Circle(), interactive: true)
        .help("Быстрый вопрос — ответ придёт в новый разговор, а вы останетесь здесь")
        .accessibilityLabel("Быстрый вопрос")
    }
}

/// Тонкое поле только для текста. Enter — вопрос уходит в новый разговор и
/// работает в фоне; Esc — закрыть. Текущий разговор и его черновик не трогаются.
struct QuickAskField: View {
    let session: ChatSession
    let layout: ChatLayout

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OrbPalette.teal)
            TextField("Быстрый вопрос в новом разговоре…", text: Binding(
                get: { layout.quickDraft },
                set: { layout.quickDraft = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($isFocused)
            .onSubmit(send)
            .onKeyPress(.escape) {
                close()
                return .handled
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .frame(maxWidth: 420)
        .readableSurface(Capsule(), interactive: true)
        .holdsPointer()
        .onAppear { isFocused = true }
        .onChange(of: layout.focusGeneration) { isFocused = true }
    }

    private func send() {
        guard session.sendInBackground(layout.quickDraft) != nil else { return }
        RunieSounds.shared.play(.send)
        layout.quickDraft = ""
        // Позвали сочетанием из другого приложения — чат возвращается в орб.
        if layout.quickAskReturnsToOrb {
            layout.isQuickAskOpen = false
            layout.hideChat?()
            return
        }
        close()
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { layout.isQuickAskOpen = false }
        layout.requestFocus()
    }
}

// MARK: - Готовый ответ

/// Разговор доработал в фоне — короткая карточка с началом ответа.
struct BackgroundNotice: Identifiable, Equatable {
    let id: UUID
    let title: String
    let preview: String
    let failed: Bool

    init(_ result: ChatSession.BackgroundResult) {
        id = result.conversationID
        title = result.title
        failed = result.failed
        let text = (result.reply ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        preview = result.failed
            ? String(localized: "Не получилось — откройте, чтобы посмотреть")
            : String(text.prefix(160))
    }
}

struct BackgroundNoticeCard: View {
    let notice: BackgroundNotice
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(notice.failed ? AnyShapeStyle(.orange) : AnyShapeStyle(OrbPalette.teal))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !notice.preview.isEmpty {
                    Text(notice.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Скрыть")
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .readableSurface(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
        .holdsPointer()
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .help("Открыть разговор")
    }
}

/// Карточки готовых ответов возле орба, пока чат закрыт.
@MainActor
final class NoticePanelController {

    private let panel = FloatingPanel(size: NSSize(width: 400, height: 120), allowsKey: false)
    private let layout: ChatLayout
    private var hosting: NSHostingView<NoticeStack>?
    /// Открыть разговор из карточки — это делает приложение: ему же открывать чат.
    var onOpen: ((UUID) -> Void)?
    /// Поле вокруг карточек под их тень.
    private static let margin: CGFloat = 24

    init(layout: ChatLayout) {
        self.layout = layout
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        let hosting = NSHostingView(rootView: NoticeStack(
            layout: layout,
            onOpen: { [weak self] id in self?.onOpen?(id) },
            onChange: { [weak self] in self?.refresh() }
        ))
        self.hosting = hosting
        panel.contentView = hosting
    }

    private var anchor: NSRect = .zero

    /// Показать рядом с орбом — со стороны центра экрана.
    func show(near orb: NSRect) {
        anchor = orb
        refresh()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func refresh() {
        guard !layout.notices.isEmpty, let hosting else {
            hide()
            return
        }
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        let towardLeft = center.x > visible.midX
        var x = towardLeft ? center.x - 36 - size.width + Self.margin : center.x + 36 - Self.margin
        x = min(max(x, visible.minX), visible.maxX - size.width)
        var y = center.y - size.height / 2
        y = min(max(y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}

struct NoticeStack: View {
    let layout: ChatLayout
    let onOpen: (UUID) -> Void
    let onChange: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(layout.notices) { notice in
                BackgroundNoticeCard(
                    notice: notice,
                    onOpen: { onOpen(notice.id) },
                    onDismiss: {
                        layout.notices.removeAll { $0.id == notice.id }
                        onChange()
                    }
                )
            }
        }
        .padding(24)
        .fixedSize()
    }
}
