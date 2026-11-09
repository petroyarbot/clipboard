import Foundation

// Standalone checks for UsageMonitor.swift and AgentMonitor.swift.
// Built and run by scripts/test-agents.sh.

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

let fm = FileManager.default
let now = Date()
let nowEpoch = Int(now.timeIntervalSince1970)
let futureEpoch = nowEpoch + 3600
let pastEpoch = nowEpoch - 600
let root = fm.temporaryDirectory.appendingPathComponent("notchclip-agent-tests-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)

func isoString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

func data(_ text: String) -> Data { Data(text.utf8) }

// MARK: - Claude limits

let claudeFresh = data("""
{"five_hour":{"used_percentage":37,"resets_at":\(futureEpoch)},"seven_day":{"used_percentage":12.5,"resets_at":\(futureEpoch)},"updated_at":\(nowEpoch)}
""")
if let limits = UsageParser.claudeLimits(from: claudeFresh, now: now) {
    check(limits.fiveHourLeft == 63, "claude 5h left = 100 - 37")
    check(limits.weekLeft == 88, "claude week left rounds 87.5 up to 88")
    check(limits.fiveHourReset?.timeIntervalSince1970 == Double(futureEpoch), "claude 5h reset date parsed")
    check(limits.updatedAt.timeIntervalSince1970 == Double(nowEpoch), "claude updated_at parsed")
} else {
    check(false, "claude fresh file parses")
}

let claudeExpired = data("""
{"five_hour":{"used_percentage":80,"resets_at":\(pastEpoch)},"seven_day":{"used_percentage":30,"resets_at":\(futureEpoch)},"updated_at":\(nowEpoch)}
""")
if let limits = UsageParser.claudeLimits(from: claudeExpired, now: now) {
    check(limits.fiveHourLeft == nil, "expired claude 5h window has no percent")
    check(limits.fiveHourReset == nil, "expired claude 5h window has unknown reset")
    check(limits.weekLeft == 70, "live claude week window is kept when 5h expired")
} else {
    check(false, "claude file with expired window parses")
}

let claudeClamp = data("""
{"five_hour":{"used_percentage":150,"resets_at":\(futureEpoch)},"seven_day":{"used_percentage":-5,"resets_at":\(futureEpoch)},"updated_at":\(nowEpoch)}
""")
if let limits = UsageParser.claudeLimits(from: claudeClamp, now: now) {
    check(limits.fiveHourLeft == 0, "claude used > 100 clamps to 0 left")
    check(limits.weekLeft == 100, "claude used < 0 clamps to 100 left")
} else {
    check(false, "claude clamp file parses")
}

let claudeMissingWindows = data(#"{"five_hour":null,"seven_day":null,"updated_at":1}"#)
check(UsageParser.claudeLimits(from: claudeMissingWindows, now: now) == nil, "claude file without windows yields no limits")

// MARK: - Codex limits

func codexLine(timestamp: String, limitId: String, primaryUsed: Double, secondaryUsed: Double, resets: Int, weekResets: Int? = nil) -> String {
    let weekReset = weekResets ?? resets
    return """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"\(limitId)","primary":{"used_percent":\(primaryUsed),"window_minutes":300,"resets_at":\(resets)},"secondary":{"used_percent":\(secondaryUsed),"window_minutes":10080,"resets_at":\(weekReset)}}}}
    """
}

let sessions = root.appendingPathComponent("codex/sessions/2026/11/09", isDirectory: true)
try fm.createDirectory(at: sessions, withIntermediateDirectories: true)

// File A is modified most recently but holds the OLDER timestamp.
let fileA = sessions.appendingPathComponent("rollout-a.jsonl")
let fileALines = [
    codexLine(timestamp: "2026-11-08T10:00:00.000Z", limitId: "codex", primaryUsed: 20, secondaryUsed: 40, resets: futureEpoch),
    // Premium entries must be ignored even though their timestamp is the newest.
    #"{"timestamp":"2026-11-09T12:00:00.000Z","type":"event_msg","payload":{"rate_limits":{"limit_id":"premium","primary":{"used_percent":99,"resets_at":\#(futureEpoch)}}}}"#,
].joined(separator: "\n") + "\n"
try fileALines.write(to: fileA, atomically: true, encoding: .utf8)
try fm.setAttributes([.modificationDate: now], ofItemAtPath: fileA.path)

// File B is older by mtime but holds the NEWEST codex timestamp.
let fileB = sessions.appendingPathComponent("rollout-b.jsonl")
let fileBLines = [
    #"{"timestamp":"2026-11-09T07:00:00.000Z","type":"event_msg","payload":{"text":"no limits here"}}"#,
    codexLine(timestamp: "2026-11-09T08:00:00.000Z", limitId: "codex", primaryUsed: 70, secondaryUsed: 10, resets: futureEpoch),
].joined(separator: "\n") + "\n"
try fileBLines.write(to: fileB, atomically: true, encoding: .utf8)
try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: fileB.path)

let codexHome = root.appendingPathComponent("codex", isDirectory: true)
let codexReader = CodexLimitsReader(sessionsDirectory: codexHome.appendingPathComponent("sessions"))
let codexLatest = codexReader.latestLimits(now: now)
check(codexLatest?.fiveHourLeft == 30, "codex picks newest timestamp, not newest mtime (5h left = 30)")
check(codexLatest?.weekLeft == 90, "codex secondary window is the weekly limit")
check(codexLatest?.updatedAt == UsageParser.parseDate("2026-11-09T08:00:00.000Z"), "codex updatedAt is the entry timestamp")

let codexExpiredLine = codexLine(timestamp: "2026-11-09T09:00:00.000Z", limitId: "codex", primaryUsed: 55, secondaryUsed: 60, resets: pastEpoch, weekResets: futureEpoch)
let codexExpired = UsageParser.newestCodexLimits(in: [codexExpiredLine], now: now)
check(codexExpired?.fiveHourLeft == nil, "expired codex 5h window has no percent")
check(codexExpired?.fiveHourReset == nil, "expired codex 5h window has unknown reset")
check(codexExpired?.weekLeft == 40, "live codex week window keeps its value")

let codexPremiumOnly = #"{"timestamp":"2026-11-09T12:00:00.000Z","payload":{"rate_limits":{"limit_id":"premium","primary":{"used_percent":99,"resets_at":\#(futureEpoch)}}}}"#
check(UsageParser.newestCodexLimits(in: [codexPremiumOnly], now: now) == nil, "premium-only entries yield no codex limits")

// MARK: - Missing files

let emptyDir = root.appendingPathComponent("empty", isDirectory: true)
try fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
let missingClaude = UsageMonitor.loadClaude(url: emptyDir.appendingPathComponent("claude-limits.json"), now: now)
let missingCodex = CodexLimitsReader(sessionsDirectory: root.appendingPathComponent("does-not-exist")).latestLimits(now: now)
check(missingClaude == nil && missingCodex == nil, "missing data files produce no limits")

// MARK: - Codex reader: throttled file set, tail read, mtime/size cache

let cacheDir = root.appendingPathComponent("cache-sessions", isDirectory: true)
try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
let cachedFile = cacheDir.appendingPathComponent("rollout-cache.jsonl")
let cachedStamp = now.addingTimeInterval(-60)
try (codexLine(timestamp: "2026-11-09T08:00:00.000Z", limitId: "codex", primaryUsed: 10, secondaryUsed: 10, resets: futureEpoch) + "\n")
    .write(to: cachedFile, atomically: true, encoding: .utf8)
try fm.setAttributes([.modificationDate: cachedStamp], ofItemAtPath: cachedFile.path)
let cacheReader = CodexLimitsReader(sessionsDirectory: cacheDir)
check(cacheReader.latestLimits(now: now)?.fiveHourLeft == 90, "codex reader reads a new session file")

// Same size and mtime but different content: the cached result must be reused, proving the file was not re-read.
let sameSize = codexLine(timestamp: "2026-11-09T08:00:00.000Z", limitId: "codex", primaryUsed: 50, secondaryUsed: 10, resets: futureEpoch) + "\n"
let originalSize = try Data(contentsOf: cachedFile).count
precondition(sameSize.utf8.count == originalSize, "fixture must keep the same size")
try sameSize.write(to: cachedFile, atomically: true, encoding: .utf8)
try fm.setAttributes([.modificationDate: cachedStamp], ofItemAtPath: cachedFile.path)
check(cacheReader.latestLimits(now: now)?.fiveHourLeft == 90, "unchanged mtime and size reuse the cached line")

// A changed mtime makes the reader scan the file again.
try fm.setAttributes([.modificationDate: now], ofItemAtPath: cachedFile.path)
check(cacheReader.latestLimits(now: now)?.fiveHourLeft == 50, "changed mtime triggers a fresh read")

// Only the last 256 KB are read: a newer entry buried before the tail is ignored.
let buriedFile = cacheDir.appendingPathComponent("rollout-buried.jsonl")
let oldBuried = codexLine(timestamp: "2026-11-09T11:00:00.000Z", limitId: "codex", primaryUsed: 5, secondaryUsed: 5, resets: futureEpoch)
let filler = String(repeating: "x", count: 1000) + "\n"
var buriedText = oldBuried + "\n"
for _ in 0..<400 { buriedText += filler }  // about 400 KB of plain lines after the entry
try buriedText.write(to: buriedFile, atomically: true, encoding: .utf8)
try fm.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: buriedFile.path)
check(CodexLimitsReader.newestCodexLine(in: buriedFile) == nil, "entries before the 256 KB tail are not read")

// Only the 10 most recently modified files are scanned.
let manyDir = root.appendingPathComponent("many-sessions", isDirectory: true)
try fm.createDirectory(at: manyDir, withIntermediateDirectories: true)
for index in 0..<11 {
    let file = manyDir.appendingPathComponent("rollout-\(index).jsonl")
    // File 10 is the oldest by mtime (outside the 10 newest) but holds the newest codex timestamp.
    let stamp = index == 10 ? "2026-11-09T20:00:00.000Z" : "2026-11-09T09:00:00.000Z"
    try (codexLine(timestamp: stamp, limitId: "codex", primaryUsed: Double(index), secondaryUsed: 0, resets: futureEpoch) + "\n")
        .write(to: file, atomically: true, encoding: .utf8)
    try fm.setAttributes([.modificationDate: now.addingTimeInterval(-Double(index) * 60)], ofItemAtPath: file.path)
}
let manyLimits = CodexLimitsReader(sessionsDirectory: manyDir).latestLimits(now: now)
check(manyLimits?.updatedAt == UsageParser.parseDate("2026-11-09T09:00:00.000Z"), "only the 10 newest session files are scanned")

// MARK: - Agent reducer

let base = Double(nowEpoch - 100)

func agentLine(_ source: String, _ event: String, _ session: String, cwd: String = "", type: String? = nil, message: String = "", at time: Double) -> String {
    var object: [String: Any] = [
        "source": source, "event": event, "session": session,
        "cwd": cwd, "message": message, "time": Int(time),
    ]
    if let type { object["type"] = type } else { object["type"] = NSNull() }
    let encoded = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: encoded, as: UTF8.self)
}

let agentLines = [
    agentLine("claude", "SessionStart", "s1", cwd: "/work/alpha", at: base),
    agentLine("claude", "UserPromptSubmit", "s2", cwd: "/work/beta", at: base + 1),
    agentLine("claude", "Notification", "s2", cwd: "/work/beta", type: "permission_prompt", message: "Allow Bash?", at: base + 2),
    agentLine("claude", "Stop", "s3", cwd: "/work/gamma", at: base + 3),
    agentLine("codex", "turn-complete", "thr-x", cwd: "/work/codexproj", message: "готово", at: base + 4),
    agentLine("claude", "Notification", "s1", cwd: "/work/alpha", type: "auth_success", at: base + 5),
    agentLine("claude", "SessionStart", "s4", cwd: "/work/delta", at: base + 1),
    agentLine("claude", "SessionEnd", "s4", cwd: "/work/delta", at: base + 6),
    agentLine("claude", "Notification", "s5", cwd: "/work/eps", type: "elicitation_dialog", at: base + 0.5),
]
let parsed = agentLines.compactMap { AgentReducer.parseLine($0) }
check(parsed.count == agentLines.count, "every agent line parses")
check(AgentReducer.parseLine("not json") == nil, "garbage line is skipped")
check(AgentReducer.parseLine(#"{"source":"claude","event":"Stop"}"#) == nil, "line without time is skipped")

// Feed events reversed to prove the reducer orders by time.
let tasks = AgentReducer.reduce(Array(parsed.reversed()), now: now)
check(tasks.map(\.id) == ["claude:s2", "claude:s5", "claude:s1", "codex:thr-x", "claude:s3"],
      "needsAction first, then running, then done; newest first within a group")
check(tasks.first?.project == "beta" && tasks.first?.message == "Allow Bash?", "task carries project and message")
check(tasks.filter { $0.state == .needsAction }.count == 2, "needsAction count includes elicitation prompts")
check(!tasks.contains { $0.id == "claude:s4" }, "SessionEnd removes the task")
check(tasks.first { $0.id == "claude:s1" }?.state == .running, "auth_success notification leaves state unchanged")
check(tasks.first { $0.id == "codex:thr-x" }?.state == .done, "codex turn-complete is done")

let staleEvent = AgentReducer.parseLine(agentLine("claude", "Stop", "old", cwd: "/work/old", at: now.timeIntervalSince1970 - 13 * 3600))!
let freshEvent = AgentReducer.parseLine(agentLine("claude", "Stop", "new", cwd: "/work/new", at: now.timeIntervalSince1970 - 11 * 3600))!
let staleTasks = AgentReducer.reduce([staleEvent, freshEvent], now: now)
check(staleTasks.map(\.id) == ["claude:new"], "tasks older than 12 h are dropped")

// PostToolUse means the agent resumed after a Notification, so the task is running again.
let waiting = AgentReducer.parseLine(agentLine("claude", "Notification", "p1", cwd: "/work/p", type: "permission_prompt", at: base + 20))!
let resumed = AgentReducer.parseLine(agentLine("claude", "PostToolUse", "p1", cwd: "/work/p", at: base + 21))!
check(AgentReducer.transition(for: resumed) == .set(.running), "PostToolUse maps to running")
check(AgentReducer.reduce([waiting, resumed], now: now).first { $0.id == "claude:p1" }?.state == .running,
      "PostToolUse after a permission prompt clears needs-action")

let dismissedMap = ["claude:s2": base + 2]
let hidden = AgentReducer.reduce(parsed, now: now, dismissed: dismissedMap)
check(!hidden.contains { $0.id == "claude:s2" }, "dismissed task stays hidden while no newer event exists")
let revived = AgentReducer.reduce(parsed + [AgentReducer.parseLine(agentLine("claude", "Stop", "s2", cwd: "/work/beta", at: base + 10))!],
                                  now: now, dismissed: dismissedMap)
check(revived.first { $0.id == "claude:s2" }?.state == .done, "a newer event brings a dismissed task back")

// MARK: - Log reader (incremental tail)

let logURL = root.appendingPathComponent("agents.jsonl")
let firstTwo = agentLines[0] + "\n" + agentLines[1] + "\n"
let partial = agentLines[2]
try (firstTwo + partial).write(to: logURL, atomically: true, encoding: .utf8)
let firstChunk = AgentLogReader.read(url: logURL, from: 0)
check(firstChunk.events.count == 2, "reader returns only complete lines")
check(firstChunk.offset == UInt64(firstTwo.utf8.count), "reader offset stops before the partial line")
check(!firstChunk.truncated, "growing file is not reported as truncated")

try (firstTwo + partial + "\n").write(to: logURL, atomically: true, encoding: .utf8)
let secondChunk = AgentLogReader.read(url: logURL, from: firstChunk.offset)
check(secondChunk.events.count == 1 && secondChunk.events.first?.event == "Notification", "reader resumes at the saved offset")

try (agentLines[3] + "\n").write(to: logURL, atomically: true, encoding: .utf8)
let shrunk = AgentLogReader.read(url: logURL, from: secondChunk.offset)
check(shrunk.truncated && shrunk.events.count == 1, "shrunk file is re-read from the start and flagged")

let absent = AgentLogReader.read(url: root.appendingPathComponent("nope.jsonl"), from: 10)
check(absent.events.isEmpty && absent.offset == 0 && absent.truncated, "missing log resets the offset")

// MARK: - Monitor end to end (dismiss persistence)

@MainActor
func monitorChecks(dataDirectory: URL) async throws {
    let suiteName = "notchclip-agent-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    try (agentLines.joined(separator: "\n") + "\n").write(to: dataDirectory.appendingPathComponent("agents.jsonl"), atomically: true, encoding: .utf8)
    let monitor = AgentMonitor(dataDirectory: dataDirectory, defaults: defaults)
    monitor.refresh()
    var waited = 0
    while monitor.tasks.isEmpty && waited < 100 {
        try await Task.sleep(nanoseconds: 20_000_000)
        waited += 1
    }
    check(monitor.tasks.map(\.id).first == "claude:s2", "monitor loads agents.jsonl off the main thread")
    check(monitor.needsActionCount == 2, "monitor counts needs-action tasks")

    monitor.dismiss("claude:s2")
    check(!monitor.tasks.contains { $0.id == "claude:s2" }, "dismiss hides the task immediately")
    check(monitor.needsActionCount == 1, "dismissed task leaves the needs-action count")

    let reloaded = AgentMonitor(dataDirectory: dataDirectory, defaults: defaults)
    check(reloaded.dismissed["claude:s2"] != nil, "dismissal persists in UserDefaults")
    reloaded.refresh()
    waited = 0
    while reloaded.tasks.isEmpty && waited < 100 {
        try await Task.sleep(nanoseconds: 20_000_000)
        waited += 1
    }
    check(!reloaded.tasks.contains { $0.id == "claude:s2" }, "dismissed task stays hidden after restart")
}

try await monitorChecks(dataDirectory: root)

// MARK: - Claude usage API (fake token provider and fake transport, no network)

final class FakeUsageTransport: UsageTransport, @unchecked Sendable {
    let status: Int
    let body: Data
    private(set) var requests: [URLRequest] = []

    init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        requests.append(request)
        return (status, body)
    }
}

let apiToken = "fake-token-for-tests"
let fakeLogin: ClaudeTokenProvider = {
    .found(ClaudeCredentials(accessToken: apiToken, expiresAt: Date(timeIntervalSinceNow: 3600)))
}
let missingLogin: ClaudeTokenProvider = { .notLoggedIn }
let expiredLogin: ClaudeTokenProvider = {
    .found(ClaudeCredentials(accessToken: apiToken, expiresAt: Date(timeIntervalSinceNow: -60)))
}
let sampleAPI = data("""
{"five_hour":{"utilization":37.5,"resets_at":"2030-01-01T00:00:00.123456+00:00"},"seven_day":null,"seven_day_opus":null}
""")
let resetEpoch = 1893456000.0  // 2030-01-01T00:00:00Z

let parsedAPI = ClaudeUsageResponse.limits(from: sampleAPI, now: now)
check(parsedAPI?.fiveHourLeft == 62, "api utilization 37.5 leaves 62 percent")
check(parsedAPI?.weekLeft == nil, "api null seven_day leaves the week unknown")
check(parsedAPI?.weekReset == nil, "api null seven_day has no reset")
check(parsedAPI?.updatedAt == now, "api limits are stamped with the fetch time")
check(parsedAPI?.fiveHourReset != nil && abs((parsedAPI?.fiveHourReset?.timeIntervalSince1970 ?? 0) - (resetEpoch + 0.123456)) < 0.001, "api microsecond resets_at parses")

check(UsageParser.parseDate("2030-01-01T00:00:00Z")?.timeIntervalSince1970 == resetEpoch, "ISO date without fraction parses")
check(UsageParser.parseDate("2030-01-01T00:00:00.500Z")?.timeIntervalSince1970 == resetEpoch + 0.5, "ISO date with milliseconds parses")
check(UsageParser.parseDate("2030-01-01T00:00:00.123456+00:00") != nil, "ISO date with microseconds parses")
check(ClaudeUsageResponse.limits(from: data(#"{"five_hour":null,"seven_day":null}"#), now: now) == nil, "response without windows is a failure")

let parsedKeychain = ClaudeKeychain.parse(data(#"{"claudeAiOauth":{"accessToken":"fake-token-for-tests","expiresAt":1893456000000}}"#))
if case .found(let creds) = parsedKeychain {
    check(creds.accessToken == apiToken && creds.expiresAt?.timeIntervalSince1970 == resetEpoch, "keychain JSON yields token and ms expiry")
} else {
    check(false, "keychain JSON with token parses")
}
check(ClaudeKeychain.parse(data(#"{"claudeAiOauth":{}}"#)) == .notLoggedIn, "keychain JSON without token means notLoggedIn")

let noItemTransport = FakeUsageTransport(status: 200, body: sampleAPI)
let noItem = await ClaudeUsageClient(tokenProvider: missingLogin, transport: noItemTransport).fetch(now: now)
check(noItem == .notLoggedIn && noItemTransport.requests.isEmpty, "missing keychain item means notLoggedIn without a request")

let expiredTransport = FakeUsageTransport(status: 200, body: sampleAPI)
let expired = await ClaudeUsageClient(tokenProvider: expiredLogin, transport: expiredTransport).fetch(now: now)
check(expired == .tokenExpired && expiredTransport.requests.isEmpty, "expired token means tokenExpired without a request")

let okTransport = FakeUsageTransport(status: 200, body: sampleAPI)
let okFetch = await ClaudeUsageClient(tokenProvider: fakeLogin, transport: okTransport).fetch(now: now)
check(okFetch == .success(parsedAPI!), "200 response is parsed into limits")
let sent = okTransport.requests.first
check(okTransport.requests.count == 1, "one request per fetch")
check(sent?.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage", "request goes to the usage endpoint")
check(sent?.httpMethod == "GET", "request is a GET")
check(sent?.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiToken)", "request carries the bearer token")
check(sent?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20", "request sends the oauth beta header")
check(sent?.value(forHTTPHeaderField: "User-Agent") == "NotchClip", "request identifies NotchClip")
check(sent?.timeoutInterval == 10, "request timeout is 10 s")

for code in [401, 403] {
    let transport = FakeUsageTransport(status: code)
    let result = await ClaudeUsageClient(tokenProvider: fakeLogin, transport: transport).fetch(now: now)
    check(result == .tokenExpired, "HTTP \(code) means tokenExpired")
}
let limitedTransport = FakeUsageTransport(status: 429)
let limited = await ClaudeUsageClient(tokenProvider: fakeLogin, transport: limitedTransport).fetch(now: now)
check(limited == .rateLimited, "HTTP 429 means rateLimited")

// Backoff: 429 doubles the interval up to 30 min; success returns it to 5 min.
var backoff = ClaudeApiState()
check(backoff.interval == 300, "claude API starts at 5 min")
backoff.apply(.rateLimited, now: now)
check(backoff.interval == 600, "429 doubles the interval to 10 min")
backoff.apply(.rateLimited, now: now)
check(backoff.interval == 1200, "second 429 doubles the interval to 20 min")
backoff.apply(.rateLimited, now: now)
backoff.apply(.rateLimited, now: now)
check(backoff.interval == 1800, "interval stops at 30 min")
backoff.apply(.success(parsedAPI!), now: now)
check(backoff.interval == 300, "success resets the interval to 5 min")
check(backoff.isDue(now: now) == false && backoff.isDue(now: now.addingTimeInterval(301)), "next fetch is due after the interval")

// Failures keep the last good values.
var kept = ClaudeApiState()
kept.apply(.success(parsedAPI!), now: now)
kept.apply(.failure("Нет связи с сервером Claude"), now: now.addingTimeInterval(300))
check(kept.limits == parsedAPI, "failure keeps the last good values")
check(kept.status == .error("Нет связи с сервером Claude"), "failure is reported in the status")
kept.apply(.tokenExpired, now: now.addingTimeInterval(600))
check(kept.limits == parsedAPI && kept.status == .tokenExpired, "token expiry keeps values and reports tokenExpired")

// Denied Keychain access: status is set, no automatic retry, and a manual refresh allows one.
var denied = ClaudeApiState()
denied.apply(.accessDenied, now: now)
check(denied.status == .error(ClaudeKeychain.accessDeniedText), "denied Keychain access reports the Keychain hint")
check(denied.isDue(now: now.addingTimeInterval(86_400 * 365)) == false, "denied access is never retried automatically")
denied.allowFetchNow()
check(denied.isDue(now: now), "manual refresh makes the denied source due again")
let deniedLogin: ClaudeTokenProvider = { .accessDenied }
let deniedTransport = FakeUsageTransport(status: 200, body: sampleAPI)
let deniedFetch = await ClaudeUsageClient(tokenProvider: deniedLogin, transport: deniedTransport).fetch(now: now)
check(deniedFetch == .accessDenied && deniedTransport.requests.isEmpty, "denied Keychain access sends no request")

// Status line file is used only when it is newer than the last API success.
let olderFile = Limits(fiveHourLeft: 10, fiveHourReset: nil, weekLeft: nil, weekReset: nil, updatedAt: now.addingTimeInterval(-60))
let newerFile = Limits(fiveHourLeft: 50, fiveHourReset: nil, weekLeft: nil, weekReset: nil, updatedAt: now.addingTimeInterval(60))
check(kept.resolve(file: newerFile) == newerFile, "newer status line file wins over the API")
check(kept.resolve(file: olderFile) == parsedAPI, "older status line file is ignored when the API has data")
check(ClaudeApiState().resolve(file: olderFile) == olderFile, "status line file is used when the API never succeeded")
check(ClaudeApiState().resolve(file: nil) == nil, "no API and no file means no Claude data")

try? fm.removeItem(at: root)

if failures > 0 {
    print("\(failures) agent data check(s) failed")
    exit(1)
}
print("all agent data checks passed")
