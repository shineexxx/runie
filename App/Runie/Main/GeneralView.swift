import RunieKit
import SwiftUI

struct GeneralView: View {
    let settings: AppSettings

    private let claudePath = try? ClaudeCodeLocator().locate().path
    private let updater = UpdaterModel.shared
    @AppStorage(MorningBriefing.enabledKey) private var briefingEnabled = true

    private var lastCheck: String {
        guard let date = updater.lastCheck else { return String(localized: "Ещё не проверяли") }
        return String(localized: "Последняя проверка: ") + date.formatted(.dateTime.day().month().hour().minute().locale(.runie))
    }

    var body: some View {
        Form {
            Section("Руни") {
                LabeledContent("Версия", value: Runie.version)
                LabeledContent("Как вызвать", value: String(localized: "Нажмите на орб у края экрана"))
            }
            Section("Язык") {
                Picker(selection: Binding(get: { settings.answerLanguage }, set: { settings.answerLanguage = $0 })) {
                    Text("Как в системе").tag(AnswerLanguage.system)
                    Text("Русский").tag(AnswerLanguage.russian)
                    Text("English").tag(AnswerLanguage.english)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Язык ответов")
                        Text("На этом языке Руни отвечает, придумывает подсказки и пишет даты. Язык интерфейса берётся из настроек macOS.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
            }
            Section("Обновления") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(updater.status ?? String(localized: "Runie обновляется сам"))
                        Text(lastCheck)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Проверить сейчас") { updater.check() }
                        .disabled(!updater.canCheck)
                }
                Toggle(isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Проверять обновления автоматически")
                        Text("Раз в сутки Runie заглядывает на GitHub и предлагает поставить новую версию. Каждый выпуск подписан ключом автора.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Claude Code") {
                if let claudePath {
                    LabeledContent("Найден", value: claudePath)
                } else {
                    Text("Claude Code не найден. Установите его и выполните в терминале `claude login`.")
                        .foregroundStyle(.orange)
                }
            }
            Section("Утренний разбор дня") {
                Toggle(isOn: $briefingEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Звать разобрать день по утрам")
                        Text("Когда утром вы впервые открываете Mac, орб выходит из-за края, а в чате первой подсказкой стоит «Разобрать день»: встречи, напоминания и свободные окна. Раз в день.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Индекс") {
                IndexRows()
            }
            Section("Память") {
                MemoryModelRow()
            }
            Section("История") {
                LabeledContent("Где хранится", value: "~/Library/Application Support/Runie")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandGlowBackground())
        
    }
}

/// Модель смыслового поиска: скачать, показать ход загрузки, удалить.
private struct MemoryModelRow: View {
    private let installer = MemoryModelInstaller.shared

    private var size: String {
        Measurement(value: Double(MemoryModelInstaller.downloadSize), unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .file).locale(.runie))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Искать по смыслу, а не только по словам")
                    Text("Руни запоминает факты о вас в папке «Документы → Runie → Memory». Со скачанной моделью он найдёт нужное, даже если вы спросите другими словами: «правило про картинки» приведёт к записи про скриншоты. Модель работает на вашем Mac, ничего никуда не отправляет.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch installer.state {
                case .absent, .failed:
                    Button("Скачать \(size)") { installer.install() }
                case .downloading:
                    Button("Отменить") { installer.cancel() }
                case .ready:
                    Button("Удалить") { installer.remove() }
                }
            }
            switch installer.state {
            case .downloading(let progress):
                ProgressView(value: progress)
            case .failed(let reason):
                Text(reason).font(.system(size: 11)).foregroundStyle(.orange)
            case .ready:
                Text("Модель на месте — поиск по памяти понимает смысл.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .absent:
                EmptyView()
            }
        }
    }
}

/// Указатель: что включено, сколько собрано и можно ли всё стереть.
private struct IndexRows: View {
    private let index = IndexModel.shared

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Знать ваши файлы, почту и заметки")
                Text("Руни составит свой указатель и будет искать по нему — по смыслу, а не по имени файла. Указатель лежит на вашем Mac; каждый источник включается отдельно.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Подробнее…") { IndexIntroWindowController.shared.show() }
        }

        ForEach(IndexStore.Source.allCases, id: \.self) { source in
            Toggle(isOn: Binding(
                get: { index.enabled.contains(source) },
                set: { index.setEnabled(source, $0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title)
                    Text(status(for: source))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!isAvailable(source))
        }

        if let failure = index.failure {
            Text(failure).font(.system(size: 11)).foregroundStyle(.orange)
        }
        if index.hasAnything {
            HStack {
                Text("Удалить указатель целиком")
                Spacer()
                Button("Удалить", role: .destructive) { index.removeEverything() }
            }
        }
    }

    /// Источники, для которых сборщик уже написан.
    private func isAvailable(_ source: IndexStore.Source) -> Bool {
        source == .files || source == .notes || source == .mail
    }

    private func status(for source: IndexStore.Source) -> String {
        if let scanning = index.scanning, scanning.source == source {
            return String(localized: "Собираю… \(scanning.done)")
        }
        guard isAvailable(source) else { return String(localized: "Пока не собирается") }
        let count = index.counts[source] ?? 0
        guard count > 0 else {
            return switch source {
            case .files: String(localized: "Документы, заметки и тексты из ваших папок")
            case .notes: String(localized: "Ваши заметки; Руни читает их, когда Заметки открыты")
            case .mail: MailCollector().canReadFiles
                ? String(localized: "Все письма из Почты")
                : String(localized: "Без доступа к диску — только последние письма, и когда Почта открыта")
            default: String(localized: "Ничего не собрано")
            }
        }
        return String(localized: "В указателе: \(count)")
    }
}
