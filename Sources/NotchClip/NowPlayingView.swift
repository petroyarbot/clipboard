import SwiftUI

/// Слева в компакте островка: обложка 20 pt со скруглением.
struct NowPlayingCompactLeading: View {
    @ObservedObject var monitor: NowPlayingMonitor

    var body: some View {
        NowPlayingArtwork(image: monitor.artwork, size: 20, radius: 5)
    }
}

/// Справа в компакте островка: три столбика эквалайзера в цвете обложки.
/// На паузе и при "Уменьшить движение" столбики статичны.
struct NowPlayingCompactTrailing: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let playing = monitor.status == .playing
        let animated = playing && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !animated)) { context in
            let heights = NowPlayingEqualizer.heights(at: context.date.timeIntervalSinceReferenceDate, playing: animated)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Color(nsColor: monitor.tint.nsColor))
                        .frame(width: 3, height: max(2, 14 * CGFloat(heights[index])))
                }
            }
            .frame(width: 14, height: 14, alignment: .bottom)
        }
    }
}

/// Мини-плеер ~440×150: обложка 64 pt, название и исполнитель, прогресс, ⏮ ⏯ ⏭.
struct NowPlayingMiniView: View {
    @ObservedObject var monitor: NowPlayingMonitor
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
                            .fill(Color(nsColor: monitor.tint.nsColor))
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
