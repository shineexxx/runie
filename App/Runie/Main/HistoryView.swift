import RunieKit
import SwiftUI

/// Переписка выбранного разговора.
struct ConversationDetail: View {
    let record: ConversationRecord
    let onContinue: (ConversationRecord) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(record.items) { item in
                        TimelineRow(item: item)
                    }
                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .id(record.id)

            Divider()
            HStack {
                Text(record.updatedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(.runie)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Удалить…", role: .destructive, action: onDelete)
                Button("Продолжить в Руни") { onContinue(record) }
                    .buttonStyle(.borderedProminent)
                    .tint(OrbPalette.deep)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .navigationTitle(record.title)
    }
}
