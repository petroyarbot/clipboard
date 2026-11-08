import Foundation

/// Where NotchClip keeps agent data. Override with NOTCHCLIP_DATA_DIR (used by tests).
enum NotchClipDataLocation {
    static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["NOTCHCLIP_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchClip", isDirectory: true)
    }
}

struct Limits: Equatable {
    /// Percent left in the window; nil when there is no data or the window already expired.
    var fiveHourLeft: Int?
    var fiveHourReset: Date?
    var weekLeft: Int?
    var weekReset: Date?
    var updatedAt: Date
}

struct UsageSnapshot: Equatable {
    var claude: Limits?
    var codex: Limits?
}

enum UsageParser {
    /// Percent left in a window, plus its reset time when known.
    typealias Window = (left: Int?, reset: Date?)

    static let codexMarker = "\"limit_id\":\"codex\""

    private static let fractionalDates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainDates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    static func parseDate(_ text: String) -> Date? {
        fractionalDates.date(from: text) ?? plainDates.date(from: text)
    }

    /// A window whose reset time has passed has no known usage any more, so its percent is nil.
    static func window(_ value: Any?, now: Date, usedKey: String) -> Window? {
        guard let dict = value as? [String: Any], let used = number(dict[usedKey]) else { return nil }
        let reset = number(dict["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        if let reset, reset < now { return (nil, nil) }
        let left = min(100, max(0, 100 - used)).rounded()
        return (Int(left), reset)
    }

    static func claudeLimits(from data: Data, now: Date) -> Limits? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let five = window(root["five_hour"], now: now, usedKey: "used_percentage")
        let week = window(root["seven_day"], now: now, usedKey: "used_percentage")
        guard five != nil || week != nil else { return nil }
        let updated = number(root["updated_at"]).map { Date(timeIntervalSince1970: $0) } ?? now
        return Limits(
            fiveHourLeft: five?.left,
            fiveHourReset: five?.reset,
            weekLeft: week?.left,
            weekReset: week?.reset,
            updatedAt: updated
        )
    }

    /// Parses one Codex session log line. Only the entry with limit_id "codex" is used.
    static func codexEntry(fromLine line: String, now: Date) -> (timestamp: Date, limits: Limits)? {
        guard line.contains(codexMarker),
              let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stamp = root["timestamp"] as? String,
              let timestamp = parseDate(stamp),
              let rate = findCodexRateLimits(root)
        else { return nil }
        let primary = window(rate["primary"], now: now, usedKey: "used_percent")
        let secondary = window(rate["secondary"], now: now, usedKey: "used_percent")
        guard primary != nil || secondary != nil else { return nil }
        let limits = Limits(
            fiveHourLeft: primary?.left,
            fiveHourReset: primary?.reset,
            weekLeft: secondary?.left,
            weekReset: secondary?.reset,
            updatedAt: timestamp
        )
        return (timestamp, limits)
    }

    static func findCodexRateLimits(_ value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if dict["limit_id"] as? String == "codex" { return dict }
            for child in dict.values {
                if let found = findCodexRateLimits(child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findCodexRateLimits(child) { return found }
            }
        }
        return nil
    }

    /// Picks the Codex entry with the newest `timestamp` field among the given lines.
    static func newestCodexLimits<S: Sequence>(in lines: S, now: Date) -> Limits? where S.Element == String {
        var best: (timestamp: Date, limits: Limits)?
        for line in lines {
            guard let entry = codexEntry(fromLine: line, now: now) else { continue }
            if entry.timestamp > (best?.timestamp ?? .distantPast) { best = entry }
        }
        return best?.limits
    }
}

/// Reads the newest Codex rate-limit entry from ~/.codex/sessions.
/// Only the 10 most recently modified session files are considered, and only their last 256 KB.
/// Each file's newest limit line is cached by (mtime, size), so unchanged files are not read again.
/// Not thread-safe: one scan at a time (UsageMonitor guarantees this).
final class CodexLimitsReader: @unchecked Sendable {
    static let maxFiles = 10
    static let tailBytes = 256 * 1024

    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private struct Cached {
        let stamp: Stamp
        /// The raw line with the newest codex timestamp in the file tail, if any.
        let line: String?
    }

    private let sessionsDirectory: URL
    private var cache: [String: Cached] = [:]

    init(sessionsDirectory: URL) {
        self.sessionsDirectory = sessionsDirectory
    }

    func latestLimits(now: Date) -> Limits? {
        var best: (timestamp: Date, limits: Limits)?
        var seen = Set<String>()
        for file in recentFiles() {
            let key = file.url.path
            seen.insert(key)
            let line: String?
            if let cached = cache[key], cached.stamp == file.stamp {
                line = cached.line
            } else {
                line = Self.newestCodexLine(in: file.url)
                cache[key] = Cached(stamp: file.stamp, line: line)
            }
            // Parsed on every scan so that expired windows drop out as time passes.
            guard let line, let entry = UsageParser.codexEntry(fromLine: line, now: now) else { continue }
            if entry.timestamp > (best?.timestamp ?? .distantPast) { best = entry }
        }
        cache = cache.filter { seen.contains($0.key) }
        return best?.limits
    }

    private func recentFiles() -> [(url: URL, stamp: Stamp)] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, stamp: Stamp)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let stamp = Stamp(modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
            files.append((url, stamp))
        }
        files.sort { $0.stamp.modified > $1.stamp.modified }
        return Array(files.prefix(Self.maxFiles))
    }

    /// Reads only the last `tailBytes` of the file. A partial first line is dropped.
    static func tailLines(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var bytes = data
        if start > 0 {
            guard let newline = bytes.firstIndex(of: 0x0A) else { return [] }
            bytes = Data(bytes[(newline + 1)...])
        }
        return String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func newestCodexLine(in url: URL) -> String? {
        var best: (timestamp: Date, line: String)?
        for line in tailLines(of: url) where line.contains(UsageParser.codexMarker) {
            guard let entry = UsageParser.codexEntry(fromLine: line, now: Date()) else { continue }
            if entry.timestamp > (best?.timestamp ?? .distantPast) { best = (entry.timestamp, line) }
        }
        return best?.line
    }
}

/// Publishes Claude and Codex limits. claude-limits.json is re-read on data-directory changes (debounced to
/// at most once per second). Codex sessions are scanned only by the 30 s timer, on a background task.
@MainActor
final class UsageMonitor: ObservableObject {
    static let claudeDebounce: TimeInterval = 1

    @Published private(set) var snapshot = UsageSnapshot(claude: nil, codex: nil)

    let dataDirectory: URL
    let pollInterval: TimeInterval

    private let codexReader: CodexLimitsReader
    private var claude: Limits?
    private var codex: Limits?
    private var codexLoading = false
    private var claudeTask: Task<Void, Never>?
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?

    init(
        dataDirectory: URL = NotchClipDataLocation.directory,
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true),
        pollInterval: TimeInterval = 30
    ) {
        self.dataDirectory = dataDirectory
        self.codexReader = CodexLimitsReader(sessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true))
        self.pollInterval = pollInterval
    }

    func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        // The timer is the only trigger for Codex scans, so they run at most once per pollInterval.
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        watchDataDirectory()
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        claudeTask?.cancel()
        claudeTask = nil
        watcher?.cancel()
        watcher = nil
    }

    /// Re-reads Claude limits now and starts a Codex scan unless one is already running.
    func refresh() {
        refreshClaude()
        refreshCodex()
    }

    nonisolated static func loadClaude(url: URL, now: Date) -> Limits? {
        (try? Data(contentsOf: url)).flatMap { UsageParser.claudeLimits(from: $0, now: now) }
    }

    private func refreshClaude() {
        let url = dataDirectory.appendingPathComponent("claude-limits.json")
        Task.detached(priority: .utility) {
            let limits = UsageMonitor.loadClaude(url: url, now: Date())
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.claude = limits
                self.publish()
            }
        }
    }

    private func refreshCodex() {
        guard !codexLoading else { return }
        codexLoading = true
        let reader = codexReader
        Task.detached(priority: .utility) {
            let limits = reader.latestLimits(now: Date())
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.codexLoading = false
                self.codex = limits
                self.publish()
            }
        }
    }

    /// Watcher events arrive several times a second while the status line and hooks write.
    /// Coalesce them into one Claude read per debounce window.
    private func scheduleClaudeRefresh() {
        guard claudeTask == nil else { return }
        claudeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.claudeDebounce * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.claudeTask = nil
            self.refreshClaude()
        }
    }

    private func publish() {
        let next = UsageSnapshot(claude: claude, codex: codex)
        if snapshot != next { snapshot = next }
    }

    private func watchDataDirectory() {
        let descriptor = open(dataDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleClaudeRefresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}
