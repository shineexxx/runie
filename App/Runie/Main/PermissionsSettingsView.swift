import RunieKit
import SwiftUI

/// Какие действия Руни выполняет без вопроса.
struct PermissionsSettingsView: View {
    let settings: AppSettings

    private static let safe: [PermissionCategory] = [.readFiles, .browseFolders, .systemInfo]

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Прежде чем что-то сделать на Mac, Руни спрашивает разрешения. Здесь можно разрешить частые действия заранее — тогда вопроса не будет.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Разрешить безопасное") {
                            for category in Self.safe { settings.setRule(.allow, for: category) }
                        }
                        .help("Чтение файлов, просмотр папок и сведения о системе — это ничего не меняет")
                        Button("Спрашивать обо всём") {
                            for category in PermissionCategory.allCases { settings.setRule(.ask, for: category) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Ничего не меняют") {
                ForEach(PermissionCategory.allCases.filter { !$0.isRisky }) { category in
                    CategoryRow(category: category, settings: settings)
                }
            }

            Section {
                ForEach(PermissionCategory.allCases.filter(\.isRisky)) { category in
                    CategoryRow(category: category, settings: settings)
                }
            } header: {
                Text("Меняют файлы, систему или выходят в интернет")
            } footer: {
                Text("Если команда затрагивает несколько групп — например, находит файлы и удаляет их, — Руни выполнит её без вопроса, только если разрешены все эти группы. Команды, которые не удаётся разобрать, всегда попадают в «Прочие команды».")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        
    }
}

private struct CategoryRow: View {
    let category: PermissionCategory
    let settings: AppSettings

    @State private var showsExamples = false

    var body: some View {
        let rule = settings.policy.rule(for: category)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(category.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker(category.title, selection: Binding(
                    get: { rule },
                    set: { settings.setRule($0, for: category) }
                )) {
                    Text("Спрашивать").tag(PermissionPolicy.Rule.ask)
                    Text("Разрешать").tag(PermissionPolicy.Rule.allow)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if category.isRisky, rule == .allow {
                Label("Руни будет делать это без вопроса", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }

            if !category.examples.isEmpty {
                DisclosureGroup(isExpanded: $showsExamples) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(category.examples, id: \.command) { example in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(example.meaning.prefix(1).uppercased() + example.meaning.dropFirst())
                                    .font(.system(size: 12))
                                Spacer(minLength: 8)
                                Text(example.command)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Что сюда входит")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
