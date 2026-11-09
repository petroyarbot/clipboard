import AppKit
import SwiftUI

/// Компактная карточка "Сегодня" для вкладки Фокус: время в фокусе и топ-5 приложений.
struct DayStatsView: View {
    @ObservedObject var tracker: ActivityTracker

    /// Акцент фокуса.
    static let accent = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)

    var body: some View {
        let stats = tracker.today
        VStack(alignment: .leading, spacing: 10) {
            Text("Сегодня: в фокусе \(ActivityFormat.duration(stats.focusSeconds)) · \(ActivityFormat.sessions(stats.sessions))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if stats.topApps.isEmpty {
                Text("Пока нет данных за сегодня")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                let maxSeconds = stats.topApps.map(\.seconds).max() ?? 1
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(stats.topApps, id: \.bundleID) { app in
                        appRow(app, maxSeconds: maxSeconds)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func appRow(_ app: AppUsage, maxSeconds: TimeInterval) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.icon(for: app.bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
            Text(app.name)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            GeometryReader { proxy in
                let fraction = maxSeconds > 0 ? app.seconds / maxSeconds : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(Self.accent)
                        .frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text(ActivityFormat.duration(app.seconds))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 64, alignment: .trailing)
        }
    }

    /// Иконка приложения по bundle id; без установленного приложения — общая иконка.
    private static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}
