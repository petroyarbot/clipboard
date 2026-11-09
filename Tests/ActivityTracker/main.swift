import Foundation

// Фейковые часы и простой: время и простой двигаются только явно.
final class FakeWorld {
    var now: Date
    var idle: TimeInterval = 0
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval, idle idleValue: TimeInterval = 0) {
        now = now.addingTimeInterval(seconds)
        idle = idleValue
    }
}

@MainActor
func makeTracker(_ dir: URL, _ world: FakeWorld, _ calendar: Calendar) -> ActivityTracker {
    ActivityTracker(
        dataDir: dir,
        calendar: calendar,
        clock: { world.now },
        idleProvider: { world.idle }
    )
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

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    let fileManager = FileManager.default
    func freshDir() -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("activity-tests-\(UUID().uuidString)")
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // 1. Форматирование.
    check(ActivityFormat.duration(2 * 3600 + 10 * 60) == "2 ч 10 мин", "duration 2 ч 10 мин")
    check(ActivityFormat.duration(3600 + 5 * 60) == "1 ч 05 мин", "duration pads minutes after hours")
    check(ActivityFormat.duration(12 * 60 + 59) == "12 мин", "duration under an hour is minutes only")
    check(ActivityFormat.duration(0) == "0 мин", "duration zero")
    check(ActivityFormat.sessions(1) == "1 сессия", "sessions 1")
    check(ActivityFormat.sessions(2) == "2 сессии", "sessions 2")
    check(ActivityFormat.sessions(4) == "4 сессии", "sessions 4")
    check(ActivityFormat.sessions(5) == "5 сессий", "sessions 5")
    check(ActivityFormat.sessions(11) == "11 сессий", "sessions 11 is genitive plural")
    check(ActivityFormat.sessions(21) == "21 сессия", "sessions 21")
    check(ActivityFormat.sessions(0) == "0 сессий", "sessions 0")

    // 2. Накопление, простой и сон экрана.
    do {
        let dir = freshDir()
        let world = FakeWorld(utc(2026, 11, 9, 12))
        let tracker = makeTracker(dir, world, calendar)
        tracker.applicationActivated(bundleID: "com.a", name: "App A")  // первый вызов ставит курсор
        world.advance(60)
        tracker.advance(now: world.now, idleSeconds: 0)
        world.advance(60)
        tracker.advance(now: world.now, idleSeconds: 0)
        var day = tracker.snapshot(for: world.now)
        check(day.activeSeconds == 120 && day.topApps.first?.seconds == 120, "active time accumulates per app")

        // Пользователь не трогает клавиатуру: первые 120 с простоя ещё считаются, дальше — пауза.
        world.advance(60, idle: 60)
        tracker.advance(now: world.now, idleSeconds: world.idle)
        world.advance(60, idle: 120)
        tracker.advance(now: world.now, idleSeconds: world.idle)
        check(tracker.snapshot(for: world.now).activeSeconds == 240, "idle counts only up to 120 s after last input")

        world.advance(60, idle: 180)
        tracker.advance(now: world.now, idleSeconds: world.idle)
        check(tracker.snapshot(for: world.now).activeSeconds == 240, "no time accrues while idle beyond threshold")

        // Возврат к работе: до ввода ничего не считается, после — считается.
        world.advance(30, idle: 30)
        tracker.advance(now: world.now, idleSeconds: world.idle)
        check(tracker.snapshot(for: world.now).activeSeconds == 270, "returning counts only from the last input")
        world.advance(30, idle: 0)
        tracker.advance(now: world.now, idleSeconds: world.idle)
        check(tracker.snapshot(for: world.now).activeSeconds == 300, "active again after input resumes accrual")

        // Экран погас: время не идёт, пока не включили.
        tracker.setScreenAsleep(true)
        world.advance(40, idle: 0)
        tracker.advance(now: world.now, idleSeconds: world.idle)
        check(tracker.snapshot(for: world.now).activeSeconds == 300, "screen sleep pauses accrual")
        tracker.setScreenAsleep(false)
        world.advance(30, idle: 0)
        tracker.advance(now: world.now, idleSeconds: world.idle)
        check(tracker.snapshot(for: world.now).activeSeconds == 330, "accrual resumes after screen wake")

        // Смена приложения: предыдущее получает время до переключения, новое — после.
        tracker.applicationActivated(bundleID: "com.b", name: "App B")
        world.advance(15, idle: 0)
        tracker.advance(now: world.now, idleSeconds: world.idle)
        day = tracker.snapshot(for: world.now)
        check(day.topApps.map(\.bundleID) == ["com.a", "com.b"], "top apps ordered by seconds")
        check(day.topApps.last?.seconds == 15 && day.topApps.last?.name == "App B", "switched app gets its own time and name")
    }

    // 3. Полночь: интервал делится по дням.
    do {
        let dir = freshDir()
        let world = FakeWorld(utc(2026, 11, 9, 23, 59, 30))
        let tracker = makeTracker(dir, world, calendar)
        tracker.applicationActivated(bundleID: "com.c", name: "C")
        world.advance(150, idle: 0)
        tracker.advance(now: world.now, idleSeconds: 0)
        check(tracker.snapshot(for: utc(2026, 11, 9)).activeSeconds == 30, "midnight rollover: 30 s before midnight go to the old day")
        check(tracker.snapshot(for: utc(2026, 11, 10)).activeSeconds == 120, "midnight rollover: 120 s after midnight go to the new day")
    }

    // 4. Фокус и сессии.
    do {
        let dir = freshDir()
        let world = FakeWorld(utc(2026, 11, 9, 9))
        let tracker = makeTracker(dir, world, calendar)
        tracker.addFocus(seconds: 1500)
        tracker.addFocus(seconds: 600)
        let day = tracker.snapshot(for: world.now)
        check(day.focusSeconds == 2100 && day.sessions == 2, "addFocus accumulates seconds and sessions")
        check(tracker.today.focusSeconds == 2100, "today published after addFocus")
    }

    // 5. Топ-5 приложений.
    do {
        let dir = freshDir()
        let world = FakeWorld(utc(2026, 11, 9, 9))
        let tracker = makeTracker(dir, world, calendar)
        tracker.applicationActivated(bundleID: "app.0", name: "Zero")
        for index in 1...6 {
            world.advance(TimeInterval(index * 10), idle: 0)
            tracker.applicationActivated(bundleID: "app.\(index)", name: "App \(index)")
        }
        world.advance(5, idle: 0)
        tracker.advance(now: world.now, idleSeconds: 0)
        let top = tracker.snapshot(for: world.now).topApps
        check(top.count == 5, "top apps capped at five")
        check(top.first?.bundleID == "app.5", "top app is the longest one")
        check(!top.contains { $0.bundleID == "app.0" || $0.bundleID == "app.6" }, "two shortest apps dropped from top five")
    }

    // 6. Запись на диск: не чаще раза в минуту, при stop — сразу; данные переживают перезапуск.
    do {
        let dir = freshDir()
        let world = FakeWorld(utc(2026, 11, 9, 9))
        let tracker = makeTracker(dir, world, calendar)
        tracker.applicationActivated(bundleID: "com.d", name: "D")
        world.advance(30, idle: 0)
        tracker.advance(now: world.now, idleSeconds: 0)
        let file = dir.appendingPathComponent("activity-2026-11-09.json")
        check(!fileManager.fileExists(atPath: file.path), "no write within the first minute")
        world.advance(40, idle: 0)
        tracker.advance(now: world.now, idleSeconds: 0)
        check(fileManager.fileExists(atPath: file.path), "write happens after a minute")
        world.advance(20, idle: 0)
        tracker.advance(now: world.now, idleSeconds: 0)
        tracker.stop()
        let reloaded = makeTracker(dir, world, calendar)
        check(reloaded.snapshot(for: world.now).activeSeconds == 90, "persisted seconds survive a restart")
    }

    // 7. Удаление файлов старше 30 дней.
    do {
        let dir = freshDir()
        let world = FakeWorld(utc(2026, 11, 9, 9))
        for day in ["2026-10-09", "2026-10-10", "2026-10-11", "2026-11-09"] {
            _ = fileManager.createFile(atPath: dir.appendingPathComponent("activity-\(day).json").path, contents: Data("{}".utf8))
        }
        _ = makeTracker(dir, world, calendar)
        let names = Set((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [])
        check(!names.contains("activity-2026-10-09.json"), "31-day-old file pruned")
        check(!names.contains("activity-2026-10-10.json"), "30-day-old file pruned")
        check(names.contains("activity-2026-10-11.json"), "29-day-old file kept")
        check(names.contains("activity-2026-11-09.json"), "today's file kept")
    }

    return failures
}

let failureCount = MainActor.assumeIsolated { runTests() }
print(failureCount == 0 ? "All activity tracker tests passed" : "\(failureCount) activity tracker check(s) failed")
exit(failureCount == 0 ? 0 : 1)
