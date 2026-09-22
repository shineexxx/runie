import RunieKit
import SwiftUI

// Фирменные элементы окна Runie: живой орб, бирюзовое свечение, акценты.
// Цвета берутся из палитры времени суток — окно меняется вместе с орбом.

/// Мягкое свечение в цветах орба под содержимым окна. Едва заметное: окно
/// остаётся спокойным, но не голым.
struct BrandGlowBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Circle()
                    .fill(OrbPalette.cyan.opacity(0.16))
                    .frame(width: size.width * 0.7, height: size.width * 0.7)
                    .position(x: size.width * 0.92, y: -size.height * 0.05)
                Circle()
                    .fill(OrbPalette.azure.opacity(0.12))
                    .frame(width: size.width * 0.6, height: size.width * 0.6)
                    .position(x: size.width * 0.05, y: size.height * 1.02)
                Circle()
                    .fill(OrbPalette.mint.opacity(0.06))
                    .frame(width: size.width * 0.4, height: size.width * 0.4)
                    .position(x: size.width * 0.55, y: size.height * 0.55)
            }
            .blur(radius: 90)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Шапка боковой панели: живой орб, имя и чем Руни занят.
struct SidebarBrandHeader: View {
    let session: ChatSession

    var body: some View {
        HStack(spacing: 10) {
            RunieOrb(mood: RunieMood(activity: session.timeline.activity), size: 24)
                .frame(width: 30, height: 30)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                Text("Runie")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(session.isBusy ? AnyShapeStyle(OrbPalette.teal) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var status: String {
        session.isBusy ? ActivityLabel.text(session.timeline.activity) : String(localized: "Готов помочь")
    }
}

/// Пустой разговор: большой живой орб и приветствие.
struct BrandEmptyState: View {
    let title: String
    let subtitle: String
    var mood: RunieMood = .idle

    var body: some View {
        VStack(spacing: 18) {
            RunieOrb(mood: mood, size: 64)
                .frame(width: 96, height: 96)
                .allowsHitTesting(false)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PermissionCategory {
    /// Значок группы в настройках разрешений.
    var symbol: String {
        switch self {
        case .readFiles: "doc.text"
        case .browseFolders: "folder"
        case .systemInfo: "desktopcomputer"
        case .editFiles: "square.and.pencil"
        case .moveDelete: "trash"
        case .openApps: "arrow.up.forward.app"
        case .internet: "globe"
        case .automation: "wand.and.stars"
        case .install: "shippingbox"
        case .sharing: "paperplane"
        case .contacts: "person.crop.circle"
        case .calendarRead: "calendar"
        case .calendarEdit: "calendar.badge.plus"
        case .browserRead: "safari"
        case .browserControl: "cursorarrow.click"
        case .pageScript: "curlybraces"
        case .extendRunie: "wand.and.sparkles"
        case .memory: "brain"
        case .services: "puzzlepiece.extension"
        case .otherCommands: "terminal"
        }
    }
}
