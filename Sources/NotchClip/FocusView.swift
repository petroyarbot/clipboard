import SwiftUI

/// Панель таймера фокуса в стиле таймера из Apple Clock (оригинальная реализация).
struct FocusView: View {
    @ObservedObject var timer: FocusTimer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Быстрые пресеты. Остальные значения задаются в настройках, вкладка "Фокус".
    private let presets = [25, 50, 5, 15]
    private let ringSize: CGFloat = 140
    private let ringWidth: CGFloat = 8
    private let accent = Color.orange

    var body: some View {
        VStack(spacing: 6) {
            ring
            if timer.state == .idle {
                presetRow
            } else {
                Color.clear.frame(height: 22)
            }
            controls
            footer
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Кольцо и время

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: ringWidth)
            Circle()
                .trim(from: 0, to: CGFloat(timer.progress))
                .stroke(accent, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(timer.progress > 0.001 ? 1 : 0)
                .animation(reduceMotion ? nil : .linear(duration: 1), value: timer.progress)

            VStack(spacing: 3) {
                Text(timer.compactText)
                    .font(.system(size: 44, weight: .ultraLight))
                    .monospacedDigit()
                Text(timer.phaseTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                if let endTime = timer.endTimeText {
                    Label(endTime, systemImage: "bell.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: ringSize, height: ringSize)
    }

    // MARK: - Пресеты

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(presets, id: \.self) { minutes in
                chip("\(minutes) мин", selected: timer.focusMinutes == minutes) {
                    timer.setMinutes(minutes, for: .focus)
                }
            }
        }
        .frame(height: 22)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? accent.opacity(0.35) : Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Кнопки

    private var controls: some View {
        HStack(spacing: 40) {
            roundButton(title: "Отмена", fill: Color.white.opacity(0.18)) {
                timer.reset()
            }
            .disabled(timer.state == .idle)
            .opacity(timer.state == .idle ? 0.4 : 1)

            roundButton(title: primaryTitle, fill: primaryTint.opacity(0.9)) {
                timer.toggle()
            }
        }
    }

    private var primaryTitle: String {
        switch timer.state {
        case .idle: return "Старт"
        case .running: return "Пауза"
        case .paused: return "Продолжить"
        }
    }

    private var primaryTint: Color {
        timer.state == .running ? .orange : .green
    }

    private func roundButton(title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Нижняя строка

    private var footer: some View {
        HStack {
            HStack(spacing: 8) {
                Text("Сегодня: \(timer.completedFocusCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 3) {
                    ForEach(0..<FocusTimer.sessionsPerCycle, id: \.self) { index in
                        Circle()
                            .fill(index < timer.focusInCycle ? accent : Color.white.opacity(0.2))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            Spacer()
            Button {
                timer.skip()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Пропустить фазу")
            .accessibilityLabel("Пропустить фазу")
        }
        .frame(height: 18)
    }
}
