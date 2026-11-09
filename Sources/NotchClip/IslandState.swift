import AppKit // ширина текста считается теми же системными шрифтами, что рисует островок
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
    /// Ширина одного крыла в компактном режиме (слева и справа одинаковая, чтобы содержимое было симметричным).
    var wing: CGFloat = IslandState.minimumWingWidth
}

/// Что стоит в компактных крыльях. По этому описанию считается ширина, поэтому окно и текст не расходятся.
struct CompactWings: Equatable {
    var showsTimer = false
    var showsAgent = false
    /// Текущее время ("4:44", "1:05:00"). Из строки берётся формат, а не сами цифры.
    var clock = "0:00"
    var phaseLabel = "Фокус"
    var agentProject = ""
    var agentCount = 0
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
    /// Минимальная ширина крыла; реальная считается по содержимому (`compactWingWidth`).
    static let minimumWingWidth: CGFloat = 68
    /// Отступ содержимого от внешнего края крыла: выше верхнего скругления/фаски формы (фаска ~11 pt при высоте 32).
    static let wingEdgePadding: CGFloat = 12
    /// Минимальный зазор между содержимым и вырезом камеры.
    static let wingNotchGap: CGFloat = 8
    /// Запас окна на пружинный перелёт формы при росте (по 5 pt с каждой стороны, снизу 10).
    static let overshootSlack: CGFloat = 10
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

    static func layout(for presentation: IslandPresentation, notchWidth: CGFloat, notchHeight: CGFloat, wings: CompactWings = CompactWings()) -> IslandLayout? {
        switch presentation {
        case .idle:
            return nil
        case .compactTimer, .compactAgent, .compactBoth:
            let wing = compactWingWidth(wings)
            return IslandLayout(width: notchWidth + 2 * wing, height: notchHeight, bottomRadius: 12, contentTop: 0, wing: wing)
        case .miniPlayer:
            return IslandLayout(width: miniSize.width, height: miniSize.height, bottomRadius: 30, contentTop: notchHeight)
        case .banner:
            return IslandLayout(width: bannerSize.width, height: bannerSize.height, bottomRadius: 22, contentTop: notchHeight)
        }
    }

    // MARK: - Время и ширина крыльев

    /// Самая широкая строка того же формата: ширина крыла не дёргается, пока время идёт.
    static func reservedClock(_ text: String) -> String {
        text.filter { $0 == ":" }.count >= 2 ? "99:59:59" : "59:59"
    }

    /// Ширина текста в точках. `digits` — моноширинные цифры, как `monospacedDigit()` в SwiftUI.
    static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight, digits: Bool = false) -> CGFloat {
        let font = digits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Ширина времени с запасом под значок паузы (он стоит слева от цифр и не должен менять ширину крыла).
    static func clockWidth(_ clock: String, size: CGFloat) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .regular)
        let pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.size.width ?? size * 0.5
        return textWidth(reservedClock(clock), size: size, weight: .semibold, digits: true) + 3 + ceil(pause)
    }

    /// Ширина одного крыла: самое широкое содержимое + отступ от края + зазор до выреза. Не меньше `minimumWingWidth`.
    static func compactWingWidth(_ wings: CompactWings) -> CGFloat {
        // Слева: кольцо 15 + 5 + (время при агенте 11 pt | подпись фазы 10 pt) или значок агента 22 + 5 + проект (до 96).
        var left: CGFloat = 0
        if wings.showsTimer {
            let tail = wings.showsAgent ? clockWidth(wings.clock, size: 11) : textWidth(wings.phaseLabel, size: 10, weight: .semibold)
            left = 15 + 5 + tail
        } else if wings.showsAgent {
            left = badgeWidth + 5 + min(textWidth(wings.agentProject, size: 10, weight: .medium), 96)
        }
        // Справа: значок агента + точка 6 + 4 + число/"ждёт" (10 pt), либо одно время 13 pt.
        var right: CGFloat = 0
        if wings.showsAgent {
            let count = wings.showsTimer ? "\(wings.agentCount)" : "ждёт"
            right = (wings.showsTimer ? badgeWidth + 4 : 0) + 6 + 4 + textWidth("\(count)", size: 10, weight: .semibold)
        } else if wings.showsTimer {
            right = clockWidth(wings.clock, size: 13)
        }
        let content = max(left, right)
        return max(minimumWingWidth, content + wingEdgePadding + wingNotchGap)
    }

    /// Значок "CL"/"CX": текст 8.5 pt + по 4 pt слева и справа.
    private static var badgeWidth: CGFloat { textWidth("CL", size: 8.5, weight: .bold) + 8 }

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
