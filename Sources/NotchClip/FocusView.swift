import AppKit
import SwiftUI

/// Панель таймера фокуса в стиле таймера из Apple Clock (оригинальная реализация).
/// В покое — колёсики часов/минут/секунд; во время работы — кольцо с обратным отсчётом.
struct FocusView: View {
    @ObservedObject var timer: FocusTimer
    @ObservedObject var tracker: ActivityTracker
    @AppStorage(FocusView.recentsKey) private var recentsText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let recentsKey = "focusTimer.recentSeconds"
    private let ringSize: CGFloat = 140
    private let ringWidth: CGFloat = 8
    @AppStorage(AppearanceSettings.accentKey) private var accentHex = AppearanceSettings.accentDefaultHex

    var body: some View {
        VStack(spacing: 12) {
            if timer.state == .idle {
                TimeWheelPicker(totalSeconds: pickBinding)
            } else {
                ring
            }
            if timer.state == .idle { recentRow }
            controls
            footer
            DayStatsView(tracker: tracker, timer: timer)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: FocusLayoutCoordinateSpace.name)
    }

    private var accent: Color { Color(hex: accentHex) }

    private var pickBinding: Binding<Int> {
        Binding(get: { timer.focusSeconds }, set: { timer.setFocusSeconds($0) })
    }

    private var recents: [Int] {
        TimeWheelMath.decodeRecents(recentsText)
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

    // MARK: - Недавние

    @ViewBuilder
    private var recentRow: some View {
        if recents.isEmpty {
            Color.clear.frame(height: 22)
        } else {
            HStack(spacing: 6) {
                Text("Недавние")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                ForEach(recents, id: \.self) { seconds in
                    chip(TimeWheelMath.durationTitle(seconds), selected: timer.focusSeconds == seconds) {
                        timer.setFocusSeconds(seconds)
                    }
                }
            }
            .frame(height: 22)
        }
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
                primaryTapped()
            }
            .disabled(startDisabled)
            .opacity(startDisabled ? 0.4 : 1)
        }
    }

    /// 0:00:00 не запускается; переходы между фазами при этом не блокируются.
    private var startDisabled: Bool {
        timer.state == .idle && timer.phase == .focus && timer.focusSeconds == 0
    }

    private func primaryTapped() {
        if timer.state == .idle, timer.phase == .focus {
            recentsText = TimeWheelMath.encodeRecents(
                TimeWheelMath.updatedRecents(recents, adding: timer.focusSeconds)
            )
        }
        timer.toggle()
    }

    private var primaryTitle: String {
        switch timer.state {
        case .idle: return "Старт"
        case .running: return "Пауза"
        case .paused: return "Продолжить"
        }
    }

    private var primaryTint: Color {
        timer.state == .running ? accent : .green
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

// MARK: - Вид

/// Три колеса: часы 0–23, минуты 0–59, секунды 0–59. Значение — общее число секунд.
struct TimeWheelPicker: View {
    @Binding var totalSeconds: Int
    static let rowHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            column(count: 24, unit: "ч", part: .hours)
            column(count: 60, unit: "мин", part: .minutes)
            column(count: 60, unit: "с", part: .seconds)
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .frame(height: Self.rowHeight)
        }
        .frame(height: Self.rowHeight * 5)
        .clipped()
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: FocusLayoutFramesKey.self, value: [.wheel: proxy.frame(in: .named(FocusLayoutCoordinateSpace.name))])
            }
        }
    }

    private enum Part { case hours, minutes, seconds }

    private func column(count: Int, unit: String, part: Part) -> some View {
        TimeWheelColumn(
            count: count,
            value: Binding(
                get: {
                    let parts = TimeWheelMath.components(totalSeconds)
                    switch part {
                    case .hours: return parts.hours
                    case .minutes: return parts.minutes
                    case .seconds: return parts.seconds
                    }
                },
                set: { newValue in
                    let parts = TimeWheelMath.components(totalSeconds)
                    switch part {
                    case .hours:
                        totalSeconds = TimeWheelMath.totalSeconds(hours: newValue, minutes: parts.minutes, seconds: parts.seconds)
                    case .minutes:
                        totalSeconds = TimeWheelMath.totalSeconds(hours: parts.hours, minutes: newValue, seconds: parts.seconds)
                    case .seconds:
                        totalSeconds = TimeWheelMath.totalSeconds(hours: parts.hours, minutes: parts.minutes, seconds: newValue)
                    }
                }
            ),
            unit: unit,
            rowHeight: Self.rowHeight
        )
    }
}

enum FocusLayoutCoordinateSpace {
    static let name = "focus-layout"
}

enum FocusLayoutElement: Hashable { case wheel, stats }

struct FocusLayoutFramesKey: PreferenceKey {
    static var defaultValue: [FocusLayoutElement: CGRect] = [:]
    static func reduce(value: inout [FocusLayoutElement: CGRect], nextValue: () -> [FocusLayoutElement: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Непрокрученная позиция — nil: тогда колесо стоит на значении привязки.
private final class WheelPosition: ObservableObject {
    @Published var stored: Double?
}

/// Одно колесо. Перерисовка только при прокрутке.
private struct TimeWheelColumn: View {
    let count: Int
    @Binding var value: Int
    let unit: String
    let rowHeight: CGFloat

    /// Позиция хранится в объекте, а не в @State: макрос @State недоступен в CLT (см. SettingsView).
    @StateObject private var wheel = WheelPosition()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.85)

    private var position: Double {
        wheel.stored ?? Double(value)
    }

    var body: some View {
        // Строки k = -3...3 стоят стопкой с шагом rowHeight; стопка сдвигается на дробную часть
        // позиции, поэтому колесо движется плавно. Окно — 5 строк (clipped), центр — выбранная строка.
        // reduceMotion влияет только на анимацию пружины (см. apply).
        let base = TimeWheelMath.selectedIndex(position: position)
        let fraction = position - Double(base)
        HStack(spacing: 2) {
            ZStack {
                VStack(spacing: 0) {
                    ForEach(-3...3, id: \.self) { offset in
                        let distance = Double(offset) - fraction
                        Text(String(format: "%02d", TimeWheelMath.wrap(base + offset, count: count)))
                            .font(.system(size: 28, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: rowHeight)
                            .opacity(TimeWheelMath.opacity(distance: distance))
                            // Цилиндр без perspective-3D: высота строки ~ cos(наклона). rotation3DEffect
                            // с perspective ломает раскладку в offscreen-рендере (строки слипаются).
                            .scaleEffect(y: CGFloat(cos(TimeWheelMath.tilt(distance: distance) * .pi / 180)))
                    }
                }
                .offset(y: CGFloat(-fraction) * rowHeight)
                WheelInputView(
                    rowHeight: rowHeight,
                    onMove: { move(by: $0) },
                    onNotch: { notch($0) },
                    onEnd: { snap() },
                    onClick: { click($0) }
                )
            }
            .frame(width: 40, height: rowHeight * 5)
            .clipped()
            Text(unit)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 26, alignment: .leading)
        }
        .frame(width: 80)
        .frame(height: rowHeight * 5)
        .clipped()
        .onChange(of: value) { newValue in
            let current = TimeWheelMath.value(position: position, count: count)
            guard current != newValue else { return }
            apply(TimeWheelMath.position(near: position, toValue: newValue, count: count), animated: true)
        }
    }

    private func move(by rows: Double) {
        apply(TimeWheelMath.position(position, movedBy: rows), animated: false)
    }

    private func notch(_ step: Int) {
        apply(TimeWheelMath.snapTarget(position) + Double(step), animated: true)
    }

    private func click(_ rows: Int) {
        apply(TimeWheelMath.snapTarget(position) + Double(rows), animated: true)
    }

    private func snap() {
        apply(TimeWheelMath.snapTarget(position), animated: true)
    }

    /// Единая точка изменения позиции: обновляет значение, отдаёт отклик при смене строки.
    private func apply(_ newPosition: Double, animated: Bool) {
        let oldIndex = TimeWheelMath.selectedIndex(position: position)
        if animated {
            withAnimation(reduceMotion ? nil : Self.spring) { wheel.stored = newPosition }
        } else {
            wheel.stored = newPosition
        }
        let newValue = TimeWheelMath.value(position: newPosition, count: count)
        if newValue != value { value = newValue }
        if TimeWheelMath.selectedIndex(position: newPosition) != oldIndex {
            TimeWheelFeedback.tick()
        }
    }
}

// MARK: - Ввод: скролл, перетаскивание, клик

/// Прозрачный NSView поверх колеса. Получает события без активации окна.
private struct WheelInputView: NSViewRepresentable {
    let rowHeight: CGFloat
    let onMove: (Double) -> Void
    let onNotch: (Int) -> Void
    let onEnd: () -> Void
    let onClick: (Int) -> Void

    func makeNSView(context: Context) -> WheelInputNSView {
        WheelInputNSView()
    }

    func updateNSView(_ view: WheelInputNSView, context: Context) {
        view.rowHeight = rowHeight
        view.onMove = onMove
        view.onNotch = onNotch
        view.onEnd = onEnd
        view.onClick = onClick
    }
}

final class WheelInputNSView: NSView {
    var rowHeight: CGFloat = 30
    var onMove: ((Double) -> Void)?
    var onNotch: ((Int) -> Void)?
    var onEnd: (() -> Void)?
    var onClick: ((Int) -> Void)?

    private var pendingSnap: DispatchWorkItem?
    private var lastDragY: CGFloat = 0
    private var dragStartY: CGFloat = 0
    private var dragMoved = false

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        pendingSnap?.cancel()
        pendingSnap = nil
        if event.hasPreciseScrollingDeltas {
            // Трекпад: следуем за пальцем 1:1, инерцию тоже отрабатываем по событиям.
            let dy = Double(event.scrollingDeltaY)
            if dy != 0 {
                onMove?(TimeWheelMath.rows(forScrollDelta: dy, rowHeight: Double(rowHeight)))
            }
            let momentumEnded = event.momentumPhase == .ended
            let fingerLiftedWithoutMomentum = event.momentumPhase == [] && (event.phase == .ended || event.phase == .cancelled)
            if momentumEnded {
                onEnd?()
            } else if fingerLiftedWithoutMomentum {
                // Инерция может начаться следующим событием: привязываемся, только если оно не пришло.
                let work = DispatchWorkItem { [weak self] in self?.onEnd?() }
                pendingSnap = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
            }
        } else {
            // Колесо мыши: одна щелка = одна строка.
            let step = TimeWheelMath.notchStep(deltaY: Double(event.scrollingDeltaY))
            if step != 0 { onNotch?(step) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = convert(event.locationInWindow, from: nil).y
        lastDragY = dragStartY
        dragMoved = false
    }

    override func mouseDragged(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        if abs(y - dragStartY) > 3 { dragMoved = true }
        let dy = Double(y - lastDragY)
        lastDragY = y
        if dragMoved, dy != 0 {
            onMove?(TimeWheelMath.rows(forScrollDelta: dy, rowHeight: Double(rowHeight)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragMoved {
            // Клик по строке выше/ниже центра — переход к ней.
            let y = convert(event.locationInWindow, from: nil).y
            let rows = Int(((y - bounds.midY) / rowHeight).rounded())
            if rows != 0 { onClick?(rows) }
        }
        onEnd?()
    }
}
