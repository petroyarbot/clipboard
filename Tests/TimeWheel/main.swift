import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("ok   - \(name)")
    } else {
        failures += 1
        print("FAIL - \(name)")
    }
}

// Обёртка: цикличность индекса, включая отрицательные значения.
check(TimeWheelMath.wrap(59, count: 60) == 59, "wrap keeps last minute")
check(TimeWheelMath.wrap(60, count: 60) == 0, "wrap 60 goes to 0 for minutes")
check(TimeWheelMath.wrap(-1, count: 60) == 59, "wrap -1 goes to 59")
check(TimeWheelMath.wrap(-61, count: 60) == 59, "wrap -61 goes to 59")
check(TimeWheelMath.wrap(24, count: 24) == 0, "hours wrap 24 to 0")
check(TimeWheelMath.wrap(-24, count: 24) == 0, "hours wrap -24 to 0")
check(TimeWheelMath.wrap(25, count: 24) == 1, "hours wrap 25 to 1")
check(TimeWheelMath.wrap(5, count: 0) == 0, "wrap with empty count is 0")

// Значение из позиции: округление до ближайшей строки.
check(TimeWheelMath.value(position: 59.4, count: 60) == 59, "value rounds down below .5")
check(TimeWheelMath.value(position: 59.6, count: 60) == 0, "value rounds up past .5 and wraps")
check(TimeWheelMath.value(position: -0.4, count: 60) == 0, "value near zero from below")
check(TimeWheelMath.value(position: -0.6, count: 60) == 59, "value below zero wraps to 59")

// Перенос позиции к значению по кратчайшему пути.
check(TimeWheelMath.position(near: 59.0, toValue: 0, count: 60) == 60.0, "59 to 0 goes forward one step")
check(TimeWheelMath.position(near: 0, toValue: 59, count: 60) == -1.0, "0 to 59 goes back one step")
check(TimeWheelMath.position(near: 5, toValue: 7, count: 60) == 7.0, "5 to 7 moves two steps")
check(TimeWheelMath.position(near: 3.2, toValue: 3, count: 60) == 3.2, "same value keeps fractional position")
check(TimeWheelMath.value(position: TimeWheelMath.position(near: 23, toValue: 0, count: 24), count: 24) == 0, "hours rebase wraps")

// Цель привязки.
check(TimeWheelMath.snapTarget(2.4) == 2, "snap rounds down")
check(TimeWheelMath.snapTarget(2.5) == 3, "snap rounds half up")
check(TimeWheelMath.snapTarget(-2.4) == -2, "snap works for negative positions")

// Скролл: палец вниз уменьшает значение, одна щелка мыши = одна строка.
check(TimeWheelMath.rows(forScrollDelta: -30, rowHeight: 30) == 1, "finger up (negative dy) adds one row per 30 pt")
check(TimeWheelMath.rows(forScrollDelta: 15, rowHeight: 30) == -0.5, "finger down reduces value")
check(TimeWheelMath.position(2.0, movedBy: 1.5) == 3.5, "movement adds rows")
check(TimeWheelMath.notchStep(deltaY: 1) == -1, "wheel up notch goes to previous row")
check(TimeWheelMath.notchStep(deltaY: -3) == 1, "wheel down notch goes to next row")
check(TimeWheelMath.notchStep(deltaY: 0) == 0, "no delta means no step")

// Отклик: число пересечённых строк.
check(TimeWheelMath.stepsCrossed(from: 1.4, to: 2.4) == 1, "crossing one boundary is one step")
check(TimeWheelMath.stepsCrossed(from: 1.4, to: 2.6) == 2, "crossing two boundaries is two steps")
check(TimeWheelMath.stepsCrossed(from: 0.2, to: 0.4) == 0, "moving inside a row is no step")
check(TimeWheelMath.stepsCrossed(from: 0, to: -2.6) == 3, "fast move across rows counts each step")

// Троттлинг тактильного отклика: не чаще 25 мс.
do {
    var throttle = HapticThrottle()
    check(throttle.shouldFire(at: 0), "first tick fires")
    check(!throttle.shouldFire(at: 0.010), "tick 10 ms later is throttled")
    check(throttle.shouldFire(at: 0.025), "tick exactly 25 ms later fires")
    check(!throttle.shouldFire(at: 0.030), "tick 5 ms after a fire is throttled")
    check(throttle.lastFire == 0.025, "throttled ticks do not move the window")
}

// Непрозрачность и наклон строк.
check(TimeWheelMath.opacity(distance: 0) == 1, "selected row fully opaque")
check(abs(TimeWheelMath.opacity(distance: 1) - 0.3) < 0.0001, "neighbour row fades to 30 percent")
check(TimeWheelMath.opacity(distance: -1) == TimeWheelMath.opacity(distance: 1), "fade is symmetric")
check(TimeWheelMath.opacity(distance: 3) == 0, "far rows are hidden")
check(TimeWheelMath.tilt(distance: 0) == 0, "selected row is not tilted")
check(TimeWheelMath.tilt(distance: -1) == -25, "tilt grows with distance")

// Общее время: зажатие до 23:59:59.
check(TimeWheelMath.maxTotalSeconds == 86_399, "max total is 23:59:59")
check(TimeWheelMath.totalSeconds(hours: 23, minutes: 59, seconds: 59) == 86_399, "max components give max total")
check(TimeWheelMath.totalSeconds(hours: 24, minutes: 0, seconds: 0) == 86_399, "hours over 23 clamp to max")
check(TimeWheelMath.totalSeconds(hours: 0, minutes: 0, seconds: 0) == 0, "zero total allowed")
check(TimeWheelMath.components(3725) == (1, 2, 5), "components of 3725")
check(TimeWheelMath.components(-5) == (0, 0, 0), "negative components clamp to zero")
check(TimeWheelMath.components(999_999) == (23, 59, 59), "huge components clamp to max")

// Недавние: уникальные, свежие первыми, не больше четырёх.
check(TimeWheelMath.updatedRecents([], adding: 1500) == [1500], "first recent is stored")
check(TimeWheelMath.updatedRecents([1500, 3600, 900], adding: 60) == [60, 1500, 3600, 900], "new recent goes first")
check(TimeWheelMath.updatedRecents([60, 1500, 3600, 900], adding: 45) == [45, 60, 1500, 3600], "list keeps only four")
check(TimeWheelMath.updatedRecents([60, 1500, 3600, 900], adding: 1500) == [1500, 60, 3600, 900], "repeat moves to front without duplicates")
check(TimeWheelMath.updatedRecents([60], adding: 0) == [60], "zero is not recorded")
check(TimeWheelMath.decodeRecents(TimeWheelMath.encodeRecents([3600, 1500])) == [3600, 1500], "encode and decode round-trip")
check(TimeWheelMath.decodeRecents("abc,0,-5,1500,1500,99999999,900") == [1500, 900], "decode drops junk, zeros, duplicates and overflow")
check(TimeWheelMath.decodeRecents("") == [], "empty text decodes to empty list")
check(TimeWheelMath.decodeRecents("1,2,3,4,5,6") == [1, 2, 3, 4], "decode keeps at most four")

// Подписи чипов.
check(TimeWheelMath.durationTitle(1500) == "25 мин", "25 minutes title")
check(TimeWheelMath.durationTitle(5400) == "1 ч 30 мин", "hour and minutes title")
check(TimeWheelMath.durationTitle(3600) == "1 ч", "exact hour title")
check(TimeWheelMath.durationTitle(90) == "1 мин 30 с", "minute and seconds title")
check(TimeWheelMath.durationTitle(45) == "45 с", "seconds only title")

print(failures == 0 ? "All time wheel tests passed" : "\(failures) time wheel check(s) failed")
exit(failures == 0 ? 0 : 1)
