import AppKit
import Observation
import RunieKit

/// Следит, в каком приложении человек работает.
///
/// Сам Runie в расчёт не берётся: его панели не активируют приложение, так что
/// впереди остаётся то, откуда позвали орб. Но при переключении через Dock или
/// Cmd-Tab Runie может мелькнуть впереди — его активация просто игнорируется.
@MainActor
@Observable
final class FrontmostAppTracker {

    struct Current: Equatable {
        let context: AppContext
        let icon: NSImage

        static func == (lhs: Current, rhs: Current) -> Bool {
            lhs.context == rhs.context
        }
    }

    private(set) var current: Current?

    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        update(with: NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.update(with: app) }
        }
    }

    private func update(with app: NSRunningApplication?) {
        guard let app,
              let bundleIdentifier = app.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }

        current = Current(
            context: AppContext(
                bundleIdentifier: bundleIdentifier,
                name: app.localizedName ?? bundleIdentifier
            ),
            icon: app.icon ?? NSWorkspace.shared.icon(for: .application)
        )
    }
}
