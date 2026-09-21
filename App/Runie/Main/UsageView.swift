import RunieKit
import SwiftUI

/// Лимит подписки Claude, на которой работает Руни.
struct UsageView: View {
    let usage: SubscriptionUsage?

    var body: some View {
        Form {
            Section {
                Text("Руни работает через вашу подписку Claude. У неё два лимита: на ближайшие 5 часов и на неделю. Когда лимит заканчивается, Руни не может отвечать до его сброса.")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            if let usage, !usage.windows.isEmpty {
                Section("Сейчас использовано") {
                    ForEach(usage.windows, id: \.kind) { window in
                        UsageWindowRow(window: window)
                    }
                }
            } else {
                Section {
                    Text("Данные появятся после первого ответа Руни.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandGlowBackground())
        
    }
}

struct UsageWindowRow: View {
    let window: SubscriptionUsage.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(UsageText.windowName(window.kind))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int((window.utilization * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(window.utilization >= 0.8 ? .orange : .primary)
            }
            ProgressView(value: min(max(window.utilization, 0), 1))
                .tint(window.utilization >= 0.8 ? .orange : OrbPalette.teal)
            if let reset = UsageText.reset(window) {
                Text(reset)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

enum UsageText {
    static func windowName(_ kind: String) -> String {
        switch kind {
        case "five_hour": String(localized: "За 5 часов")
        case "seven_day": String(localized: "За неделю")
        case "seven_day_opus": String(localized: "За неделю, Opus")
        case "seven_day_sonnet": String(localized: "За неделю, Sonnet")
        default: kind
        }
    }

    static func reset(_ window: SubscriptionUsage.Window) -> String? {
        guard let date = window.resetsAt else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(localized: "Сброс сегодня в \(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.runie)))")
        }
        if calendar.isDateInTomorrow(date) {
            return String(localized: "Сброс завтра в \(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.runie)))")
        }
        return String(localized: "Сброс \(date.formatted(.dateTime.day().month(.wide).hour().minute().locale(.runie)))")
    }
}
