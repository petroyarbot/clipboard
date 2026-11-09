import AppKit
import SwiftUI

/// Компактная карточка "Сегодня" для вкладки Фокус: время в фокусе и до трёх приложений.
struct DayStatsView: View {
    @ObservedObject var tracker: ActivityTracker
    @ObservedObject var timer: FocusTimer

    @AppStorage(AppearanceSettings.accentKey) private var accentHex = AppearanceSettings.accentDefaultHex

    private var accent: Color { Color(hex: accentHex) }

    var body: some View {
        let stats = tracker.today
        VStack(alignment: .leading, spacing: 8) {
            // Единственный источник сессий и времени — ActivityTracker (addFocus на каждую завершённую фокус-сессию).
            // Точки — прогресс текущего цикла из FocusTimer.focusInCycle.
            HStack(spacing: 8) {
                Text("Сегодня: в фокусе \(ActivityFormat.duration(stats.focusSeconds)) · \(ActivityFormat.sessions(stats.sessions))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    ForEach(0..<FocusTimer.sessionsPerCycle, id: \.self) { index in
                        Circle()
                            .fill(index < timer.focusInCycle ? accent : Color.white.opacity(0.2))
                            .frame(width: 6, height: 6)
                    }
                }
            }

            if stats.topApps.isEmpty {
                Text("Пока нет данных за сегодня")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                let apps = Array(stats.topApps.prefix(3))
                let maxSeconds = apps.map(\.seconds).max() ?? 1
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(apps, id: \.bundleID) { app in
                        appRow(app, maxSeconds: maxSeconds)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: FocusLayoutFramesKey.self, value: [.stats: proxy.frame(in: .named(FocusLayoutCoordinateSpace.name))])
            }
        }
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
                        .fill(accent)
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
