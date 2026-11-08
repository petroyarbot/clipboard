import Foundation

enum AgentState: String, Equatable {
    case running
    case needsAction
    case done
}

/// One line of agents.jsonl, written by scripts/agent-hooks.
struct AgentEvent: Equatable {
    let source: String
    let event: String
    let session: String
    let cwd: String
    let type: String?
    let message: String
    let time: Date
}

struct AgentTask: Identifiable, Equatable {
    let id: String
    let source: String
    let project: String
    let message: String
    let state: AgentState
    let updatedAt: Date
}

enum AgentReducer {
    static let staleAfter: TimeInterval = 12 * 3600
    static let needsActionTypes: Set<String> = ["permission_prompt", "idle_prompt"]

    enum Transition: Equatable {
        case set(AgentState)
        case remove
        case ignore
    }

    static func parseLine(_ line: String) -> AgentEvent? {
        guard let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let source = root["source"] as? String, !source.isEmpty,
              let event = root["event"] as? String, !event.isEmpty,
              let time = UsageParser.number(root["time"])
        else { return nil }
        return AgentEvent(
            source: source,
            event: event,
            session: root["session"] as? String ?? "",
            cwd: root["cwd"] as? String ?? "",
            type: root["type"] as? String,
            message: root["message"] as? String ?? "",
            time: Date(timeIntervalSince1970: time)
        )
    }

    static func key(for event: AgentEvent) -> String {
        "\(event.source):\(event.session.isEmpty ? event.cwd : event.session)"
    }

    static func transition(for event: AgentEvent) -> Transition {
        switch event.event {
        case "SessionStart", "UserPromptSubmit", "PostToolUse":
            return .set(.running)
        case "Notification":
            let type = event.type ?? ""
            if needsActionTypes.contains(type) || type.hasPrefix("elicitation") {
                return .set(.needsAction)
            }
            return .ignore
        case "Stop", "turn-complete":
            return .set(.done)
        case "SessionEnd":
            return .remove
        default:
            return .ignore
        }
    }

    static func projectName(cwd: String) -> String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func rank(_ state: AgentState) -> Int {
        switch state {
        case .needsAction: return 0
        case .running: return 1
        case .done: return 2
        }
    }

    /// Reduces events to visible tasks. `dismissed` maps task id to the time it was dismissed;
    /// a task stays hidden until an event newer than that time arrives.
    static func reduce(_ events: [AgentEvent], now: Date, dismissed: [String: Double] = [:]) -> [AgentTask] {
        struct Record {
            var source: String
            var project: String
            var message: String
            var state: AgentState
            var updatedAt: Date
        }

        let ordered = events.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)

        var records: [String: Record] = [:]
        for event in ordered {
            let key = key(for: event)
            switch transition(for: event) {
            case .set(let state):
                var record = records[key] ?? Record(source: event.source, project: "", message: "", state: state, updatedAt: event.time)
                record.state = state
                record.updatedAt = event.time
                record.message = event.message
                if !event.cwd.isEmpty { record.project = projectName(cwd: event.cwd) }
                records[key] = record
            case .remove:
                records[key] = nil
            case .ignore:
                break
            }
        }

        var tasks: [AgentTask] = []
        for (key, record) in records where now.timeIntervalSince(record.updatedAt) <= staleAfter {
            if let dismissedAt = dismissed[key], record.updatedAt.timeIntervalSince1970 <= dismissedAt { continue }
            tasks.append(AgentTask(
                id: key,
                source: record.source,
                project: record.project,
                message: record.message,
                state: record.state,
                updatedAt: record.updatedAt
            ))
        }

        return tasks.sorted { lhs, rhs in
            let lhsRank = rank(lhs.state), rhsRank = rank(rhs.state)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

/// Reads agents.jsonl from a byte offset. Only complete lines are consumed.
enum AgentLogReader {
    struct Chunk: Equatable {
        var events: [AgentEvent]
        var offset: UInt64
        /// True when the file shrank or disappeared, so the caller must drop what it has read so far.
        var truncated: Bool
    }

    static func read(url: URL, from offset: UInt64) -> Chunk {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Chunk(events: [], offset: 0, truncated: true)
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        var start = offset
        var truncated = false
        if size < offset {
            start = 0
            truncated = true
        }
        guard size > start else {
            return Chunk(events: [], offset: start, truncated: truncated)
        }

        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return Chunk(events: [], offset: start, truncated: truncated)
        }
        let complete = data[data.startIndex...lastNewline]
        let text = String(decoding: complete, as: UTF8.self)
        let events = text.split(separator: "\n").compactMap { AgentReducer.parseLine(String($0)) }
        return Chunk(events: events, offset: start + UInt64(complete.count), truncated: truncated)
    }
}

/// Tails agents.jsonl and publishes the reduced task list. Dismissals persist in UserDefaults.
@MainActor
final class AgentMonitor: ObservableObject {
    static let maxEvents = 5000
    static let dismissedKey = "NotchClip.dismissedAgentTasks"

    @Published private(set) var tasks: [AgentTask] = []
    @Published private(set) var dismissed: [String: Double]

    let fileURL: URL
    private let defaults: UserDefaults
    private var events: [AgentEvent] = []
    private var offset: UInt64 = 0
    private var loading = false
    private var timer: Timer?

    var needsActionCount: Int {
        tasks.filter { $0.state == .needsAction }.count
    }

    init(dataDirectory: URL = NotchClipDataLocation.directory, defaults: UserDefaults = .standard) {
        self.fileURL = dataDirectory.appendingPathComponent("agents.jsonl")
        self.defaults = defaults
        self.dismissed = (defaults.dictionary(forKey: Self.dismissedKey) as? [String: Double]) ?? [:]
    }

    func start(interval: TimeInterval = 2) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        let url = fileURL
        let start = offset
        Task.detached(priority: .utility) {
            let chunk = AgentLogReader.read(url: url, from: start)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading = false
                self.apply(chunk)
            }
        }
    }

    /// Hides a task until a newer event for it arrives.
    func dismiss(_ id: String) {
        let now = Date().timeIntervalSince1970
        var next = dismissed.filter { now - $0.value < AgentReducer.staleAfter }
        next[id] = now
        dismissed = next
        defaults.set(next, forKey: Self.dismissedKey)
        recompute()
    }

    private func apply(_ chunk: AgentLogReader.Chunk) {
        if chunk.truncated { events.removeAll() }
        offset = chunk.offset
        events.append(contentsOf: chunk.events)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
        recompute()
    }

    private func recompute() {
        tasks = AgentReducer.reduce(events, now: Date(), dismissed: dismissed)
    }
}
