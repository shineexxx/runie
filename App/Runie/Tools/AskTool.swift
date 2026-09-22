import RunieKit
import SwiftUI

// Вопрос человеку с вариантами ответа.
//
// У Claude Code есть свой AskUserQuestion, но он живёт только в интерактивном
// терминале: в режиме `--print`, на котором работает Runie, такого инструмента
// нет вовсе. Поэтому вопрос свой — карточка с кнопками прямо в чате, как
// карточка разрешения или ввода ключа.

/// Ждёт, пока человек выберет ответ. Инструмент стоит всё это время.
@MainActor
@Observable
final class QuestionBroker {

    static let shared = QuestionBroker()

    struct Option: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let detail: String?
    }

    struct Request: Identifiable {
        let id = UUID()
        let question: String
        let options: [Option]
        /// Можно выбрать несколько.
        let multiple: Bool
    }

    private(set) var pending: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<String?, Never>?
    /// Появился вопрос — приложение открывает чат, если он закрыт.
    @ObservationIgnored var onRequest: (() -> Void)?

    /// Ответ человека или `nil`, если он отмахнулся.
    func ask(_ request: Request) async -> String? {
        // Прежний вопрос, на который так и не ответили, считается снятым.
        finish(nil)
        pending = request
        onRequest?()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func answer(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(text.isEmpty ? nil : text)
    }

    func dismiss() {
        finish(nil)
    }

    private func finish(_ answer: String?) {
        pending = nil
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

struct AskUserTool: HostTool {
    let name = "ask_user"
    let description = """
    Задаёт человеку вопрос с готовыми вариантами ответа — он выбирает кнопкой прямо в чате. \
    Бери его, когда без ответа человека дальше идти нельзя: развилка в том, что делать, выбор между \
    подходами, уточнение к расплывчатой просьбе. Не спрашивай о том, что можно посмотреть самому или \
    решить разумным умолчанием, и не переспрашивай уже сказанное. Варианты пиши короткими и \
    различимыми; первым ставь тот, который советуешь.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "question": .object([
                "type": .string("string"),
                "description": .string("Вопрос целиком, по-русски и по делу")
            ]),
            "options": .object([
                "type": .string("array"),
                "description": .string("От двух до четырёх вариантов"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "label": .object(["type": .string("string"), "description": .string("Коротко, 1–4 слова")]),
                        "detail": .object(["type": .string("string"), "description": .string("Что это значит и к чему приведёт")])
                    ]),
                    "required": .array([.string("label")])
                ])
            ]),
            "multiple": .object([
                "type": .string("boolean"),
                "description": .string("Можно выбрать несколько вариантов")
            ])
        ]),
        "required": .array([.string("question"), .string("options")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let question = (arguments["question"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let options = (arguments["options"]?.arrayValue ?? []).compactMap { item -> QuestionBroker.Option? in
            guard let label = item["label"]?.stringValue,
                  !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return QuestionBroker.Option(label: label, detail: item["detail"]?.stringValue)
        }
        guard !question.isEmpty, options.count >= 2 else {
            return HostToolResult("Нужен вопрос и хотя бы два варианта ответа.", isError: true)
        }
        let request = QuestionBroker.Request(
            question: question,
            options: Array(options.prefix(4)),
            multiple: arguments["multiple"]?.boolValue ?? false
        )
        guard let answer = await QuestionBroker.shared.ask(request) else {
            return HostToolResult("Человек не ответил на вопрос. Не переспрашивай: реши сам разумным образом "
                                  + "или скажи, что остановился и ждёшь решения.")
        }
        return HostToolResult("Человек ответил: \(answer)")
    }
}

/// Карточка вопроса: варианты кнопками, плюс поле для своего ответа.
struct QuestionCard: View {

    let request: QuestionBroker.Request
    let broker: QuestionBroker

    @State private var chosen: Set<UUID> = []
    @State private var ownAnswer = ""
    @FocusState private var writingOwn: Bool

    private var chosenLabels: [String] {
        request.options.filter { chosen.contains($0.id) }.map(\.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.question)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(request.options) { option in
                    OptionButton(
                        option: option,
                        isChosen: chosen.contains(option.id),
                        showsCheck: request.multiple
                    ) {
                        pick(option)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Свой ответ", text: $ownAnswer)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($writingOwn)
                    .onSubmit { broker.answer(ownAnswer) }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))

                if request.multiple && !chosen.isEmpty {
                    Button("Готово") { broker.answer(chosenLabels.joined(separator: ", ")) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if !ownAnswer.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Ответить") { broker.answer(ownAnswer) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button("Пропустить") { broker.dismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .readableSurface(RoundedRectangle(cornerRadius: 18))
    }

    private func pick(_ option: QuestionBroker.Option) {
        guard request.multiple else {
            broker.answer(option.label)
            return
        }
        if chosen.contains(option.id) { chosen.remove(option.id) } else { chosen.insert(option.id) }
    }
}

private struct OptionButton: View {
    let option: QuestionBroker.Option
    let isChosen: Bool
    let showsCheck: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showsCheck {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isChosen ? OrbPalette.teal : .secondary)
                        .font(.system(size: 12))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(isChosen ? OrbPalette.teal.opacity(0.16) : Color.primary.opacity(hovering ? 0.08 : 0.04))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
