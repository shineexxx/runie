import AppKit
import RunieKit
import SwiftUI

/// Ответ с разметкой: заголовки, списки, код с кнопкой копирования, цитаты, таблицы.
/// Шрифт и цвет берутся из окружения — пузыря в чате или строки в окне.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let value):
            inline(value)
        case .heading(let level, let value):
            inline(value)
                .font(.system(size: level <= 1 ? 17 : level == 2 ? 15.5 : 14.5, weight: .semibold))
                .padding(.top, 4)
        case .listItem(let level, let marker, let value):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(marker == "•" ? AnyShapeStyle(OrbPalette.teal) : AnyShapeStyle(.secondary))
                    .frame(minWidth: 12, alignment: .trailing)
                inline(value)
            }
            .padding(.leading, CGFloat(level) * 16)
        case .code(let language, let value):
            CodeBlockView(language: language, code: value)
        case .quote(let value):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(OrbPalette.teal.opacity(0.7))
                    .frame(width: 3)
                inline(value)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            TableBlockView(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func inline(_ value: String) -> some View {
        Text(MarkdownText.inline(value))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Блок кода: моноширинный, прокручивается вбок, копируется целиком.
private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? String(localized: "код"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: code, label: String(localized: "Скопировать код"))
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.top, 3)

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .fontWeight(.regular)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
                    .padding(.top, 2)
            }
            .scrollIndicators(.hidden)
        }
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Таблица: шапка полужирным, ряды через тонкую линию. Широкая прокручивается вбок.
private struct TableBlockView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownText.inline(cell)).fontWeight(.semibold)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownText.inline(cell))
                        }
                    }
                }
            }
            .font(.system(size: 13))
            .padding(10)
        }
        .scrollIndicators(.hidden)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Кнопка «скопировать»: на мгновение превращается в галочку.
struct CopyButton: View {
    let text: String
    var label = String(localized: "Скопировать")
    var size: CGFloat = 11

    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(copied ? AnyShapeStyle(OrbPalette.teal) : AnyShapeStyle(.secondary))
                .frame(width: size * 2.2, height: size * 2.2)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(copied ? String(localized: "Скопировано") : label)
        .accessibilityLabel(label)
    }
}
