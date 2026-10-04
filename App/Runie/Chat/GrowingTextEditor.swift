import SwiftUI

/// Поле ввода сообщения: растёт по тексту до `maxLines` строк, дальше
/// прокручивается — и колесом мыши тоже.
///
/// Многострочный `TextField` в macOS колесо не принимает: длинный текст в нём
/// листался только стрелками. Здесь под капотом `TextEditor`, а высоту задаёт
/// невидимая копия текста с тем же шрифтом — до заданного числа строк.
struct GrowingTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 14
    var maxLines = 5
    let isFocused: FocusState<Bool>.Binding
    /// Enter без Shift.
    let onSubmit: () -> Void
    /// Tab: `true` — нажатие обработано.
    var onTab: (() -> Bool)?
    /// ↑: `true` — нажатие обработано, иначе курсор идёт вверх как обычно.
    var onUpArrow: (() -> Bool)?

    /// Отступ строки внутри редактора — тот же у мерки, чтобы переносы совпадали.
    private static let linePadding: CGFloat = 5

    var body: some View {
        Text(measured)
            .font(.system(size: fontSize))
            .lineLimit(1...maxLines)
            .padding(.horizontal, Self.linePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay {
                TextEditor(text: $text)
                    .font(.system(size: fontSize))
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.automatic)
                    .focused(isFocused)
                    // Enter отправляет; Shift+Enter — обычный перенос строки редактора.
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        onSubmit()
                        return .handled
                    }
                    // Табуляция в сообщении не нужна — Tab только подставляет команду.
                    .onKeyPress(.tab) {
                        _ = onTab?()
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        onUpArrow?() == true ? .handled : .ignored
                    }
            }
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, Self.linePadding)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Пустая строка в конце тоже занимает место — иначе после Shift+Enter поле
    /// не вырастет, пока не начнёшь печатать.
    private var measured: String {
        if text.isEmpty { return " " }
        return text.hasSuffix("\n") ? text + " " : text
    }
}
