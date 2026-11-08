import Foundation

// Фейковые часы: время двигается только явно.
final class FakeClock {
    var now: Date
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

// Записываем побочные эффекты вместо звука и уведомлений.
final class Recorder {
    var sounds = 0
    var messages: [String] = []
}

@MainActor
func makeTimer(_ clock: FakeClock, _ defaults: UserDefaults, _ recorder: Recorder) -> FocusTimer {
    FocusTimer(
        defaults: defaults,
        clock: { clock.now },
        playSound: { recorder.sounds += 1 },
        notify: { recorder.messages.append($0) }
    )
}

/// Запускает текущую фазу и доводит её до конца.
@MainActor
func finishPhase(_ timer: FocusTimer, _ clock: FakeClock) {
    timer.start()
    clock.advance(timer.remaining)
    timer.tick()
}

@MainActor
func runTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ name: String) {
        if condition {
            print("ok   - \(name)")
        } else {
            failures += 1
            print("FAIL - \(name)")
        }
    }

    let suite = "focus-timer-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    var calendar = Calendar.current
    calendar.timeZone = TimeZone.current
    let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!

    // 1. Старт: время уменьшается по часам, а не декрементом.
    do {
        let clock = FakeClock(noon)
        let recorder = Recorder()
        let timer = makeTimer(clock, defaults, recorder)
        check(timer.state == .idle && timer.phase == .focus, "starts idle in focus phase")
        check(timer.remaining == 1500 && timer.compactText == "25:00", "idle shows full 25:00")
        timer.start()
        check(timer.state == .running, "start moves to running")
        clock.advance(378)
        check(timer.remaining == 1122, "remaining decreases with clock")
        check(timer.compactText == "18:42", "compactText shows 18:42")
        check(abs(timer.progress - 378.0 / 1500.0) < 0.001, "progress is elapsed fraction")
        check(timer.endTimeText != nil, "end time shown while running")
    }

    // 2. Пауза и продолжение сохраняют остаток.
    do {
        let clock = FakeClock(noon)
        let timer = makeTimer(clock, defaults, Recorder())
        timer.start()
        clock.advance(10)
        timer.pause()
        check(timer.state == .paused, "pause moves to paused")
        check(timer.remaining == 1490, "pause freezes remaining")
        clock.advance(100)
        check(timer.remaining == 1490, "paused time does not count down")
        timer.resume()
        check(timer.state == .running, "resume moves to running")
        clock.advance(2)
        check(timer.remaining == 1488, "resume continues from paused remaining")
    }

    // 3. Конец фазы (включая "сон" через большой скачок часов): фокус -> короткий перерыв.
    do {
        let clock = FakeClock(noon)
        let recorder = Recorder()
        let timer = makeTimer(clock, defaults, recorder)
        timer.start()
        clock.advance(5000) // имитация сна компьютера
        timer.tick()
        check(timer.phase == .shortBreak, "focus end advances to short break")
        check(timer.state == .idle, "next phase waits idle for Start")
        check(timer.remaining == 300, "short break is 5 minutes")
        check(recorder.sounds == 1, "phase end plays sound once")
        check(recorder.messages.last == "Фокус окончен — перерыв 5 мин", "phase end posts notification")
        check(timer.completedFocusCount == 1, "completed focus is counted")
    }

    // 4. Четвёртая фокус-сессия -> длинный перерыв.
    do {
        defaults.removeObject(forKey: "focusTimer.count")
        defaults.removeObject(forKey: "focusTimer.countDay")
        defaults.removeObject(forKey: "focusTimer.cycle")
        let clock = FakeClock(noon)
        let recorder = Recorder()
        let timer = makeTimer(clock, defaults, recorder)
        var phases: [FocusPhase] = []
        for _ in 0..<3 {
            finishPhase(timer, clock) // focus -> break
            phases.append(timer.phase)
            finishPhase(timer, clock) // break -> focus
            phases.append(timer.phase)
        }
        finishPhase(timer, clock) // 4th focus
        phases.append(timer.phase)
        check(phases == [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak],
              "cycle of 4 focus sessions ends with long break")
        check(timer.remaining == 900, "long break is 15 minutes")
        check(recorder.messages.last == "Фокус окончен — длинный перерыв 15 мин", "long break message")
        check(timer.focusInCycle == 0, "cycle counter resets after long break")
        finishPhase(timer, clock) // long break -> focus
        check(timer.phase == .focus, "long break end returns to focus")
        check(recorder.messages.last == "Перерыв окончен — фокус 25 мин", "break end message")
    }

    // 5. Пропуск фазы: без звука, без счётчика.
    do {
        defaults.removeObject(forKey: "focusTimer.count")
        defaults.removeObject(forKey: "focusTimer.countDay")
        defaults.removeObject(forKey: "focusTimer.cycle")
        let clock = FakeClock(noon)
        let recorder = Recorder()
        let timer = makeTimer(clock, defaults, recorder)
        let countBefore = timer.completedFocusCount
        timer.start()
        clock.advance(60)
        timer.skip()
        check(timer.phase == .shortBreak && timer.state == .idle, "skip focus goes to short break idle")
        check(recorder.sounds == 0 && recorder.messages.isEmpty, "skip plays no sound or notification")
        check(timer.completedFocusCount == countBefore, "skipped focus is not counted")
        timer.skip()
        check(timer.phase == .focus && timer.state == .idle, "skip break returns to focus idle")
    }

    // 6. Сброс возвращает полную длительность фазы.
    do {
        let clock = FakeClock(noon)
        let timer = makeTimer(clock, defaults, Recorder())
        timer.start()
        clock.advance(100)
        timer.reset()
        check(timer.state == .idle && timer.remaining == 1500, "reset returns to idle full duration")
    }

    // 7. Дневной счётчик: сохраняется и сбрасывается в новый день.
    do {
        defaults.removeObject(forKey: "focusTimer.count")
        defaults.removeObject(forKey: "focusTimer.countDay")
        defaults.removeObject(forKey: "focusTimer.cycle")
        let clock = FakeClock(noon)
        let timer = makeTimer(clock, defaults, Recorder())
        finishPhase(timer, clock)
        check(timer.completedFocusCount == 1, "daily count is 1 after one focus")
        let reopened = makeTimer(clock, defaults, Recorder())
        check(reopened.completedFocusCount == 1, "daily count persists across instances")

        clock.advance(24 * 3600)
        let nextDay = makeTimer(clock, defaults, Recorder())
        check(nextDay.completedFocusCount == 0, "daily count resets on new day")
        finishPhase(nextDay, clock)
        check(nextDay.completedFocusCount == 1, "count starts again on new day")
    }

    // 8. Настройка длительности: зажимается и сохраняется.
    do {
        defaults.removeObject(forKey: "focusTimer.focusMinutes")
        let clock = FakeClock(noon)
        let timer = makeTimer(clock, defaults, Recorder())
        timer.setMinutes(50, for: .focus)
        check(timer.remaining == 3000, "custom focus duration applies when idle")
        timer.setMinutes(0, for: .focus)
        check(timer.focusMinutes == 1, "focus duration clamps to minimum 1")
        timer.setMinutes(50, for: .focus)
        let reopened = makeTimer(clock, defaults, Recorder())
        check(reopened.focusMinutes == 50, "custom duration persists")
    }

    return failures
}

let failureCount = MainActor.assumeIsolated { runTests() }
print(failureCount == 0 ? "All focus timer tests passed" : "\(failureCount) focus timer check(s) failed")
exit(failureCount == 0 ? 0 : 1)
