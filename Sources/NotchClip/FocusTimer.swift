import AppKit
import Combine
import Foundation
@preconcurrency import UserNotifications

/// Фаза таймера: фокус или один из перерывов.
enum FocusPhase: Equatable {
    case focus
    case shortBreak
    case longBreak
}

/// Состояние таймера.
enum FocusState: Equatable {
    case idle
    case running
    case paused
}

/// Завершение фазы по таймеру (не по пропуску). Нужно островку для баннера.
struct FocusPhaseEnd: Equatable {
    let id: UUID
    let finished: FocusPhase
    let next: FocusPhase
    let nextMinutes: Int
    let completedToday: Int
}

/// Помодоро-таймер. Время считается от `endDate` (а не декрементом), поэтому
/// корректно переживает сон компьютера. Часы и побочные эффекты инжектируются.
@MainActor
final class FocusTimer: ObservableObject {
    static let sessionsPerCycle = 4
    /// Звук в конце фазы. По умолчанию включён.
    static let soundEnabledKey = "focusTimer.soundEnabled"
    private static let finishEpsilon: TimeInterval = 0.05
    private static let minMinutes = 1
    private static let maxMinutes = 180

    /// Обновляется раз в секунду, пока таймер идёт; заставляет SwiftUI перерисовываться.
    @Published private(set) var lastTick: Date
    /// Ставится, когда фаза доходит до нуля. Пропуск фазы сюда не пишет.
    @Published private(set) var lastPhaseEnd: FocusPhaseEnd?
    @Published private(set) var phase: FocusPhase = .focus
    @Published private(set) var state: FocusState = .idle
    /// Сколько фокус-сессий сделано в текущем цикле (0..<sessionsPerCycle).
    @Published private(set) var focusInCycle: Int = 0
    @Published private(set) var focusMinutes: Int
    @Published private(set) var shortBreakMinutes: Int
    @Published private(set) var longBreakMinutes: Int

    private let defaults: UserDefaults
    private let clock: () -> Date
    private let playSound: () -> Void
    private let notify: (String) -> Void

    private var endDate: Date?
    private var pausedRemaining: TimeInterval?
    private var ticker: Timer?
    /// Сброс настроек пришёл во время фазы: длительности перечитаются на следующей фазе.
    private var durationsPending = false

    private enum Key {
        static let focusMinutes = "focusTimer.focusMinutes"
        static let shortBreakMinutes = "focusTimer.shortBreakMinutes"
        static let longBreakMinutes = "focusTimer.longBreakMinutes"
        static let cycle = "focusTimer.cycle"
        static let count = "focusTimer.count"
        static let countDay = "focusTimer.countDay"
    }

    init(
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = { Date() },
        playSound: @escaping () -> Void = FocusTimer.defaultPlaySound,
        notify: @escaping (String) -> Void = FocusTimer.defaultNotify
    ) {
        self.defaults = defaults
        self.clock = clock
        self.playSound = playSound
        self.notify = notify
        self.lastTick = clock()
        self.focusMinutes = FocusTimer.storedMinutes(defaults, Key.focusMinutes, fallback: 25)
        self.shortBreakMinutes = FocusTimer.storedMinutes(defaults, Key.shortBreakMinutes, fallback: 5)
        self.longBreakMinutes = FocusTimer.storedMinutes(defaults, Key.longBreakMinutes, fallback: 15)
        self.focusInCycle = min(max(defaults.integer(forKey: Key.cycle), 0), FocusTimer.sessionsPerCycle - 1)
    }

    // MARK: - Производные значения

    func minutes(for phase: FocusPhase) -> Int {
        switch phase {
        case .focus: return focusMinutes
        case .shortBreak: return shortBreakMinutes
        case .longBreak: return longBreakMinutes
        }
    }

    func duration(of phase: FocusPhase) -> TimeInterval {
        TimeInterval(minutes(for: phase) * 60)
    }

    /// Оставшееся время в секундах.
    var remaining: TimeInterval {
        switch state {
        case .idle:
            return duration(of: phase)
        case .paused:
            return pausedRemaining ?? duration(of: phase)
        case .running:
            guard let endDate else { return duration(of: phase) }
            return max(0, endDate.timeIntervalSince(clock()))
        }
    }

    /// Прогресс текущей фазы от 0 до 1 (доля прошедшего времени).
    var progress: Double {
        let total = duration(of: phase)
        guard total > 0 else { return 0 }
        return min(max(1 - remaining / total, 0), 1)
    }

    /// "18:42" — мм:сс, округление вверх, чтобы в начале было "25:00".
    var compactText: String {
        let total = max(0, Int(ceil(remaining - 0.01)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    var phaseTitle: String {
        switch phase {
        case .focus: return "Фокус"
        case .shortBreak: return "Перерыв"
        case .longBreak: return "Длинный перерыв"
        }
    }

    /// Время окончания фазы ("14:35") — только когда таймер идёт.
    var endTimeText: String? {
        guard state == .running, let endDate else { return nil }
        return Self.timeFormatter.string(from: endDate)
    }

    /// Сколько фокус-сессий завершено сегодня (сбрасывается в новый день).
    var completedFocusCount: Int {
        defaults.integer(forKey: Key.countDay) == dayKey(clock())
            ? defaults.integer(forKey: Key.count)
            : 0
    }

    // MARK: - Настройки

    /// Перечитывает длительности из UserDefaults (после сброса настроек). В idle — сразу,
    /// иначе — при переходе к следующей фазе, чтобы текущая фаза не сменила длительность на ходу.
    func reloadDurations() {
        guard state == .idle else { durationsPending = true; return }
        loadDurations()
    }

    private func loadDurations() {
        durationsPending = false
        focusMinutes = FocusTimer.storedMinutes(defaults, Key.focusMinutes, fallback: 25)
        shortBreakMinutes = FocusTimer.storedMinutes(defaults, Key.shortBreakMinutes, fallback: 5)
        longBreakMinutes = FocusTimer.storedMinutes(defaults, Key.longBreakMinutes, fallback: 15)
    }

    /// Меняет длительность фазы. Работает только в состоянии idle.
    func setMinutes(_ value: Int, for phase: FocusPhase) {
        guard state == .idle else { return }
        let clamped = min(max(value, Self.minMinutes), Self.maxMinutes)
        switch phase {
        case .focus:
            focusMinutes = clamped
            defaults.set(clamped, forKey: Key.focusMinutes)
        case .shortBreak:
            shortBreakMinutes = clamped
            defaults.set(clamped, forKey: Key.shortBreakMinutes)
        case .longBreak:
            longBreakMinutes = clamped
            defaults.set(clamped, forKey: Key.longBreakMinutes)
        }
    }

    // MARK: - Управление

    func start() {
        guard state == .idle else { return }
        endDate = clock().addingTimeInterval(duration(of: phase))
        pausedRemaining = nil
        state = .running
        startTicker()
    }

    func pause() {
        guard state == .running else { return }
        pausedRemaining = remaining
        endDate = nil
        state = .paused
        stopTicker()
    }

    func resume() {
        guard state == .paused else { return }
        endDate = clock().addingTimeInterval(pausedRemaining ?? duration(of: phase))
        pausedRemaining = nil
        state = .running
        startTicker()
    }

    /// Главная кнопка: Старт / Пауза / Продолжить.
    func toggle() {
        switch state {
        case .idle: start()
        case .running: pause()
        case .paused: resume()
        }
    }

    /// Кнопка "Отмена": сбрасывает текущую фазу без перехода к следующей.
    func reset() {
        stopTicker()
        endDate = nil
        pausedRemaining = nil
        state = .idle
        if durationsPending { loadDurations() }
    }

    /// Добавляет время к текущей фазе (кнопка "+5 мин" на островке).
    func addTime(_ seconds: TimeInterval) {
        switch state {
        case .idle: return
        case .running:
            if let endDate { self.endDate = endDate.addingTimeInterval(seconds) }
        case .paused:
            pausedRemaining = (pausedRemaining ?? 0) + seconds
        }
    }

    /// Пропуск фазы: переход к следующей без звука и уведомления.
    /// Пропущенная фокус-сессия в дневной счётчик не попадает.
    func skip() {
        advancePhase(completed: false)
    }

    /// Вызывается каждую секунду во время работы таймера (и напрямую из тестов).
    func tick() {
        lastTick = clock()
        guard state == .running, remaining <= Self.finishEpsilon else { return }
        let finished = phase
        advancePhase(completed: true)
        lastPhaseEnd = FocusPhaseEnd(
            id: UUID(),
            finished: finished,
            next: phase,
            nextMinutes: minutes(for: phase),
            completedToday: completedFocusCount
        )
        if defaults.object(forKey: Self.soundEnabledKey) as? Bool ?? true { playSound() }
        notify(endMessage(finished: finished))
    }

    // MARK: - Внутреннее

    /// Переводит таймер к следующей фазе в состоянии idle.
    private func advancePhase(completed: Bool) {
        stopTicker()
        endDate = nil
        pausedRemaining = nil
        state = .idle
        if durationsPending { loadDurations() }

        switch phase {
        case .focus:
            if completed { incrementCompletedCount() }
            focusInCycle += 1
            if focusInCycle >= Self.sessionsPerCycle {
                focusInCycle = 0
                phase = .longBreak
            } else {
                phase = .shortBreak
            }
            defaults.set(focusInCycle, forKey: Key.cycle)
        case .shortBreak, .longBreak:
            phase = .focus
        }
    }

    private func endMessage(finished: FocusPhase) -> String {
        switch finished {
        case .focus:
            let label = phase == .longBreak ? "длинный перерыв" : "перерыв"
            return "Фокус окончен — \(label) \(minutes(for: phase)) мин"
        case .shortBreak, .longBreak:
            return "Перерыв окончен — фокус \(minutes(for: .focus)) мин"
        }
    }

    private func incrementCompletedCount() {
        let today = dayKey(clock())
        let current = defaults.integer(forKey: Key.countDay) == today
            ? defaults.integer(forKey: Key.count)
            : 0
        defaults.set(today, forKey: Key.countDay)
        defaults.set(current + 1, forKey: Key.count)
    }

    private func dayKey(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func storedMinutes(_ defaults: UserDefaults, _ key: String, fallback: Int) -> Int {
        let value = defaults.integer(forKey: key)
        return value > 0 ? value : fallback
    }

    // MARK: - Побочные эффекты по умолчанию

    nonisolated static func defaultPlaySound() {
        NSSound(named: "Glass")?.play()
    }

    /// Уведомление-баннер. Разрешение запрашивается лениво; ошибки игнорируются.
    nonisolated static func defaultNotify(_ message: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "NotchClip"
            content.body = message
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }
}
