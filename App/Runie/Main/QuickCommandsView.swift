import RunieKit
import SwiftUI

/// «Мои команды» в настройках навыков: свои инструкции, которые вызываются через
/// `/команда` или сами — когда человек просит похожими словами.
struct QuickCommandsSection: View {
    let model: QuickCommandsModel

    @State private var editing: QuickCommand?
    @State private var pendingRemoval: QuickCommand?

    var body: some View {
        Section {
            if model.commands.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Команд пока нет.")
                    Text("Например: /отчёт — «собери, что я сделал за неделю, по календарю и файлам, и оформи списком».")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(model.commands) { command in
                CommandRow(
                    command: command,
                    onEdit: { editing = command },
                    onRemove: { pendingRemoval = command }
                )
            }
        } header: {
            HStack {
                Text("Мои команды")
                Spacer()
                Button {
                    editing = QuickCommand(title: "", command: "", instructions: "")
                } label: {
                    Label("Добавить…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("Напишите в чате «/» и выберите команду — или просто попросите похожими словами, и Руни вызовет её сам. Команды работают только в Runie.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { command in
            CommandEditor(original: command, model: model)
        }
        .confirmationDialog(
            "Удалить команду?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { command in
            Button("Удалить", role: .destructive) { model.remove(command) }
        } message: { command in
            Text("/\(command.command) — «\(command.title)»")
        }
    }
}

private struct CommandRow: View {
    let command: QuickCommand
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("/\(command.command)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(OrbPalette.teal)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(OrbPalette.teal.opacity(0.12), in: Capsule())
            VStack(alignment: .leading, spacing: 3) {
                Text(command.title).font(.system(size: 13, weight: .semibold))
                let phrases = command.phrases.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                Text(phrases.isEmpty ? String(command.instructions.prefix(120)) : phrases.map { "«\($0)»" }.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Изменить")
            Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Удалить")
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onEdit)
    }
}

private struct CommandEditor: View {
    let original: QuickCommand
    let model: QuickCommandsModel

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var command = ""
    @State private var phrases = ""
    @State private var instructions = ""
    @State private var error: String?

    private var isNew: Bool { original.name.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RunieOrb(mood: .idle, size: 22)
                    .frame(width: 28, height: 28)
                Text(isNew ? "Новая команда" : "Команда /\(original.command)")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }

            Form {
                TextField("Название", text: $title, prompt: Text("Недельный отчёт"))
                HStack(spacing: 2) {
                    TextField("Команда", text: $command, prompt: Text("отчёт"))
                }
                .overlay(alignment: .trailing) {
                    Text("вызов: /\(QuickCommand.normalize(command).isEmpty ? "…" : QuickCommand.normalize(command))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                TextField("Как ещё попросить", text: $phrases, prompt: Text("итоги недели\nчто я сделал за неделю"), axis: .vertical)
                    .lineLimit(2...4)
                    .help("По одной фразе на строку. По ним Руни поймёт, что нужна эта команда, даже без «/».")
            }
            .formStyle(.grouped)
            .frame(height: 200)

            VStack(alignment: .leading, spacing: 6) {
                Text("Что делать")
                    .font(.system(size: 13, weight: .semibold))
                ZStack(alignment: .topLeading) {
                    if instructions.isEmpty {
                        Text("Опишите, как Руни должен выполнять команду: шаги, откуда брать данные, в каком виде ответить. Например: посмотри мой календарь за неделю и файлы на рабочем столе, собери список сделанного по дням, в конце — три главных итога.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(.vertical, 8)
                }
                .frame(minHeight: 160)
                .padding(.horizontal, 6)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }

            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(OrbPalette.deep)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                              || QuickCommand.normalize(command).isEmpty
                              || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            title = original.title
            command = original.command
            phrases = original.phrases.joined(separator: "\n")
            instructions = original.instructions
        }
    }

    private func save() {
        var updated = original
        updated.title = title
        updated.command = command
        updated.phrases = phrases.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        updated.instructions = instructions
        do {
            try model.save(updated, replacing: isNew ? nil : original.name)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Список команд над полем ввода, пока набирается «/…». Щелчок или Tab подставляет.
struct CommandSuggestions: View {
    let matches: [QuickCommand]
    let onPick: (QuickCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(matches.prefix(5)) { command in
                CommandSuggestionRow(command: command, isFirst: command.id == matches.first?.id) { onPick(command) }
            }
        }
        .padding(5)
        .frame(maxWidth: 360)
        .readableSurface(RoundedRectangle(cornerRadius: 18))
    }
}

private struct CommandSuggestionRow: View {
    let command: QuickCommand
    let isFirst: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("/\(command.command)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OrbPalette.teal)
                Text(command.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isFirst {
                    Text("Tab")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
