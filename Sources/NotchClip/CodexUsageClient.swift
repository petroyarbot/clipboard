import Foundation
import Darwin

/// Synchronous runner, called only from the monitor's background task.
protocol CodexProcessRunning {
    func run(executable: URL, timeout: TimeInterval) -> Data?
}

struct CodexProcessRunner: CodexProcessRunning {
    func run(executable: URL, timeout: TimeInterval) -> Data? {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        func send(_ object: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            data.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: data); return true } catch { return false }
        }
        func receive(id: Int) -> Data? {
            var line = Data()
            while Date() < deadline {
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let remaining = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
                guard poll(&descriptor, 1, remaining) > 0 else { return nil }
                var byte: UInt8 = 0
                guard read(descriptor.fd, &byte, 1) == 1 else { return nil }
                if byte == 10 {
                    if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                       (object["id"] as? Int) == id { return line }
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                    if line.count > 1_000_000 { return nil }
                }
            }
            return nil
        }
        guard send(CodexUsageClient.initializeRequest), let initResponse = receive(id: 1),
              CodexUsageClient.initialized(initResponse),
              send(["method": "initialized"]),
              send(["id": 2, "method": "account/rateLimits/read", "params": [:]]) else { return nil }
        return receive(id: 2)
    }
}

enum CodexFetchResult {
    case success(Limits)
    case unavailable(String)
}

struct CodexUsageClient {
    static let initializeRequest: [String: Any] = ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "NotchClip", "version": "1.0"]]]
    var runner: CodexProcessRunning = CodexProcessRunner()
    var locate: () -> URL? = { CodexUsageClient.findExecutable() }

    static func findExecutable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fm = FileManager.default
        // The VS Code / ChatGPT sdk-cache keeps one folder per version: try the newest version first.
        let cache = home.appendingPathComponent("Library/Application Support/Code/agent-host/sdk-cache/codex", isDirectory: true)
        let versions = ((try? fm.contentsOfDirectory(atPath: cache.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let cached = versions.map {
            cache.appendingPathComponent("\($0)/darwin-arm64/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex").path
        }
        let fixed = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        return (cached + fixed).first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    static func initialized(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return object["result"] != nil && object["error"] == nil
    }

    static func parse(_ data: Data, now: Date) -> Limits? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["id"] as? Int) == 2, object["error"] == nil,
              let result = object["result"] as? [String: Any] else { return nil }
        // Prefer the "codex" bucket; rateLimits mirrors the same single-bucket view for older servers.
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let fallbackRate = result["rateLimits"] as? [String: Any]
        guard let rate = (buckets?["codex"] as? [String: Any]) ?? fallbackRate else { return nil }
        func window(_ value: Any?) -> UsageParser.Window? {
            guard let value = value as? [String: Any], let used = UsageParser.number(value["usedPercent"]),
                  let minutes = UsageParser.number(value["windowDurationMins"]), minutes > 0 else { return nil }
            return UsageParser.window(["used": used, "resets_at": value["resetsAt"] ?? NSNull()], now: now, usedKey: "used")
        }
        let five = window(rate["primary"]), week = window(rate["secondary"])
        guard five != nil || week != nil else { return nil }
        return Limits(fiveHourLeft: five?.left, fiveHourReset: five?.reset, weekLeft: week?.left, weekReset: week?.reset, updatedAt: now)
    }

    func fetch(now: Date) -> CodexFetchResult {
        guard let executable = locate() else { return .unavailable("Codex CLI не найден — данные из журнала") }
        guard let data = runner.run(executable: executable, timeout: 15), let limits = Self.parse(data, now: now) else {
            return .unavailable("Codex недоступен — данные из журнала")
        }
        return .success(limits)
    }
}

struct CodexApiState {
    private(set) var limits: Limits?
    private(set) var status: String?
    private(set) var nextFetch: Date = .distantPast
    mutating func apply(_ result: CodexFetchResult, now: Date) {
        switch result {
        case .success(let value): limits = value; status = nil
        case .unavailable(let message): limits = nil; status = message
        }
        nextFetch = now.addingTimeInterval(300)
    }
    func resolve(file: Limits?) -> Limits? {
        guard let file else { return limits }
        guard let limits else { return file }
        return file.updatedAt > limits.updatedAt ? file : limits
    }
}
