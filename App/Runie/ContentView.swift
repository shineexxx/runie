import RunieKit
import SwiftUI

/// Каркасный экран. Единственная его задача на этом шаге — доказать, что приложение
/// собирается, линкуется с RunieKit и видит установленный Claude Code.
struct ContentView: View {

    private enum Status {
        case found(URL)
        case missing([String])
    }

    @State private var status: Status = .missing([])

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Runie")
                .font(.largeTitle.weight(.semibold))
            Text("версия \(Runie.version)")
                .foregroundStyle(.secondary)

            Divider()

            switch status {
            case .found(let url):
                Label("Claude Code найден", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(url.path)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)

            case .missing(let searched):
                Label("Claude Code не найден", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Установите Claude Code и выполните `claude login`.")
                    .foregroundStyle(.secondary)
                if !searched.isEmpty {
                    DisclosureGroup("Где искали (\(searched.count))") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(searched, id: \.self) { path in
                                Text(path).font(.system(.caption2, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { refresh() }
    }

    private func refresh() {
        let locator = ClaudeCodeLocator()
        do {
            status = .found(try locator.locate())
        } catch let ClaudeCodeLocator.Failure.notFound(searched) {
            status = .missing(searched)
        } catch {
            status = .missing([])
        }
    }
}

#Preview {
    ContentView()
}
