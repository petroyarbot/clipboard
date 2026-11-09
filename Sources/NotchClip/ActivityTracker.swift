import AppKit
import Foundation

/// Одно приложение в топе дня.
struct AppUsage: Equatable {
    let bundleID: String
    let name: String
    let seconds: TimeInterval
}

/// Итоги одного дня для UI.
struct DaySnapshot: Equatable {
    var activeSeconds: TimeInterval = 0
    var focusSeconds: TimeInterval = 0
    var sessions = 0
    /// До 5 приложений по убыванию времени.
    var topApps: [AppUsage] = []

    static let empty = DaySnapshot()
}

/// Запись одного дня на диске: `activity-YYYY-MM-DD.json`.
struct ActivityDayRecord: Codable, Equatable {
    var day: String
    /// bundle id -> активные секунды.
    var seconds: [String: Double] = [:]
    /// bundle id -> отображаемое имя.
    var names: [String: String] = [:]
    var focusSeconds: Double = 0
    var sessions = 0
}

/// Учёт экранного времени по приложениям. Только локально.
/// Время считается от `cursor` (до какого момента уже засчитано), поэтому тики можно сдвигать явно в тестах.
@MainActor
final class ActivityTracker: ObservableObject {
    /// Сколько секунд без ввода считаются ещё активной работой; дальше — пауза.
    static let idleThreshold: TimeInterval = 120
    static let retentionDays = 30
    static let flushInterval: TimeInterval = 60
    static let tickInterval: TimeInterval = 5
    static let topCount = 5

    /// Итоги сегодняшнего дня; обновляются при каждом изменении.
    @Published private(set) var today = DaySnapshot.empty

    private let dataDir: URL
    private let calendar: Calendar
    private let clock: () -> Date
    private let idleProvider: () -> TimeInterval

    /// Загруженные дни, ключ "YYYY-MM-DD".
    private var records: [String: ActivityDayRecord] = [:]
    private var dirtyDays: Set<String> = []
    private var lastFlush: Date?
    private var cursor: Date?
    private var current: (bundleID: String, name: String)?
    private var wasIdle = false
    private var screenAsleep = false
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []

    init(
        dataDir: URL,
        calendar: Calendar = .current,
        clock: @escaping () -> Date = { Date() },
        idleProvider: @escaping () -> TimeInterval = ActivityTracker.systemIdleSeconds
    ) {
        self.dataDir = dataDir
        self.calendar = calendar
        self.clock = clock
        self.idleProvider = idleProvider
        self.lastFlush = clock()
        pruneOldFiles(today: clock())
        today = snapshot(for: clock())
    }

    /// Секунды с последнего ввода (клавиатура, мышь) во всей сессии.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: - Жизненный цикл

    /// Подписка на смену приложения и сон экрана, плюс таймер тиков.
    func start() {
        let now = clock()
        let frontmost = NSWorkspace.shared.frontmostApplication
        current = frontmost.flatMap { app in
            app.bundleIdentifier.map { ($0, app.localizedName ?? $0) }
        }
        cursor = now
        wasIdle = false

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let name = app?.localizedName ?? bundleID ?? ""
            Task { @MainActor in self?.applicationActivated(bundleID: bundleID, name: name) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setScreenAsleep(true) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setScreenAsleep(false) }
        })

        // Screen lock and fast user switching: nothing is counted while the session is not on screen.
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setScreenAsleep(true) }
        })
        observers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setScreenAsleep(false) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setScreenAsleep(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setScreenAsleep(false) }
        })

        ticker = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Остановка: досчитать, записать на диск, снять подписки. Вызывать при выходе из приложения.
    func stop() {
        tick()
        ticker?.invalidate()
        ticker = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
        flush(now: clock())
    }

    // MARK: - События

    /// Тик по таймеру: засчитывает время до `clock()`.
    func tick() {
        advance(now: clock(), idleSeconds: idleProvider())
    }

    func applicationActivated(bundleID: String?, name: String) {
        let now = clock()
        advance(now: now, idleSeconds: idleProvider())
        current = bundleID.map { ($0, name.isEmpty ? $0 : name) }
    }

    func setScreenAsleep(_ asleep: Bool) {
        let now = clock()
        advance(now: now, idleSeconds: idleProvider())
        screenAsleep = asleep
        advance(now: now, idleSeconds: idleProvider())
    }

    /// Завершённая фокус-сессия длиной `seconds`. Каждый вызов — одна сессия.
    func addFocus(seconds: TimeInterval) {
        let key = dayKey(clock())
        var record = loadedRecord(key)
        record.focusSeconds += max(0, seconds)
        record.sessions += 1
        records[key] = record
        dirtyDays.insert(key)
        publishToday()
    }

    // MARK: - Чтение

    /// Итоги произвольного дня (для тестов и для "сегодня").
    func snapshot(for date: Date) -> DaySnapshot {
        let record = loadedRecord(dayKey(date))
        let usage = record.seconds
            .filter { $0.value > 0 }
            .map { AppUsage(bundleID: $0.key, name: record.names[$0.key] ?? $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
        return DaySnapshot(
            activeSeconds: usage.reduce(0) { $0 + $1.seconds },
            focusSeconds: record.focusSeconds,
            sessions: record.sessions,
            topApps: Array(usage.prefix(Self.topCount))
        )
    }

    // MARK: - Учёт

    /// Засчитывает время с `cursor` до `now` для текущего приложения, учитывая простой и сон экрана.
    /// Без ввода дольше `idleThreshold` время перестаёт идти с момента последнего ввода + порог.
    func advance(now: Date, idleSeconds: TimeInterval) {
        guard let last = cursor else {
            cursor = now
            return
        }
        let idle = max(0, idleSeconds)
        let inputAt = now.addingTimeInterval(-idle)
        let isIdle = screenAsleep || idle >= Self.idleThreshold

        if isIdle {
            if !wasIdle {
                let pauseAt = screenAsleep ? now : inputAt.addingTimeInterval(Self.idleThreshold)
                credit(from: last, to: clamp(pauseAt, last, now))
            }
            wasIdle = true
        } else {
            let start = wasIdle ? max(last, inputAt) : last
            credit(from: start, to: now)
            wasIdle = false
        }
        cursor = now
        flushIfDue(now: now)
        publishToday()
    }

    /// Делит интервал по полуночи и добавляет секунды текущему приложению в нужные дни.
    private func credit(from start: Date, to end: Date) {
        guard end > start, let current else { return }
        var from = start
        while from < end {
            let dayStart = calendar.startOfDay(for: from)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let to = min(end, nextDay)
            let key = dayKey(from)
            var record = loadedRecord(key)
            record.seconds[current.bundleID, default: 0] += to.timeIntervalSince(from)
            record.names[current.bundleID] = current.name
            records[key] = record
            dirtyDays.insert(key)
            from = to
        }
    }

    // MARK: - Хранение

    /// Записывает изменённые дни, если с прошлой записи прошло не меньше `flushInterval`.
    private func flushIfDue(now: Date) {
        guard !dirtyDays.isEmpty else { return }
        if let lastFlush, now.timeIntervalSince(lastFlush) < Self.flushInterval { return }
        flush(now: now)
    }

    private func flush(now: Date) {
        guard !dirtyDays.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for key in dirtyDays {
                guard let record = records[key] else { continue }
                let data = try encoder.encode(record)
                try data.write(to: fileURL(for: key), options: .atomic)
            }
            dirtyDays = []
            lastFlush = now
        } catch {
            // Данные остаются в памяти и будут записаны со следующей попыткой.
        }
    }

    private func loadedRecord(_ key: String) -> ActivityDayRecord {
        if let record = records[key] { return record }
        let url = fileURL(for: key)
        let loaded = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(ActivityDayRecord.self, from: $0) }
        let record = loaded ?? ActivityDayRecord(day: key)
        records[key] = record
        return record
    }

    /// Удаляет файлы старше `retentionDays` дней (считая сегодня как первый день).
    private func pruneOldFiles(today: Date) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dataDir.path) else { return }
        let todayStart = calendar.startOfDay(for: today)
        for name in names where name.hasPrefix(Self.filePrefix) && name.hasSuffix(Self.fileSuffix) {
            let key = String(name.dropFirst(Self.filePrefix.count).dropLast(Self.fileSuffix.count))
            guard let day = Self.date(fromKey: key, calendar: calendar),
                  let age = calendar.dateComponents([.day], from: day, to: todayStart).day,
                  age >= Self.retentionDays
            else { continue }
            try? FileManager.default.removeItem(at: dataDir.appendingPathComponent(name))
            records[key] = nil
        }
    }

    private func publishToday() {
        let next = snapshot(for: clock())
        if next != today { today = next }
    }

    // MARK: - Ключи дней

    static let filePrefix = "activity-"
    static let fileSuffix = ".json"

    private func fileURL(for key: String) -> URL {
        dataDir.appendingPathComponent("\(Self.filePrefix)\(key)\(Self.fileSuffix)")
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func clamp(_ date: Date, _ low: Date, _ high: Date) -> Date {
        min(max(date, low), high)
    }
}

/// Форматирование времени и счётчиков для UI. Чистые функции.
enum ActivityFormat {
    /// "2 ч 10 мин", "1 ч 05 мин", "12 мин", "0 мин".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0 { return String(format: "%d ч %02d мин", hours, rest) }
        return "\(rest) мин"
    }

    /// "1 сессия", "2 сессии", "5 сессий", "11 сессий".
    static func sessions(_ count: Int) -> String {
        let tens = count % 100
        let ones = count % 10
        let word: String
        if (11...14).contains(tens) {
            word = "сессий"
        } else if ones == 1 {
            word = "сессия"
        } else if (2...4).contains(ones) {
            word = "сессии"
        } else {
            word = "сессий"
        }
        return "\(count) \(word)"
    }
}
