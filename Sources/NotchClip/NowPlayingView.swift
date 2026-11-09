import SwiftUI

/// Слева в компакте островка: обложка 20 pt со скруглением.
struct NowPlayingCompactLeading: View {
    @ObservedObject var monitor: NowPlayingMonitor

    var body: some View {
        NowPlayingArtwork(image: monitor.artwork, size: 20, radius: 5)
    }
}

/// Справа в компакте островка: три столбика эквалайзера в цвете из настройки "Цвет музыки".
/// На паузе и при "Уменьшить движение" столбики статичны.
struct NowPlayingCompactTrailing: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @AppStorage(AppearanceSettings.accentKey) private var accentHex = AppearanceSettings.accentDefaultHex
    @AppStorage(AppearanceSettings.musicColorKey) private var musicMode = AppearanceSettings.musicColorDefault
    @AppStorage(AppearanceSettings.musicCustomKey) private var musicCustomHex = AppearanceSettings.accentDefaultHex

    private var tint: Color { musicTint(artwork: monitor.tint, mode: musicMode, accentHex: accentHex, customHex: musicCustomHex) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let playing = monitor.status == .playing
        let animated = playing && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !animated)) { context in
            let heights = NowPlayingEqualizer.heights(at: context.date.timeIntervalSinceReferenceDate, playing: animated)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: max(2, 14 * CGFloat(heights[index])))
                }
            }
            .frame(width: 14, height: 14, alignment: .bottom)
        }
    }
}

/// Цвет эквалайзера и прогресса по настройке "Цвет музыки": обложка, акцент или свой цвет.
func musicTint(artwork: RGB8, mode: String, accentHex: String, customHex: String) -> Color {
    switch MusicColorMode(rawValue: mode) ?? .accent {
    case .artwork: return Color(nsColor: artwork.nsColor)
    case .accent: return Color(hex: accentHex)
    case .custom: return Color(hex: customHex)
    }
}

extension Color {
    /// Цвет из сохранённого "#RRGGBB"; испорченное значение даёт акцент по умолчанию.
    init(hex: String) {
        self = Color(nsColor: (RGB8(hex: hex) ?? RGB8.accentDefault).nsColor)
    }
}

/// Мини-плеер ~440×150: обложка 64 pt, название и исполнитель, прогресс, ⏮ ⏯ ⏭.
struct NowPlayingMiniView: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @AppStorage(AppearanceSettings.accentKey) private var accentHex = AppearanceSettings.accentDefaultHex
    @AppStorage(AppearanceSettings.musicColorKey) private var musicMode = AppearanceSettings.musicColorDefault
    @AppStorage(AppearanceSettings.musicCustomKey) private var musicCustomHex = AppearanceSettings.accentDefaultHex

    private var tint: Color { musicTint(artwork: monitor.tint, mode: musicMode, accentHex: accentHex, customHex: musicCustomHex) }
    /// Отступ сверху под вырезом (задаёт островок).
    var contentTop: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            NowPlayingArtwork(image: monitor.artwork, size: 64, radius: 12)
            VStack(alignment: .leading, spacing: 6) {
                titles
                progress
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.top, contentTop + 8)
        .padding(.bottom, 12)
        .frame(width: 440, height: 150, alignment: .topLeading)
        .foregroundStyle(.white)
    }

    private var hasTrack: Bool { monitor.status != .stopped && monitor.snapshot != nil }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hasTrack ? (monitor.snapshot?.title ?? "") : "Ничего не играет")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    private var subtitle: String {
        guard hasTrack, let snapshot = monitor.snapshot else { return "" }
        let artist = snapshot.artist.isEmpty ? snapshot.album : snapshot.artist
        let source = NowPlayingSource.displayName(bundleID: snapshot.bundleID)
        return artist.isEmpty ? source : "\(artist) · \(source)"
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let snapshot = monitor.snapshot
            let now = context.date.timeIntervalSince1970
            let elapsed = snapshot.map { NowPlayingClock.elapsed($0, at: now) } ?? 0
            let duration = snapshot?.duration ?? 0
            VStack(spacing: 3) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule()
                            .fill(tint)
                            .frame(width: geometry.size.width * NowPlayingClock.progress(elapsed: elapsed, duration: duration))
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(NowPlayingClock.format(elapsed))
                    Spacer()
                    Text(duration > 0 ? NowPlayingClock.remaining(elapsed: elapsed, duration: duration) : "")
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 26) {
            transportButton("backward.end.fill", size: 15) { monitor.send(.previous) }
            transportButton(monitor.status == .playing ? "pause.fill" : "playpause.fill", size: 20) { monitor.send(.toggle) }
            transportButton("forward.end.fill", size: 15) { monitor.send(.next) }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .disabled(!hasTrack)
        .opacity(hasTrack ? 1 : 0.4)
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Обложка с заглушкой, если картинки нет.
struct NowPlayingArtwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Полный плеер на вкладке панели.
struct NowPlayingPanelView: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @AppStorage(AppearanceSettings.accentKey) private var accentHex = AppearanceSettings.accentDefaultHex
    @AppStorage(AppearanceSettings.musicColorKey) private var musicMode = AppearanceSettings.musicColorDefault
    @AppStorage(AppearanceSettings.musicCustomKey) private var musicCustomHex = AppearanceSettings.accentDefaultHex
    private var tint: Color { musicTint(artwork: monitor.tint, mode: musicMode, accentHex: accentHex, customHex: musicCustomHex) }
    private var hasTrack: Bool { monitor.status != .stopped && monitor.snapshot != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if hasTrack, let track = monitor.snapshot {
                    NowPlayingArtwork(image: monitor.artwork, size: 120, radius: 18)
                    VStack(spacing: 3) {
                        Text(track.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        Text(track.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        if !track.album.isEmpty { Text(track.album).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                    }
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let elapsed = NowPlayingClock.elapsed(track, at: context.date.timeIntervalSince1970)
                        VStack(spacing: 4) {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.15))
                                    Capsule().fill(tint).frame(width: geometry.size.width * NowPlayingClock.progress(elapsed: elapsed, duration: track.duration))
                                }
                            }.frame(height: 4)
                            HStack {
                                Text(NowPlayingClock.format(elapsed))
                                Spacer()
                                Text(track.duration > 0 ? NowPlayingClock.remaining(elapsed: elapsed, duration: track.duration) : "")
                            }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                        }
                    }.frame(maxWidth: 300)
                    HStack(spacing: 32) {
                        transport("backward.end.fill", label: "Предыдущий", command: .previous)
                        transport(monitor.status == .playing ? "pause.fill" : "play.fill", label: "Пауза или воспроизведение", command: .toggle)
                        transport("forward.end.fill", label: "Следующий", command: .next)
                    }
                    Button("Открыть \(NowPlayingSource.displayName(bundleID: track.bundleID))") { openApp(track.bundleID) }
                        .buttonStyle(.link).foregroundStyle(tint)
                } else {
                    Image(systemName: "music.note").font(.system(size: 38)).foregroundStyle(tint)
                    Text("Сейчас ничего не играет").font(.system(size: 16, weight: .semibold))
                    Button("Открыть Яндекс Музыку") { openApp("ru.yandex.desktop.music") }
                        .buttonStyle(.link).foregroundStyle(tint)
                    if let error = monitor.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
        }
    }

    private func transport(_ symbol: String, label: String, command: NowPlayingCommand) -> some View {
        Button { monitor.send(command) } label: {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).frame(width: 40, height: 36)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
