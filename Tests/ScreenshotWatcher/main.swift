import Foundation

// Standalone checks for ScreenshotWatcher.swift: name matching, the stable-size wait (fake clock),
// unique moves, and a short real directory watch. Built and run by scripts/test-screenshots.sh.

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

func pump(until condition: () -> Bool, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

/// Returns the given sizes one per call, then keeps the last one.
func sizes(_ values: [Int64?]) -> () -> Int64? {
    var index = 0
    return {
        defer { index += 1 }
        return values[min(index, values.count - 1)]
    }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("notchclip-screenshot-tests-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)

// MARK: - Name matching

func url(_ name: String) -> URL {
    URL(fileURLWithPath: "/Users/tester/Desktop/\(name)")
}

check(ScreenshotWatcher.isScreenshot(url("Снимок экрана 2026-11-09 в 12.00.00.png")), "Russian screenshot name matches")
check(ScreenshotWatcher.isScreenshot(url("Screenshot 2026-11-09 at 12.00.00.png")), "English screenshot name matches")
check(ScreenshotWatcher.isScreenshot(url("Screen Shot 2019-01-01 at 1.00.00 PM.png")), "older 'Screen Shot' name matches")
check(ScreenshotWatcher.isScreenshot(url("Screenshot 1.heic")), "HEIC screenshot matches")
check(!ScreenshotWatcher.isScreenshot(url("Запись экрана 2026-11-09 в 12.00.00.mov")), "Russian screen recording is ignored")
check(!ScreenshotWatcher.isScreenshot(url("Screen Recording 2026-11-09 at 12.00.00.mov")), "English screen recording is ignored")
check(!ScreenshotWatcher.isScreenshot(url("Screenshot 2026-11-09.mov")), "a movie with a screenshot name is ignored")
check(!ScreenshotWatcher.isScreenshot(url("Screenshot notes.txt")), "a text file with a screenshot name is ignored")
check(!ScreenshotWatcher.isScreenshot(url("Photo.png")), "an unrelated image is ignored")
check(!ScreenshotWatcher.isScreenshot(url(".Screenshot hidden.png")), "a hidden file is ignored")

// MARK: - Folder from the system setting

let suiteName = "notchclip-screencapture-tests-\(UUID().uuidString)"
let systemSuite = UserDefaults(suiteName: suiteName)!
defer { systemSuite.removePersistentDomain(forName: suiteName) }
let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
check(ScreenshotWatcher.systemDirectory(defaults: systemSuite, home: home).path == "/Users/tester/Desktop",
      "no location setting means Desktop")
systemSuite.set("~/Shots", forKey: "location")
check(ScreenshotWatcher.systemDirectory(defaults: systemSuite, home: home).path == NSHomeDirectory() + "/Shots",
      "the location setting expands ~")
check(ScreenshotWatcher.systemDirectory(defaults: nil, home: home).path == "/Users/tester/Desktop",
      "without a defaults domain the folder is Desktop")

// MARK: - Stable size (fake clock)

var clockValue: TimeInterval = 0
func fakeClock() -> TimeInterval { clockValue }
func fakeSleep(_ seconds: TimeInterval) { clockValue += seconds }

clockValue = 0
let settled = ScreenshotWatcher.awaitStableSize(sample: sizes([0, 100, 200, 200, 200]),
                                                clock: fakeClock, sleep: fakeSleep)
check(settled == 200, "returns the size once it stops changing")
check(clockValue <= 1.0, "a file that settles is accepted within about a second (took \(clockValue) s)")

clockValue = 0
let never = ScreenshotWatcher.awaitStableSize(sample: sizes([nil]), clock: fakeClock, sleep: fakeSleep)
check(never == nil, "a file that never appears gives nil")
check(clockValue >= 6 && clockValue <= 6.5, "a missing file is given up after about 6 s (took \(clockValue) s)")

clockValue = 0
var growing: Int64 = 0
let grows = ScreenshotWatcher.awaitStableSize(sample: { growing += 10; return growing }, clock: fakeClock, sleep: fakeSleep)
check(grows != nil && grows! > 0 && clockValue >= 6, "a file that keeps growing is delivered after the timeout")

clockValue = 0
let zero = ScreenshotWatcher.awaitStableSize(sample: sizes([0]), clock: fakeClock, sleep: fakeSleep)
check(zero == nil, "a file that stays empty is not delivered")

// MARK: - Unique move

let source = root.appendingPathComponent("src", isDirectory: true)
let library = root.appendingPathComponent("Pictures/Скриншоты", isDirectory: true)
try fm.createDirectory(at: source, withIntermediateDirectories: true)

let first = source.appendingPathComponent("Screenshot 1.png")
try Data("one".utf8).write(to: first)
let movedFirst = try ScreenshotWatcher.move(first, to: library)
check(movedFirst.lastPathComponent == "Screenshot 1.png" && fm.fileExists(atPath: movedFirst.path)
      && !fm.fileExists(atPath: first.path), "the first move keeps the name")
check(fm.fileExists(atPath: library.path), "the library folder is created")

let again = source.appendingPathComponent("Screenshot 1.png")
try Data("two".utf8).write(to: again)
let movedAgain = try ScreenshotWatcher.move(again, to: library)
check(movedAgain.lastPathComponent == "Screenshot 1 2.png", "a taken name gets a numeric suffix")
check((try? String(contentsOf: movedAgain, encoding: .utf8)) == "two", "the moved content is preserved")
check((try? String(contentsOf: movedFirst, encoding: .utf8)) == "one", "the earlier file is not overwritten")

// MARK: - Real directory watch

let watchDir = root.appendingPathComponent("Desktop", isDirectory: true)
try fm.createDirectory(at: watchDir, withIntermediateDirectories: true)
try Data("old".utf8).write(to: watchDir.appendingPathComponent("Screenshot old.png"))

let watchSuiteName = "notchclip-watch-tests-\(UUID().uuidString)"
let watchDefaults = UserDefaults(suiteName: watchSuiteName)!
defer { watchDefaults.removePersistentDomain(forName: watchSuiteName) }
watchDefaults.set(true, forKey: ScreenshotWatcher.historyKey)
watchDefaults.set(false, forKey: ScreenshotWatcher.moveKey)

var delivered: [String] = []
let watcher = ScreenshotWatcher(
    directory: watchDir,
    libraryDirectory: library,
    defaults: watchDefaults,
    onScreenshot: { delivered.append($0.lastPathComponent) }
)
watcher.start()
try Data("new".utf8).write(to: watchDir.appendingPathComponent("Снимок экрана 2026-11-09 в 12.00.00.png"))
try Data("video".utf8).write(to: watchDir.appendingPathComponent("Запись экрана 2026-11-09 в 12.00.00.mov"))
pump(until: { delivered.count >= 1 }, timeout: 10)
RunLoop.main.run(until: Date().addingTimeInterval(1.5))
check(delivered == ["Снимок экрана 2026-11-09 в 12.00.00.png"],
      "only the new screenshot is delivered, once (got \(delivered))")
check(fm.fileExists(atPath: watchDir.appendingPathComponent("Снимок экрана 2026-11-09 в 12.00.00.png").path),
      "with move off the screenshot stays in place")
watcher.stop()

var movedDelivery: [String] = []
let movingDefaults = UserDefaults(suiteName: watchSuiteName + "-move")!
defer { movingDefaults.removePersistentDomain(forName: watchSuiteName + "-move") }
movingDefaults.set(true, forKey: ScreenshotWatcher.historyKey)
movingDefaults.set(true, forKey: ScreenshotWatcher.moveKey)
let movingWatcher = ScreenshotWatcher(
    directory: watchDir,
    libraryDirectory: library,
    defaults: movingDefaults,
    onScreenshot: { movedDelivery.append($0.lastPathComponent) }
)
movingWatcher.start()
try Data("nine".utf8).write(to: watchDir.appendingPathComponent("Screenshot 9.png"))
pump(until: { movedDelivery.count >= 1 }, timeout: 10)
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
check(movedDelivery == ["Screenshot 9.png"], "the moving watcher delivers the new screenshot")
check(!fm.fileExists(atPath: watchDir.appendingPathComponent("Screenshot 9.png").path)
      && fm.fileExists(atPath: library.appendingPathComponent("Screenshot 9.png").path),
      "with move on the screenshot ends up in the library folder")
movingWatcher.stop()

try? fm.removeItem(at: root)

if failures > 0 {
    print("\(failures) screenshot check(s) failed")
    exit(1)
}
print("All screenshot watcher tests passed")
