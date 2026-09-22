import AppKit
import RunieKit
import SwiftUI

/// Приглашение включить индекс: чем он полезен и как дать полный доступ к диску.
///
/// Разрешение большое, поэтому окно сначала объясняет, что Руни станет уметь и
/// куда попадут данные, и только потом показывает, где его включить. Никто ничего
/// не индексирует, пока человек не согласится.
struct IndexIntroView: View {

    let model: IndexIntroModel

    var body: some View {
        ZStack {
            BrandGlowBackground()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        benefits
                        honesty
                        grant
                    }
                    .padding(.horizontal, 38)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
                // Кнопки не уезжают вместе с текстом: на невысоком экране
                // человек иначе просто не увидит, что нажимать.
                actions
                    .padding(.horizontal, 38)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .background(.background)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            RunieOrb(mood: .thinking, size: 46)
                .frame(width: 46, height: 46)
                .padding(.bottom, -6)
            Text("Пусть Руни знает ваш Mac")
                .font(.system(size: 26, weight: .semibold))
            Text("Руни составит свой указатель: какие у вас файлы, о чём письма, что в заметках и фотографиях. Дальше он ищет по смыслу — не по имени файла и не по точному слову.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            Benefit(
                symbol: "text.magnifyingglass",
                title: String(localized: "Находит по описанию"),
                detail: String(localized: "«Та таблица с бюджетом, которую присылал Саша весной» — Руни найдёт и письмо, и вложение, даже если файл называется final2.xlsx.")
            )
            Benefit(
                symbol: "point.3.filled.connected.trianglepath.dotted",
                title: String(localized: "Связывает разное"),
                detail: String(localized: "Встреча в календаре, переписка по ней и файлы, которые к ней готовили, — для Руни это одна история, а не три разных места.")
            )
            Benefit(
                symbol: "bolt",
                title: String(localized: "Отвечает сразу"),
                detail: String(localized: "Указатель лежит на вашем Mac и обновляется сам, поэтому поиск идёт мгновенно и работает без интернета.")
            )
        }
    }

    private var honesty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Что происходит с данными")
                    .font(.system(size: 13, weight: .medium))
            } icon: {
                Image(systemName: "lock")
                    .foregroundStyle(OrbPalette.teal)
            }
            Text("Указатель целиком лежит у вас на Mac, Руни никуда его не отправляет. Но когда вы о чём-то спрашиваете, найденные куски уходят в Claude вместе с вопросом — иначе он не сможет ответить. Каждый источник включается отдельно, а весь указатель удаляется одной кнопкой.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var grant: some View {
        switch model.state {
        case .needsAccess:
            VStack(alignment: .leading, spacing: 14) {
                Text("Нужен доступ к диску")
                    .font(.system(size: 15, weight: .semibold))
                Text("Почта, Сообщения и заметки лежат в защищённых папках — без разрешения их не прочитать никому, включая Руни. Найдите Runie в списке и включите переключатель.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsIllustration()
            }
        case .needsRestart:
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Доступ выдан").font(.system(size: 15, weight: .semibold))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(OrbPalette.teal)
                }
                Text("macOS применяет такие разрешения при запуске, поэтому Руни нужно перезапустить. После этого он начнёт собирать указатель в фоне — первый раз это занимает несколько минут.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ready:
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Всё на месте").font(.system(size: 15, weight: .semibold))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(OrbPalette.teal)
                }
                Text("Доступ есть, и Руни уже собирает указатель: файлы, почту и заметки. Что именно собирать, можно поменять в настройках, а весь указатель — удалить одной кнопкой.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Панель внизу окна: то, что человек должен нажать.
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .needsAccess:
                Button("Открыть настройки") { model.openSettings() }
                    .buttonStyle(IndexButtonStyle(primary: true))
                Button("Не сейчас") { model.dismiss() }
                    .buttonStyle(IndexButtonStyle(primary: false))
                if model.isWatching {
                    ProgressView().controlSize(.small)
                    Text("Жду разрешения…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .needsRestart:
                Button("Перезапустить Руни") { model.restart() }
                    .buttonStyle(IndexButtonStyle(primary: true))
                Button("Позже") { model.dismiss() }
                    .buttonStyle(IndexButtonStyle(primary: false))
            case .ready:
                Button("Понятно") { model.dismiss() }
                    .buttonStyle(IndexButtonStyle(primary: true))
            }
        }
    }
}

/// Одно преимущество: значок, заголовок, объяснение человеческими словами.
private struct Benefit: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OrbPalette.teal)
                .frame(width: 26, height: 26)
                .background(OrbPalette.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Как выглядит нужный экран настроек — нарисовано, а не снято: так картинка
/// подходит к любому языку и к тёмной теме, и в кадр не попадают чужие программы.
private struct SettingsIllustration: View {
    @State private var enabled = false

    private struct Row: Identifiable {
        let id = UUID()
        let symbol: String
        let name: String
        let isRunie: Bool
    }

    private let rows = [
        Row(symbol: "terminal", name: "Terminal", isRunie: false),
        Row(symbol: "circle.dashed", name: "Runie", isRunie: true),
        Row(symbol: "externaldrive", name: "Time Machine", isRunie: false)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 9, height: 9)
                }
                Spacer()
                Text("Конфиденциальность и безопасность")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 40, height: 1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.5))

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(OrbPalette.azure)
                    Text("Доступ к диску")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)

                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(row.isRunie ? OrbPalette.teal : .secondary)
                            .frame(width: 16)
                        Text(row.name)
                            .font(.system(size: 11, weight: row.isRunie ? .semibold : .regular))
                        Spacer()
                        Switch(isOn: row.isRunie ? enabled : false, highlighted: row.isRunie)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background {
                        if row.isRunie {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(OrbPalette.teal.opacity(enabled ? 0.10 : 0.16))
                                .padding(.horizontal, 6)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .frame(maxWidth: 340)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .onAppear {
            // Переключатель включается сам — видно, что именно нужно сделать.
            withAnimation(.easeInOut(duration: 0.5).delay(0.9).repeatForever(autoreverses: true)) {
                enabled = true
            }
        }
        .accessibilityLabel(Text("Настройки macOS: «Доступ к диску», переключатель напротив Runie"))
    }

    /// Нарисованный переключатель: настоящий Toggle здесь нажимался бы.
    private struct Switch: View {
        let isOn: Bool
        let highlighted: Bool

        var body: some View {
            Capsule()
                .fill(isOn ? OrbPalette.teal : Color.secondary.opacity(0.28))
                .frame(width: 26, height: 15)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .padding(1.5)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                }
                .opacity(highlighted ? 1 : 0.55)
        }
    }
}

/// Кнопки окна: как в знакомстве — главная залита бирюзой, вторая прозрачная.
private struct IndexButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(primary ? .white : .primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                if primary {
                    Capsule().fill(OrbPalette.teal)
                } else {
                    Capsule().fill(.quaternary.opacity(0.5))
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
