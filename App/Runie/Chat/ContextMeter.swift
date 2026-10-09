import RunieKit
import SwiftUI

/// Колесо заполненности контекста у поля ввода. Клик — панель с цифрами и
/// кнопкой «Сжать разговор».
struct ContextMeter: View {
    let session: ChatSession
    var size: CGFloat = 16

    @State private var isShowingPanel = false

    private var context: ContextUsage? { session.timeline.context }

    var body: some View {
        Button { isShowingPanel.toggle() } label: {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.14), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: context?.fraction ?? 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: context?.fraction)
            }
            .frame(width: size, height: size)
            .frame(width: 26, height: 26)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("Контекст")
        .accessibilityValue(context.map { "\(Int(($0.fraction * 100).rounded())) %" } ?? "")
        .popover(isPresented: $isShowingPanel, arrowEdge: .top) {
            ContextPanel(session: session) { isShowingPanel = false }
        }
    }

    /// Бирюза, пока места много; ближе к автосжатию — оранжевый, потом красный.
    private var tint: Color {
        guard let context else { return OrbPalette.teal }
        let fraction = context.fraction
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .orange }
        return OrbPalette.azure
    }

    private var helpText: String {
        guard let context else { return String(localized: "Контекст: станет известно после первого ответа") }
        return String(localized: "Контекст: \(ContextPanel.tokens(context.used)) из \(ContextPanel.tokens(context.window))")
    }
}

/// Панель контекста: сколько занято, сколько до автосжатия, и сжать сейчас.
struct ContextPanel: View {
    let session: ChatSession
    let onDone: () -> Void

    var body: some View {
        let context = session.timeline.context
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Контекст")
                    .foregroundStyle(.secondary)
                Spacer()
                if let context {
                    Text("\(Self.tokens(context.used)) / \(Self.tokens(context.window)) (\(Int((context.fraction * 100).rounded())) %)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))

            ProgressView(value: context?.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(OrbPalette.azure)

            HStack {
                Text(statusLine(context))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Сжать разговор") {
                    session.compact()
                    onDone()
                }
                .disabled(session.isBusy || session.timeline.sessionID == nil)
                .help("Руни коротко перескажет себе разговор и продолжит с освободившимся местом")
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func statusLine(_ context: ContextUsage?) -> String {
        if session.timeline.isCompacting { return String(localized: "Сжимаю…") }
        guard let context else { return String(localized: "Станет известно после ответа Руни") }
        return String(localized: "≈ \(Self.tokens(context.untilAutoCompact)) до автосжатия")
    }

    /// «525,4 тыс.», «1 млн» — коротко, как в Claude Code.
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = (Double(count) / 1_000_000).formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "\(millions) млн")
        }
        if count >= 1_000 {
            let thousands = (Double(count) / 1_000).formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "\(thousands) тыс.")
        }
        return "\(count)"
    }
}
