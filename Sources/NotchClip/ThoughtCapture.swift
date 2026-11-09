import AppKit
import Foundation

// Quick thought -> personal assistant.
//
// Flow: the host calls `ThoughtCapture.begin()` BEFORE showing the card (this records the frontmost app),
// the user types or dictates, Enter calls `submit`, which writes a note into `<vault>/05 Входящие`
// and then runs Claude Code headless in the vault. Each run appends SessionStart/Stop lines to
// agents.jsonl, so the Agents tab shows it.

// MARK: - Context

/// Where a thought was written: the frontmost app and, for supported browsers, the current tab.
struct ThoughtContext: Equatable {
    var appName: String?
    var url: String?
    var pageTitle: String?

    static let empty = ThoughtContext()

    /// Short label for the card chip: "Safari · example.com", "Xcode", or "" when nothing is known.
    var chipText: String {
        var parts: [String] = []
        if let appName, !appName.isEmpty { parts.append(appName) }
        if let host = Self.host(of: url) { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    static func host(of urlString: String?) -> String? {
        guard let urlString, let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// AppleScript that returns "URL" and "title" on two lines for the front tab. Nil for apps that are not supported browsers.
    static func tabScript(bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return """
            tell application "Safari"
                if (count of windows) = 0 then return ""
                return (URL of current tab of front window) & linefeed & (name of current tab of front window)
            end tell
            """
        case "com.google.Chrome":
            return chromiumScript(application: "Google Chrome")
        case "company.thebrowser.Browser":
            return chromiumScript(application: "Arc")
        case "ru.yandex.desktop.yandex-browser":
            return chromiumScript(application: "Yandex")
        default:
            return nil
        }
    }

    private static func chromiumScript(application: String) -> String {
        """
        tell application "\(application)"
            if (count of windows) = 0 then return ""
            return (URL of active tab of front window) & linefeed & (title of active tab of front window)
        end tell
        """
    }

    /// Splits the "URL\nTitle" output. Nil unless the first line is an http(s) URL.
    static func parseTab(_ raw: String) -> (url: String, title: String)? {
        let lines = raw.components(separatedBy: "\n")
        let url = (lines.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return nil }
        let title = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (url, title)
    }

    /// Reads the frontmost app. Call on the main thread, before the card is shown.
    /// Fails silently: unsupported apps, a missing Automation permission or no open window give a context without a URL.
    @MainActor
    static func captureApp(ownBundleID: String? = Bundle.main.bundleIdentifier) -> (context: ThoughtContext, bundleID: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != ownBundleID else {
            return (.empty, nil)
        }
        return (ThoughtContext(appName: app.localizedName), app.bundleIdentifier)
    }

    /// Front tab of a supported browser. AppleScript can take seconds, so call this off the main thread.
    nonisolated static func fetchTab(bundleID: String) -> (url: String, title: String)? {
        guard let source = tabScript(bundleID: bundleID), let raw = runAppleScript(source) else { return nil }
        return parseTab(raw)
    }

    @MainActor
    static func capture(ownBundleID: String? = Bundle.main.bundleIdentifier) -> ThoughtContext {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != ownBundleID else {
            return .empty
        }
        var context = ThoughtContext(appName: app.localizedName)
        if let bundleID = app.bundleIdentifier,
           let source = tabScript(bundleID: bundleID),
           let raw = runAppleScript(source),
           let tab = parseTab(raw) {
            context.url = tab.url
            context.pageTitle = tab.title
        }
        return context
    }

    private nonisolated static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}

// MARK: - Inbox

struct ThoughtNote: Equatable {
    let url: URL
    /// Path relative to the vault, e.g. "05 Входящие/2026-11-09 12-30 Купить молоко.md".
    let relativePath: String
}

enum ThoughtInboxError: Error, LocalizedError, Equatable {
    case emptyText
    case noUniqueName

    var errorDescription: String? {
        switch self {
        case .emptyText: return "Мысль пустая"
        case .noUniqueName: return "Не удалось подобрать имя файла"
        }
    }
}

/// Writes thoughts as Markdown notes into `<vault>/05 Входящие`. Existing files are never overwritten.
struct ThoughtInbox {
    static let folderName = "05 Входящие"
    static let wordLimit = 6
    static let titleLimit = 60

    let vault: URL
    var timeZone: TimeZone = .current

    @discardableResult
    func save(text: String, context: ThoughtContext, now: Date) throws -> ThoughtNote {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ThoughtInboxError.emptyText }

        let folder = vault.appendingPathComponent(Self.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = Self.baseName(text: body, now: now, timeZone: timeZone)
        let data = Data(Self.document(body: body, context: context, now: now, timeZone: timeZone).utf8)
        for suffix in 1...999 {
            let name = suffix == 1 ? "\(base).md" : "\(base) \(suffix).md"
            let url = folder.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return ThoughtNote(url: url, relativePath: "\(Self.folderName)/\(name)")
            } catch {
                // The name is taken: try the next suffix. Any other failure is real.
                if FileManager.default.fileExists(atPath: url.path) { continue }
                throw error
            }
        }
        throw ThoughtInboxError.noUniqueName
    }

    /// "YYYY-MM-DD HH-mm <first words>", without the extension.
    static func baseName(text: String, now: Date, timeZone: TimeZone) -> String {
        let stamp = formatter("yyyy-MM-dd HH-mm", timeZone: timeZone).string(from: now)
        let title = title(from: text)
        return title.isEmpty ? stamp : "\(stamp) \(title)"
    }

    /// The first words of the thought, sanitized for a file name and an Obsidian link.
    static func title(from text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(wordLimit).joined(separator: " ")
        var title = sanitize(words)
        if title.count > titleLimit {
            title = sanitize(String(title.prefix(titleLimit)))
        }
        return title
    }

    /// Replaces characters that break file names or Obsidian links with spaces, collapses spaces and trims dots.
    static func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.controlCharacters)
        var replaced = ""
        for scalar in value.unicodeScalars {
            replaced.unicodeScalars.append(forbidden.contains(scalar) ? " " : scalar)
        }
        return replaced
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    static func document(body: String, context: ThoughtContext, now: Date, timeZone: TimeZone) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = timeZone
        return [
            "---",
            "created: \(iso.string(from: now))",
            "source: \(yamlString(context.appName ?? ""))",
            "url: \(yamlString(context.url ?? ""))",
            "status: new",
            "---",
            "",
            body,
            ""
        ].joined(separator: "\n")
    }

    static func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - Claude CLI runner

struct ThoughtProcessOutput: Equatable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
}

/// Runs a process. The app uses `FoundationThoughtProcessRunner`; tests inject a fake so Claude is never started.
protocol ThoughtProcessRunning {
    func run(executable: URL,
             arguments: [String],
             currentDirectory: URL,
             environment: [String: String],
             timeout: TimeInterval) throws -> ThoughtProcessOutput
}

/// Thrown by a runner when the process does not finish in time.
struct ThoughtProcessTimeout: Error {}

private final class ThoughtDataBox: @unchecked Sendable {
    var data = Data()
}

/// Remembers running `claude` children so quitting the app does not leave them working in the vault.
enum ThoughtProcessTracker {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var running: [ObjectIdentifier: Process] = [:]
    private nonisolated(unsafe) static var closed = false

    /// False once the app is quitting: the caller must not start a process.
    static func register(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        running[ObjectIdentifier(process)] = process
        return true
    }

    static func unregister(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        running[ObjectIdentifier(process)] = nil
    }

    /// Called at quit: stops every child and refuses new ones.
    static func terminateAll() {
        lock.lock()
        closed = true
        let processes = Array(running.values)
        lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
    }
}

struct FoundationThoughtProcessRunner: ThoughtProcessRunning {
    func run(executable: URL,
             arguments: [String],
             currentDirectory: URL,
             environment: [String: String],
             timeout: TimeInterval) throws -> ThoughtProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard ThoughtProcessTracker.register(process) else {
            process.terminate()
            throw ThoughtProcessTimeout()
        }
        defer { ThoughtProcessTracker.unregister(process) }
        // The child holds its own copies of the write ends. Closing ours lets the readers see EOF.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let outBox = ThoughtDataBox()
        let errBox = ThoughtDataBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
            throw ThoughtProcessTimeout()
        }
        readers.wait()
        return ThoughtProcessOutput(exitCode: process.terminationStatus, stdout: outBox.data, stderr: errBox.data)
    }
}

// MARK: - Processor

enum ThoughtProcessingError: Error, LocalizedError, Equatable {
    case claudeNotFound
    case timedOut
    case cliFailed(String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Не найден Claude Code CLI"
        case .timedOut:
            return "Claude Code не ответил за \(Int(ThoughtProcessor.timeout)) с"
        case .cliFailed(let detail):
            return "Claude Code завершился с ошибкой: \(detail)"
        case .badOutput:
            return "Claude Code вернул неожиданный ответ"
        }
    }
}

/// Hands one inbox note to Claude Code (headless, in the vault) and logs the run to agents.jsonl.
final class ThoughtProcessor {
    static let timeout: TimeInterval = 180
    static let model = "haiku"
    static let allowedTools = "Read,Write,Edit,Glob,Grep,LS"
    static let logSource = "assistant"
    static let logProject = "Второй мозг"

    /// One serial queue for every run, so notes are processed one at a time.
    private static let queue = DispatchQueue(label: "NotchClip.thoughts.processor", qos: .utility)

    let vault: URL
    let dataDirectory: URL
    private let runner: ThoughtProcessRunning
    private let home: String
    private let baseEnvironment: [String: String]
    private let isExecutable: (String) -> Bool
    private let now: () -> Date
    private let timeout: TimeInterval

    init(vault: URL,
         dataDirectory: URL,
         runner: ThoughtProcessRunning = FoundationThoughtProcessRunner(),
         home: String = NSHomeDirectory(),
         baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
         now: @escaping () -> Date = { Date() },
         timeout: TimeInterval = ThoughtProcessor.timeout) {
        self.vault = vault
        self.dataDirectory = dataDirectory
        self.runner = runner
        self.home = home
        self.baseEnvironment = baseEnvironment
        self.isExecutable = isExecutable
        self.now = now
        self.timeout = timeout
    }

    static func candidatePaths(home: String) -> [String] {
        ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    static func environment(base: [String: String], home: String) -> [String: String] {
        var environment = base
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .joined(separator: ":")
        environment["HOME"] = home
        return environment
    }

    static func arguments(prompt: String) -> [String] {
        [
            "-p", prompt,
            "--model", model,
            "--output-format", "json",
            "--permission-mode", "acceptEdits",
            "--allowedTools", allowedTools
        ]
    }

    static func prompt(for relativePath: String) -> String {
        """
        Ты разбираешь одну входящую мысль в Obsidian-хранилище, которое является текущей папкой.
        1. Прочитай «Как пользоваться.md» и «Начало.md» — там правила хранилища.
        2. Обрабатывай ТОЛЬКО файл «\(relativePath)». Другие файлы не трогай.
        3. Выбери папку среди «01 Сферы», «02 Проекты», «03 Знания», «04 Идеи», предпочитая существующие подпапки. Перемести заметку туда, сохрани frontmatter и поставь status: processed.
        4. Добавь одну строку-резюме и ссылки [[...]] на связанные существующие заметки. В других заметках можно только добавить строку-обратную ссылку; ничего не удаляй и не переписывай.
        5. Не используй сеть, Notion и другие сервисы.
        6. Если не уверен — оставь файл в «05 Входящие», поставь status: needs-review и задай короткий вопрос.
        Финальный ответ — ровно одна строка: «→ <относительный путь к файлу>» или «? <вопрос>».
        """
    }

    /// The answer line: the first "→" or "?" line, otherwise the first non-empty line.
    static func answerLine(from result: String) -> String {
        let lines = result
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first(where: { $0.hasPrefix("→") || $0.hasPrefix("?") }) ?? lines.first ?? ""
    }

    /// Reads `result` from `--output-format json` output (an object, or an array of messages).
    static func parseResult(stdout: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: stdout) else {
            throw ThoughtProcessingError.badOutput
        }
        let object: [String: Any]?
        if let dictionary = root as? [String: Any] {
            object = dictionary
        } else if let messages = root as? [[String: Any]] {
            object = messages.last(where: { ($0["type"] as? String) == "result" })
        } else {
            object = nil
        }
        guard let object else { throw ThoughtProcessingError.badOutput }
        if (object["is_error"] as? Bool) == true {
            throw ThoughtProcessingError.cliFailed(object["result"] as? String ?? "is_error")
        }
        guard let result = object["result"] as? String else { throw ThoughtProcessingError.badOutput }
        let answer = answerLine(from: result)
        guard !answer.isEmpty else { throw ThoughtProcessingError.badOutput }
        return answer
    }

    /// The first executable candidate. Throws `claudeNotFound` when none exists.
    func resolveExecutable() throws -> URL {
        for path in Self.candidatePaths(home: home) where isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        throw ThoughtProcessingError.claudeNotFound
    }

    /// Runs one note now (blocking). Appends SessionStart and Stop lines to agents.jsonl and returns the answer line.
    /// Failures are logged as "? <error>" on the Stop line and rethrown.
    @discardableResult
    func process(relativePath: String) throws -> String {
        let session = "assistant-\(UUID().uuidString.lowercased())"
        let log = AssistantAgentLog(fileURL: dataDirectory.appendingPathComponent("agents.jsonl"))
        try? log.append(event: "SessionStart", session: session, cwd: vault.path, message: "", time: now())
        do {
            let answer = try run(relativePath: relativePath)
            try? log.append(event: "Stop", session: session, cwd: vault.path, message: answer, time: now())
            return answer
        } catch {
            let description = error.localizedDescription
            try? log.append(event: "Stop", session: session, cwd: vault.path, message: "? " + description, time: now())
            throw error
        }
    }

    /// Queues `process` on the shared serial queue. `completion` runs on the main actor.
    func enqueue(relativePath: String, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        Self.queue.async {
            let result: Result<String, Error> = Result { try self.process(relativePath: relativePath) }
            Task { @MainActor in completion(result) }
        }
    }

    private func run(relativePath: String) throws -> String {
        let executable = try resolveExecutable()
        let output: ThoughtProcessOutput
        do {
            output = try runner.run(
                executable: executable,
                arguments: Self.arguments(prompt: Self.prompt(for: relativePath)),
                currentDirectory: vault,
                environment: Self.environment(base: baseEnvironment, home: home),
                timeout: timeout
            )
        } catch is ThoughtProcessTimeout {
            throw ThoughtProcessingError.timedOut
        }
        guard output.exitCode == 0 else {
            let stderr = String(decoding: output.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = String(stderr.prefix(200))
            throw ThoughtProcessingError.cliFailed(detail.isEmpty ? "код \(output.exitCode)" : detail)
        }
        return try Self.parseResult(stdout: output.stdout)
    }
}

/// Appends lines in the schema of scripts/agent-hooks/notchclip-hook.sh, so AgentMonitor reads them unchanged.
struct AssistantAgentLog {
    static let maxMessageLength = 200

    let fileURL: URL

    static func line(event: String, session: String, cwd: String, message: String, time: Date) -> String {
        let object: [String: Any] = [
            "source": ThoughtProcessor.logSource,
            "event": event,
            "session": session,
            "cwd": cwd,
            "type": NSNull(),
            "message": String(message.prefix(maxMessageLength)),
            "time": Int(time.timeIntervalSince1970)
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func append(event: String, session: String, cwd: String, message: String, time: Date) throws {
        let text = Self.line(event: event, session: session, cwd: cwd, message: message, time: time) + "\n"
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

// MARK: - Card state and coordinator

/// What ThoughtCaptureView shows. `requestFocus()` makes the text field first responder again.
@MainActor
final class ThoughtCaptureModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var context = ThoughtContext.empty
    @Published var errorMessage: String?
    @Published private(set) var focusRequest = 0

    var onSubmit: (@MainActor (String) -> Void)?
    var onCancel: (@MainActor () -> Void)?

    func update(context: ThoughtContext) {
        self.context = context
    }

    func reset(context: ThoughtContext) {
        text = ""
        errorMessage = nil
        self.context = context
        requestFocus()
    }

    func requestFocus() {
        focusRequest += 1
    }
}

/// Owns one capture session: records the context, saves the note, runs Claude and publishes the last answer.
@MainActor
final class ThoughtCapture: ObservableObject {
    static let vaultDefaultsKey = "assistantVaultPath"
    static let defaultVaultPath = "~/Личный ассистент/Второй мозг"

    /// Last answer from Claude ("→ path" or "? question"), or the error text.
    @Published private(set) var lastResult: String?
    let model = ThoughtCaptureModel()
    /// Set by the host. Called after a save or a cancel, so the host can hide the card.
    var onDismiss: (() -> Void)?
    var onSaved: (() -> Void)?

    private let dataDirectory: URL
    private let defaults: UserDefaults
    private let runner: ThoughtProcessRunning
    private let isExecutable: (String) -> Bool
    private var context = ThoughtContext.empty
    private var captureGeneration = 0
    private nonisolated static let tabQueue = DispatchQueue(label: "NotchClip.thoughts.tab", qos: .userInitiated)

    init(dataDirectory: URL,
         defaults: UserDefaults = .standard,
         runner: ThoughtProcessRunning = FoundationThoughtProcessRunner(),
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.dataDirectory = dataDirectory
        self.defaults = defaults
        self.runner = runner
        self.isExecutable = isExecutable
        model.onSubmit = { [weak self] text in self?.submit(text) }
        model.onCancel = { [weak self] in self?.dismiss() }
    }

    /// The vault from `assistantVaultPath`, or ~/Личный ассистент/Второй мозг.
    var vaultURL: URL {
        let configured = defaults.string(forKey: Self.vaultDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = configured.isEmpty ? Self.defaultVaultPath : configured
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Call before the card is shown. Records the frontmost app while it is still the user's app, and focuses the field.
    func begin() {
        let captured = ThoughtContext.captureApp()
        context = captured.context
        model.reset(context: context)
        // The browser tab arrives later: AppleScript must not block the hotkey on the main thread.
        captureGeneration += 1
        let generation = captureGeneration
        guard let bundleID = captured.bundleID, ThoughtContext.tabScript(bundleID: bundleID) != nil else { return }
        Self.tabQueue.async { [weak self] in
            let tab = ThoughtContext.fetchTab(bundleID: bundleID)
            Task { @MainActor in
                guard let self, let tab, generation == self.captureGeneration else { return }
                self.context.url = tab.url
                self.context.pageTitle = tab.title
                self.model.update(context: self.context)
            }
        }
    }

    private func submit(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        do {
            let note = try ThoughtInbox(vault: vaultURL).save(text: body, context: context, now: Date())
            model.text = ""
            model.errorMessage = nil
            onSaved?()
            enqueue(relativePath: note.relativePath)
            onDismiss?()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func dismiss() {
        model.text = ""
        model.errorMessage = nil
        onDismiss?()
    }

    private func enqueue(relativePath: String) {
        let processor = ThoughtProcessor(
            vault: vaultURL,
            dataDirectory: dataDirectory,
            runner: runner,
            isExecutable: isExecutable
        )
        processor.enqueue(relativePath: relativePath) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let line):
                self.lastResult = line
            case .failure(let error):
                self.lastResult = "? " + error.localizedDescription
            }
        }
    }
}
