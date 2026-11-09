import AppKit

// MARK: - Чистая логика (тестируется без UI, см. Tests/TimeWheel)

/// Математика колёсиков времени. Позиция колеса — непрерывное число в строках;
/// выбранная строка — ближайшее целое. Индекс зациклен по модулю `count`.
enum TimeWheelMath {
    static let maxTotalSeconds = 23 * 3600 + 59 * 60 + 59
    static let recentLimit = 4

    /// Остаток по модулю без отрицательных значений: wrap(-1, 60) == 59.
    static func wrap(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let rest = index % count
        return rest < 0 ? rest + count : rest
    }

    /// Выбранная строка для непрерывной позиции (округление до ближайшей).
    static func selectedIndex(position: Double) -> Int {
        Int(position.rounded())
    }

    /// Значение колеса 0..<count для позиции.
    static func value(position: Double, count: Int) -> Int {
        wrap(selectedIndex(position: position), count: count)
    }

    /// Позиция после прокрутки на `rows` строк (целевая позиция не округляется).
    static func position(_ position: Double, movedBy rows: Double) -> Double {
        position + rows
    }

    /// Строки для смещения по пикселям скролла/перетаскивания: палец вниз (dy > 0) уменьшает значение.
    static func rows(forScrollDelta dy: Double, rowHeight: Double) -> Double {
        -dy / rowHeight
    }

    /// Цель привязки после отпускания: ближайшая строка.
    static func snapTarget(_ position: Double) -> Double {
        position.rounded()
    }

    /// Одна "щелка" мыши = одна строка. dy > 0 (колесо вверх) уменьшает значение.
    static func notchStep(deltaY: Double) -> Int {
        if deltaY > 0 { return -1 }
        if deltaY < 0 { return 1 }
        return 0
    }

    /// Новая позиция, которая соответствует значению `value` по кратчайшему пути по кругу.
    static func position(near current: Double, toValue value: Int, count: Int) -> Double {
        let currentValue = wrap(selectedIndex(position: current), count: count)
        var delta = wrap(value - currentValue, count: count)
        if delta > count / 2 { delta -= count }
        return current + Double(delta)
    }

    /// Сколько целых шагов выбора пересечено между двумя позициями.
    static func stepsCrossed(from old: Double, to new: Double) -> Int {
        abs(selectedIndex(position: new) - selectedIndex(position: old))
    }

    /// Прозрачность строки по расстоянию от центра (в строках): центр 1, остальные до 0.3, дальше скрыты.
    static func opacity(distance: Double) -> Double {
        let distance = abs(distance)
        if distance > 2.5 { return 0 }
        return max(0.3, 1 - 0.7 * distance)
    }

    /// Наклон строки вокруг оси X (градусы) — эффект цилиндра.
    static func tilt(distance: Double) -> Double {
        max(-60, min(60, distance * 25))
    }

    static func totalSeconds(hours: Int, minutes: Int, seconds: Int) -> Int {
        min(max(hours * 3600 + minutes * 60 + seconds, 0), maxTotalSeconds)
    }

    static func components(_ total: Int) -> (hours: Int, minutes: Int, seconds: Int) {
        let clamped = min(max(total, 0), maxTotalSeconds)
        return (clamped / 3600, clamped % 3600 / 60, clamped % 60)
    }

    /// Недавние длительности: без повторов, самая свежая первой, не больше `limit`. Ноль игнорируется.
    static func updatedRecents(_ recents: [Int], adding seconds: Int, limit: Int = recentLimit) -> [Int] {
        guard seconds > 0 else { return Array(recents.prefix(limit)) }
        return Array(([seconds] + recents.filter { $0 != seconds }).prefix(limit))
    }

    static func encodeRecents(_ list: [Int]) -> String {
        list.map(String.init).joined(separator: ",")
    }

    /// Обратное к encodeRecents; мусор и значения вне диапазона отбрасываются.
    static func decodeRecents(_ text: String, limit: Int = recentLimit) -> [Int] {
        var result: [Int] = []
        for part in text.split(separator: ",") {
            guard let value = Int(part), value > 0, value <= maxTotalSeconds, !result.contains(value) else { continue }
            result.append(value)
            if result.count == limit { break }
        }
        return result
    }

    /// Подпись чипа: "25 мин", "1 ч 30 мин", "1 мин 30 с", "45 с".
    static func durationTitle(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = seconds % 3600 / 60
        let s = seconds % 60
        if h > 0 { return m > 0 ? "\(h) ч \(m) мин" : "\(h) ч" }
        if m > 0 { return s > 0 ? "\(m) мин \(s) с" : "\(m) мин" }
        return "\(s) с"
    }
}

/// Решение о тактильном отклике: не чаще одного раза в `minInterval` секунд.
struct HapticThrottle {
    static let minInterval: TimeInterval = 0.025
    private(set) var lastFire: TimeInterval?

    /// true — откликнуться сейчас; запоминает время только при true.
    mutating func shouldFire(at time: TimeInterval) -> Bool {
        if let lastFire, time - lastFire < Self.minInterval { return false }
        lastFire = time
        return true
    }
}

/// Тактильный отклик и мягкий звук при смене значения на одну строку.
@MainActor
enum TimeWheelFeedback {
    /// Звук щелчка выключен по умолчанию.
    static let soundKey = "focusWheelTickSound"
    private static var throttle = HapticThrottle()

    static func tick() {
        guard throttle.shouldFire(at: ProcessInfo.processInfo.systemUptime) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if UserDefaults.standard.bool(forKey: soundKey) {
            let sound = NSSound(named: "Tink")
            sound?.volume = 0.15
            sound?.play()
        }
    }
}
