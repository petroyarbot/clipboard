import Foundation

// Standalone checks for ThoughtCapture.swift and ThoughtCaptureView.swift, including the agents.jsonl line format.
// Built and run by scripts/test-thoughts.sh. The Claude CLI is never started: a fake runner records every call.

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

final class FakeRunner: ThoughtProcessRunning {
    struct Call {
        let executable: URL
        let arguments: [String]
        let currentDirectory: URL
        let environment: [String: String]
        let timeout: TimeInterval
    }

    var calls: [Call] = []
    var output = ThoughtProcessOutput(exitCode: 0, stdout: Data(), stderr: Data())
    var error: Error?

    func run(executable: URL,
             arguments: [String],
             currentDirectory: URL,
             environment: [String: String],
             timeout: TimeInterval) throws -> ThoughtProcessOutput {
        calls.append(Call(executable: executable, arguments: arguments, currentDirectory: currentDirectory,
                          environment: environment, timeout: timeout))
        if let error { throw error }
        return output
    }
}

func parseError(_ data: Data) -> ThoughtProcessingError? {
    do {
        _ = try ThoughtProcessor.parseResult(stdout: data)
        return nil
    } catch let error as ThoughtProcessingError {
        return error
    } catch {
        return nil
    }
}

func lines(of url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        .split(separator: "\n")
        .map(String.init)
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("notchclip-thought-tests-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let sampleDate = utc.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12, minute: 30))!

// MARK: - Titles and sanitizing

check(ThoughtInbox.sanitize("a/b:c?d*e|f") == "a b c d e f", "sanitize replaces forbidden characters")
check(ThoughtInbox.title(from: "Купить молоко, хлеб и яйца в магазине") == "Купить молоко, хлеб и яйца в",
      "title keeps the first six words")
check(ThoughtInbox.title(from: "  Идея\n\n  для   заметки  ") == "Идея для заметки",
      "title collapses whitespace and newlines")
let hostile = ThoughtInbox.title(from: "#тег [[ссылка]] ^блок path/to\\file")
check(!hostile.contains(where: { "#[]^/\\".contains($0) }), "title has no Obsidian or path characters")
check(ThoughtInbox.title(from: String(repeating: "я", count: 200)).count == 60, "long title is cut to 60 characters")
check(ThoughtInbox.title(from: "   ...   ").isEmpty, "a dots-only title becomes empty")

// MARK: - Saving notes

let vault = root.appendingPathComponent("Второй мозг", isDirectory: true)
let inbox = ThoughtInbox(vault: vault, timeZone: utc.timeZone)
let webContext = ThoughtContext(appName: "Safari", url: "https://www.example.com/a?b=1", pageTitle: "A")
let note = try inbox.save(text: "Купить молоко, хлеб и яйца в магазине", context: webContext, now: sampleDate)
check(note.relativePath == "05 Входящие/2026-11-09 12-30 Купить молоко, хлеб и яйца в.md",
      "file name has date, time and the first six words")
check(note.url.deletingLastPathComponent().lastPathComponent == "05 Входящие", "note goes to 05 Входящие")
let content = try String(contentsOf: note.url, encoding: .utf8)
check(content.hasPrefix("---\ncreated: 2026-11-09T12:30:00"), "frontmatter starts with an ISO8601 created date")
check(content.contains("\nsource: \"Safari\"\n"), "frontmatter has the source app")
check(content.contains("\nurl: \"https://www.example.com/a?b=1\"\n"), "frontmatter has the url")
check(content.contains("\nstatus: new\n---\n\nКупить молоко, хлеб и яйца в магазине\n"),
      "frontmatter ends with status new and the body follows")

let second = try inbox.save(text: "Купить молоко, хлеб и яйца в магазине", context: .empty, now: sampleDate)
check(second.relativePath == "05 Входящие/2026-11-09 12-30 Купить молоко, хлеб и яйца в 2.md",
      "a taken name gets a numeric suffix")
check((try? String(contentsOf: note.url, encoding: .utf8)) == content, "an existing note is never overwritten")

let quoted = try inbox.save(text: "Цитата",
                            context: ThoughtContext(appName: "Say \"hi\"\\", url: nil, pageTitle: nil),
                            now: sampleDate)
let quotedText = try String(contentsOf: quoted.url, encoding: .utf8)
check(quotedText.contains("source: \"Say \\\"hi\\\"\\\\\""), "yaml escapes quotes and backslashes")
check(quotedText.contains("url: \"\""), "a missing url is an empty string")

do {
    _ = try inbox.save(text: "   \n", context: .empty, now: sampleDate)
    check(false, "an empty thought throws emptyText")
} catch ThoughtInboxError.emptyText {
    check(true, "an empty thought throws emptyText")
} catch {
    check(false, "an empty thought throws emptyText")
}

// MARK: - Context

let tab = ThoughtContext.parseTab("https://www.example.com/a\nПример страницы")
check(tab?.url == "https://www.example.com/a" && tab?.title == "Пример страницы", "tab output splits URL and title")
check(ThoughtContext.parseTab("missing") == nil, "tab output without a URL is ignored")
check(ThoughtContext.host(of: "https://www.example.com/a") == "example.com", "host drops www")
check(webContext.chipText == "Safari · example.com", "chip shows app and host")
check(ThoughtContext(appName: "Xcode", url: nil, pageTitle: nil).chipText == "Xcode", "chip without a URL shows the app only")
check(ThoughtContext.tabScript(bundleID: "com.apple.Safari")?.contains("Safari") == true, "Safari has a tab script")
check(ThoughtContext.tabScript(bundleID: "com.apple.Terminal") == nil, "other apps have no tab script")
check(ThoughtContext.tabScript(bundleID: "ru.yandex.desktop.yandex-browser")?.contains("tell application \"Yandex\"") == true,
      "Yandex has a tab script")

// MARK: - Processor: arguments, environment, parsing (fake runner)

let fakeHome = "/Users/tester"
let dataDir = root.appendingPathComponent("data", isDirectory: true)
let answerJSON = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"→ 03 Знания/Тест.md","session_id":"s"}"#.utf8)
let runner = FakeRunner()
runner.output = ThoughtProcessOutput(exitCode: 0, stdout: answerJSON, stderr: Data())
let processor = ThoughtProcessor(
    vault: vault,
    dataDirectory: dataDir,
    runner: runner,
    home: fakeHome,
    baseEnvironment: ["KEEP_ME": "1", "PATH": "/nowhere", "HOME": "/elsewhere"],
    isExecutable: { $0 == "/opt/homebrew/bin/claude" },
    now: { sampleDate }
)
let answer = try processor.process(relativePath: "05 Входящие/x.md")
check(answer == "→ 03 Знания/Тест.md", "the answer line is returned")
check(runner.calls.count == 1, "the runner is called once")
let call = runner.calls.first
check(call?.executable.path == "/opt/homebrew/bin/claude", "homebrew claude is used when ~/.local/bin is missing")
check(call?.currentDirectory == vault, "the working directory is the vault")
check(call?.timeout == 180, "the timeout is 180 s")
let args = call?.arguments ?? []
check(args.count == 10 && args[0] == "-p", "arguments start with -p and the prompt")
check(Array(args.dropFirst(2)) == ["--model", "haiku", "--output-format", "json", "--permission-mode", "acceptEdits",
                                   "--allowedTools", "Read,Write,Edit,Glob,Grep,LS"],
      "flags match the spec")
let prompt = args.count > 1 ? args[1] : ""
check(prompt.contains("05 Входящие/x.md") && prompt.contains("Как пользоваться.md") && prompt.contains("Начало.md")
      && prompt.contains("needs-review"), "the prompt names the note, the vault rules and the review rule")
check(call?.environment["PATH"] == "\(fakeHome)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "PATH has the CLI directories first")
check(call?.environment["HOME"] == fakeHome, "HOME is the user's home")
check(call?.environment["KEEP_ME"] == "1", "other environment variables are kept")

let priority = ThoughtProcessor(vault: vault, dataDirectory: dataDir, runner: runner, home: fakeHome,
                                isExecutable: { _ in true })
check((try? priority.resolveExecutable())?.path == "\(fakeHome)/.local/bin/claude", "~/.local/bin/claude is tried first")

check(parseError(Data("not json".utf8)) == .badOutput, "non-JSON output is badOutput")
check(parseError(Data(#"{"is_error":true,"result":"limit reached"}"#.utf8)) == .cliFailed("limit reached"),
      "is_error true is a CLI failure")
check(parseError(Data(#"{"is_error":false}"#.utf8)) == .badOutput, "result missing is badOutput")
check((try? ThoughtProcessor.parseResult(stdout: Data(#"{"is_error":false,"result":"Готово.\n? Какая папка нужна?"}"#.utf8))) == "? Какая папка нужна?",
      "the question line is picked from a multi-line result")
check((try? ThoughtProcessor.parseResult(stdout: Data(#"[{"type":"system"},{"type":"result","is_error":false,"result":"→ 04 Идеи/y.md"}]"#.utf8))) == "→ 04 Идеи/y.md",
      "the result is taken from a message array")

// MARK: - Processor: failures

runner.error = ThoughtProcessTimeout()
let timeoutProcessor = ThoughtProcessor(vault: vault, dataDirectory: root.appendingPathComponent("timeout"), runner: runner,
                                        home: fakeHome, isExecutable: { _ in true }, now: { sampleDate })
do {
    _ = try timeoutProcessor.process(relativePath: "05 Входящие/t.md")
    check(false, "a timed-out run throws timedOut")
} catch let error as ThoughtProcessingError {
    check(error == .timedOut, "a timed-out run throws timedOut")
} catch {
    check(false, "a timed-out run throws timedOut")
}
runner.error = nil

let missingDir = root.appendingPathComponent("data-missing", isDirectory: true)
let missingRunner = FakeRunner()
let missing = ThoughtProcessor(vault: vault, dataDirectory: missingDir, runner: missingRunner, home: fakeHome,
                               isExecutable: { _ in false }, now: { sampleDate })
do {
    _ = try missing.process(relativePath: "05 Входящие/y.md")
    check(false, "a missing CLI throws")
} catch let error as ThoughtProcessingError {
    check(error == .claudeNotFound && error.localizedDescription == "Не найден Claude Code CLI",
          "a missing CLI gives 'Не найден Claude Code CLI'")
} catch {
    check(false, "a missing CLI gives 'Не найден Claude Code CLI'")
}
check(missingRunner.calls.isEmpty, "no process is started without the CLI")
let missingLines = lines(of: missingDir.appendingPathComponent("agents.jsonl"))
check(missingLines.count == 2, "a failed run still logs SessionStart and Stop")
check(missingLines.last.flatMap(AgentReducer.parseLine)?.message == "? Не найден Claude Code CLI",
      "the Stop line carries the error")

// MARK: - agents.jsonl format, read back by the real reader

let logURL = dataDir.appendingPathComponent("agents.jsonl")
let logLines = lines(of: logURL)
check(logLines.count == 2, "a successful run appends two lines")
let events = logLines.compactMap(AgentReducer.parseLine)
check(events.count == 2, "both lines parse with AgentReducer.parseLine")
check(events.first?.event == "SessionStart" && events.last?.event == "Stop", "SessionStart is followed by Stop")
check(events.allSatisfy { $0.source == "assistant" }, "source is assistant")
check(events.first?.session.hasPrefix("assistant-") == true && events.first?.session == events.last?.session,
      "both lines share one assistant session id")
check(events.first.map { AgentReducer.projectName(cwd: $0.cwd) } == "Второй мозг", "project is the vault folder name")
check(events.last?.message == "→ 03 Знания/Тест.md", "the Stop message is the answer line")
check(logLines.allSatisfy { $0.contains("\"type\":null") }, "type is null, as the hook writes it")
let rawObject = (try? JSONSerialization.jsonObject(with: Data(logLines[1].utf8))) as? [String: Any] ?? [:]
check(Set(rawObject.keys) == ["source", "event", "session", "cwd", "type", "message", "time"],
      "a line has exactly the hook's keys")
check(AgentLogReader.read(url: logURL, from: 0).events.count == 2, "AgentLogReader reads both lines")
let tasks = AgentReducer.reduce(events, now: sampleDate.addingTimeInterval(1))
check(tasks.count == 1 && tasks[0].state == .done && tasks[0].project == "Второй мозг" && tasks[0].source == "assistant",
      "the reducer shows one done task for the assistant")

// MARK: - Coordinator (main actor): vault setting, Enter, Esc, result publishing

@MainActor
func runCoordinatorChecks(root: URL, fileManager: FileManager) {
    let suiteName = "notchclip-thought-tests-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removePersistentDomain(forName: suiteName) }

    let coordinatorVault = root.appendingPathComponent("Ассистент-тест", isDirectory: true)
    let coordinatorData = root.appendingPathComponent("coordinator-data", isDirectory: true)
    let fake = FakeRunner()
    fake.output = ThoughtProcessOutput(exitCode: 0, stdout: answerJSON, stderr: Data())
    let capture = ThoughtCapture(
        dataDirectory: coordinatorData,
        defaults: suite,
        runner: fake,
        isExecutable: { $0 == "/usr/local/bin/claude" }
    )

    check(capture.vaultURL.path.hasSuffix("/Личный ассистент/Второй мозг"), "default vault is ~/Личный ассистент/Второй мозг")
    suite.set(coordinatorVault.path, forKey: ThoughtCapture.vaultDefaultsKey)
    check(capture.vaultURL.path == coordinatorVault.path, "the vault comes from assistantVaultPath")

    var dismissed = 0
    capture.onDismiss = { dismissed += 1 }

    let focusBefore = capture.model.focusRequest
    capture.model.reset(context: ThoughtContext(appName: "Notes", url: nil, pageTitle: nil))
    check(capture.model.focusRequest > focusBefore, "reset asks the card to take focus")
    check(capture.model.context.chipText == "Notes", "the context chip is set on reset")

    capture.model.onSubmit?("   ")
    check(dismissed == 0, "an empty Enter does nothing")

    capture.model.text = "  Мысль из теста  "
    capture.model.onSubmit?(capture.model.text)
    check(dismissed == 1, "Enter saves and asks the host to hide the card")
    check(capture.model.text.isEmpty, "the text is cleared after saving")

    let inboxFiles = (try? fileManager.contentsOfDirectory(
        atPath: coordinatorVault.appendingPathComponent("05 Входящие").path)) ?? []
    check(inboxFiles.count == 1 && inboxFiles[0].hasSuffix("Мысль из теста.md"), "the note is written to 05 Входящие")

    let deadline = Date().addingTimeInterval(10)
    while capture.lastResult == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    check(capture.lastResult == "→ 03 Знания/Тест.md", "lastResult is published after the run")
    check(fake.calls.count == 1, "one note means one Claude run")
    check(fake.calls.first?.currentDirectory == coordinatorVault, "the run happens in the configured vault")

    capture.model.text = "Отмена"
    capture.model.onCancel?()
    check(dismissed == 2, "Esc asks the host to hide the card")
    check(capture.model.text.isEmpty, "Esc clears the text")
    let afterCancel = (try? fileManager.contentsOfDirectory(
        atPath: coordinatorVault.appendingPathComponent("05 Входящие").path)) ?? []
    check(afterCancel.count == 1, "Esc does not save a note")

    _ = ThoughtCaptureView(model: capture.model)
    check(true, "ThoughtCaptureView builds from the model")
}

MainActor.assumeIsolated {
    runCoordinatorChecks(root: root, fileManager: fm)
}

try? fm.removeItem(at: root)

if failures > 0 {
    print("\(failures) thought check(s) failed")
    exit(1)
}
print("All thought capture tests passed")
