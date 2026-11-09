import Foundation

/// Что показывает закрытая "чёлка". Выбирается в `IslandState.presentation`.
enum IslandPresentation: Equatable {
    case idle
    case compactTimer
    case compactAgent
    case compactBoth
    case miniPlayer
    case banner
}

/// Всё, из чего выбирается презентация. Часы передаются отдельно.
struct IslandInputs: Equatable {
    var timer: FocusState = .idle
    var phase: FocusPhase = .focus
    var needsActionCount = 0
    var hovering = false
    var focusEnabled = true
    var agentsEnabled = true
}

/// Баннер окончания фазы.
struct IslandBanner: Equatable {
    let finished: FocusPhase
    let next: FocusPhase
    let nextMinutes: Int
    let completedToday: Int
    let agentsDone: Int
    let startedAt: TimeInterval
}

/// Размер чёрной формы. `contentTop` — где начинается содержимое под вырезом.
struct IslandLayout: Equatable {
    let width: CGFloat
    let height: CGFloat
    let bottomRadius: CGFloat
    let contentTop: CGFloat
}

/// Ключи настроек Live Activity (UI настроек читает их же).
enum IslandSettings {
    static let focusKey = "liveActivityFocus"
    static let agentsKey = "liveActivityAgents"

    static func isEnabled(_ key: String, defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// Чистый редьюсер островка: без AppKit и без таймеров. Время передаётся числом (секунды).
struct IslandState: Equatable {
    static let bannerDuration: TimeInterval = 4
    static let wingWidth: CGFloat = 68
    static let miniSize = CGSize(width: 440, height: 150)
    static let bannerSize = CGSize(width: 460, height: 104)
    static let minimumNotchHeight: CGFloat = 32

    private(set) var banner: IslandBanner?
    /// "готово" от агентов, пришедшие во время фокуса. Уходят в баннер при окончании фазы.
    private(set) var queuedAgentDone = 0
    /// То, что было в очереди при паузе. Показывается в мини-плеере, пока таймер на паузе.
    private(set) var releasedAgentDone = 0

    /// Тихий режим: фокус идёт, перерыва нет.
    static func isQuiet(timer: FocusState, phase: FocusPhase) -> Bool {
        timer == .running && phase == .focus
    }

    mutating func agentsFinished(_ count: Int, quiet: Bool) {
        guard quiet, count > 0 else { return }
        queuedAgentDone += count
    }

    /// Фокус снова идёт: отданная в мини-плеер очередь возвращается, чтобы пауза или пропуск не теряли счёт.
    mutating func quietStarted() {
        queuedAgentDone += releasedAgentDone
        releasedAgentDone = 0
    }

    mutating func quietEnded() {
        releasedAgentDone = queuedAgentDone
        queuedAgentDone = 0
    }

    mutating func phaseEnded(finished: FocusPhase, next: FocusPhase, nextMinutes: Int, completedToday: Int, at now: TimeInterval) {
        banner = IslandBanner(
            finished: finished,
            next: next,
            nextMinutes: nextMinutes,
            completedToday: completedToday,
            agentsDone: queuedAgentDone,
            startedAt: now
        )
        queuedAgentDone = 0
        releasedAgentDone = 0
    }

    mutating func dismissBanner() { banner = nil }

    /// Момент, когда баннер гаснет (для одного отложенного пересчёта).
    var bannerExpiry: TimeInterval? {
        banner.map { $0.startedAt + Self.bannerDuration }
    }

    /// Приоритет: баннер окончания > needsAction > таймер > ничего.
    func presentation(_ inputs: IslandInputs, now: TimeInterval) -> IslandPresentation {
        if inputs.focusEnabled, let banner {
            let age = now - banner.startedAt
            if age >= 0 && age < Self.bannerDuration { return .banner }
        }
        let agent = inputs.agentsEnabled && inputs.needsActionCount > 0
        let timer = inputs.focusEnabled && inputs.timer != .idle
        switch (timer, agent) {
        case (true, true): return inputs.hovering ? .miniPlayer : .compactBoth
        case (true, false): return inputs.hovering ? .miniPlayer : .compactTimer
        case (false, true): return .compactAgent
        case (false, false): return .idle
        }
    }

    static func layout(for presentation: IslandPresentation, notchWidth: CGFloat, notchHeight: CGFloat) -> IslandLayout? {
        switch presentation {
        case .idle:
            return nil
        case .compactTimer, .compactAgent, .compactBoth:
            return IslandLayout(width: notchWidth + 2 * wingWidth, height: notchHeight, bottomRadius: 12, contentTop: 0)
        case .miniPlayer:
            return IslandLayout(width: miniSize.width, height: miniSize.height, bottomRadius: 30, contentTop: notchHeight)
        case .banner:
            return IslandLayout(width: bannerSize.width, height: bannerSize.height, bottomRadius: 22, contentTop: notchHeight)
        }
    }

    // MARK: - Тексты

    static func bannerTitle(finished: FocusPhase) -> String {
        finished == .focus ? "Фокус окончен" : "Перерыв окончен"
    }

    static func nextButtonTitle(next: FocusPhase) -> String {
        next == .focus ? "Фокус" : "Перерыв"
    }

    static func phaseName(_ phase: FocusPhase) -> String {
        switch phase {
        case .focus: return "фокус"
        case .shortBreak: return "перерыв"
        case .longBreak: return "длинный перерыв"
        }
    }

    static func bannerSubtitle(_ banner: IslandBanner) -> String {
        var parts = ["Сегодня: \(banner.completedToday)", "дальше: \(phaseName(banner.next)) \(banner.nextMinutes) мин"]
        if banner.agentsDone > 0 { parts.append(agentsFinishedText(banner.agentsDone)) }
        return parts.joined(separator: " · ")
    }

    /// Русское склонение: "1 агент закончил", "2 агента закончили", "5 агентов закончили".
    static func agentsFinishedText(_ count: Int) -> String {
        let tens = count % 100
        let ones = count % 10
        if ones == 1 && tens != 11 { return "\(count) агент закончил" }
        if (2...4).contains(ones) && !(12...14).contains(tens) { return "\(count) агента закончили" }
        return "\(count) агентов закончили"
    }
}
