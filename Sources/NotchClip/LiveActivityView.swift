import SwiftUI

/// Закрытый островок: компакт по бокам от выреза, мини-плеер при наведении и баннер окончания фазы.
struct LiveIslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var timer: FocusTimer
    @ObservedObject var music: NowPlayingMonitor
    var onTap: () -> Void
    var onStartNext: () -> Void

    private static let accent = Color.orange
    private static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)

    var body: some View {
        let layout = model.layout
        let shape = NotchShape(bottomRadius: layout.bottomRadius)
        ZStack(alignment: .top) {
            compact
                .modifier(IslandReveal(visible: isCompact))
            mini
                .modifier(IslandReveal(visible: model.presentation == .miniPlayer))
            NowPlayingMiniView(monitor: music, contentTop: model.layout.contentTop)
                .modifier(IslandReveal(visible: model.presentation == .musicPlayer))
            Text(model.toast ?? "").font(.system(size: 14, weight: .semibold))
                .padding(.top, model.layout.contentTop)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(IslandReveal(visible: model.presentation == .toast))
            banner
                .modifier(IslandReveal(visible: model.presentation == .banner))
        }
        .frame(width: layout.width, height: layout.height, alignment: .top)
        .background(shape.fill(Color.black).opacity(model.presentation == .idle ? 0 : 1))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture {
            if model.presentation != .idle && model.presentation != .banner { onTap() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, model.topOffset)
        .foregroundStyle(.white)
    }

    // MARK: - Что показываем

    private var isCompact: Bool {
        model.presentation == .compactTimer || model.presentation == .compactAgent || model.presentation == .compactBoth || model.presentation == .compactMusic
    }

    /// "4:44" до часа, "1:02:05" от часа (форматирует `FocusTimer.compactText`).
    private var clock: String { timer.compactText }

    private var showsTimer: Bool {
        model.presentation == .compactTimer || model.presentation == .compactBoth
    }

    private var showsAgent: Bool {
        (model.presentation == .compactAgent || model.presentation == .compactBoth) && model.agent != nil
    }

    // MARK: - Компакт: слева и справа от выреза

    private var compact: some View {
        HStack(spacing: 0) {
            leftWing
                .padding(.leading, IslandState.wingEdgePadding)
                .frame(width: model.layout.wing, alignment: .leading)
            Color.clear.frame(width: model.notchWidth)
            rightWing
                .padding(.trailing, IslandState.wingEdgePadding)
                .frame(width: model.layout.wing, alignment: .trailing)
        }
        .frame(height: model.notchHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var leftWing: some View {
        if model.presentation == .compactMusic {
            NowPlayingCompactLeading(monitor: music)
        } else if showsTimer {
            HStack(spacing: 5) {
                ring(size: 15, line: 2.2)
                if showsAgent {
                    timeText(size: 11)
                } else {
                    Text(timer.phase == .focus ? "Фокус" : "Перерыв")
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        } else if showsAgent, let agent = model.agent {
            HStack(spacing: 5) {
                badge(agent.source)
                Text(agent.project)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder private var rightWing: some View {
        if model.presentation == .compactMusic {
            NowPlayingCompactTrailing(monitor: music)
        } else if showsAgent, let agent = model.agent {
            HStack(spacing: 4) {
                if showsTimer { badge(agent.source) }
                PulseDot()
                Text(showsTimer ? "\(agent.count)" : "ждёт")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.accent)
            }
        } else if showsTimer {
            timeText(size: 13)
        }
    }

    private func timeText(size: CGFloat) -> some View {
        let paused = timer.state == .paused
        return HStack(spacing: 3) {
            if paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(Self.accent.opacity(0.7))
            }
            Text(clock)
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Self.accent.opacity(paused ? 0.5 : 1))
        }
    }

    private func ring(size: CGFloat, line: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: line)
            Circle()
                .trim(from: 0, to: CGFloat(timer.progress))
                .stroke(Self.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }

    private func badge(_ source: String) -> some View {
        let codex = source == "codex"
        return Text(source == "assistant" ? "AI" : (codex ? "CX" : "CL"))
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(codex ? Color.black : Color.white)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(Capsule().fill(codex ? Color(white: 0.9) : Self.claude))
    }

    // MARK: - Мини-плеер

    private var mini: some View {
        HStack(spacing: 18) {
            ring(size: 72, line: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(clock)
                    .font(.system(size: 38, weight: .light))
                    .monospacedDigit()
                    .opacity(timer.state == .paused ? 0.55 : 1)
                Text(miniSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                controlButton("+5") { timer.addTime(5 * 60) }
                controlButton(symbol: timer.state == .running ? "pause.fill" : "play.fill",
                              fill: timer.state == .running ? Self.accent.opacity(0.9) : Color.green.opacity(0.9)) {
                    timer.toggle()
                }
                controlButton(symbol: "forward.end.fill") { timer.skip() }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, model.layout.contentTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var miniSubtitle: String {
        var parts = [timer.phaseTitle]
        if timer.phase == .focus {
            parts.append("\(min(timer.focusInCycle + 1, FocusTimer.sessionsPerCycle)) из \(FocusTimer.sessionsPerCycle)")
        }
        parts.append(timer.endTimeText.map { "до \($0)" } ?? "на паузе")
        if model.released > 0 { parts.append(IslandState.agentsFinishedText(model.released)) }
        return parts.joined(separator: " · ")
    }

    private func controlButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func controlButton(symbol: String, fill: Color = Color.white.opacity(0.16), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Баннер окончания фазы

    private var banner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.banner.map { IslandState.bannerTitle(finished: $0.finished) } ?? "")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.banner.map { IslandState.bannerSubtitle($0) } ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onStartNext) {
                Text(model.banner.map { IslandState.nextButtonTitle(next: $0.next) } ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.green))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, model.layout.contentTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Точка, которая мигает раз в секунду. Таймер-лента тикает только пока точка на экране.
private struct PulseDot: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lit = Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .opacity(lit ? 1 : 0.25)
        }
    }
}
