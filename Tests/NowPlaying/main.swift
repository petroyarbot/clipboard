import AppKit
import Foundation

// Проверки чистого слоя Now Playing: разбор JSON, редьюсер, время, цвет обложки, эквалайзер, настройка.
// Последняя проверка живая: собирает помощника и читает первую строку из /usr/bin/perl (без команд воспроизведения).

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("ok   - \(name)")
    } else {
        print("FAIL - \(name)")
        failures += 1
    }
}

func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

// MARK: 1. Разбор строки помощника

let playingLine = #"{"state":"playing","bundle":"ru.yandex.desktop.music","title":"Песня","artist":"Группа","album":"Альбом","duration":200,"elapsed":30.5,"rate":1,"timestamp":1000,"artworkId":"abc","artworkData":"aGVsbG8="}"#
let parsed = NowPlayingSnapshot.parse(playingLine)
check(parsed?.playback == .playing, "parse: playing state")
check(parsed?.bundleID == "ru.yandex.desktop.music", "parse: bundle id")
check(parsed?.title == "Песня" && parsed?.artist == "Группа", "parse: title and artist")
check(parsed?.duration == 200 && parsed?.elapsed == 30.5, "parse: duration and elapsed")
check(parsed?.artworkData == Data("hello".utf8), "parse: artwork decodes base64")
check(NowPlayingSnapshot.parse(#"{"state":"none"}"#)?.playback == NowPlayingSnapshot.Playback.none, "parse: none state without other fields")
check(NowPlayingSnapshot.parse(#"{"state":"weird"}"#) == nil, "parse: unknown state rejected")
check(NowPlayingSnapshot.parse("not json") == nil, "parse: garbage rejected")
check(NowPlayingSnapshot.parse(#"{"state":"paused","title":"x"}"#)?.artworkData == nil, "parse: missing artwork is nil")

// MARK: 2. Редьюсер и устаревание

var reducer = NowPlayingReducer()
check(reducer.status(at: 100) == .stopped, "reducer: no snapshot is stopped")
reducer.receive(parsed!, at: 100)
check(reducer.status(at: 105) == .playing, "reducer: fresh playing snapshot is playing")
check(reducer.status(at: 100 + NowPlayingReducer.staleAfter - 0.1) == .playing, "reducer: still playing just before staleness")
check(reducer.status(at: 100 + NowPlayingReducer.staleAfter) == .stopped, "reducer: silent helper becomes stopped")
var paused = parsed!
paused.playback = .paused
reducer.receive(paused, at: 200)
check(reducer.status(at: 201) == .paused, "reducer: paused snapshot is paused")
let noneSnapshot = NowPlayingSnapshot.parse(#"{"state":"none"}"#)!
reducer.receive(noneSnapshot, at: 210)
check(reducer.status(at: 211) == .stopped, "reducer: none snapshot is stopped")
reducer.reset()
check(reducer.snapshot == nil && reducer.status(at: 211) == .stopped, "reducer: reset clears snapshot")

// MARK: 3. Время и прогресс

check(NowPlayingClock.elapsed(parsed!, at: 1000) == 30.5, "clock: at timestamp elapsed equals base")
check(near(NowPlayingClock.elapsed(parsed!, at: 1010), 40.5), "clock: playing advances by wall time")
check(near(NowPlayingClock.elapsed(parsed!, at: 1000 + 1000), 200), "clock: elapsed clamps to duration")
var pausedClock = parsed!
pausedClock.playback = .paused
check(near(NowPlayingClock.elapsed(pausedClock, at: 1500), 30.5), "clock: paused does not advance")
check(NowPlayingClock.format(0) == "0:00", "format: zero")
check(NowPlayingClock.format(185) == "3:05", "format: minutes and seconds")
check(NowPlayingClock.format(3725) == "1:02:05", "format: hours")
check(NowPlayingClock.format(-4) == "0:00", "format: negative is zero")
check(NowPlayingClock.remaining(elapsed: 30, duration: 200) == "-2:50", "format: remaining")
check(NowPlayingClock.remaining(elapsed: 300, duration: 200) == "-0:00", "format: remaining never negative")
check(NowPlayingClock.progress(elapsed: 50, duration: 200) == 0.25, "progress: quarter")
check(NowPlayingClock.progress(elapsed: 500, duration: 200) == 1, "progress: clamped to one")
check(NowPlayingClock.progress(elapsed: 5, duration: 0) == 0, "progress: unknown duration is zero")

// MARK: 4. Источник

check(NowPlayingSource.displayName(bundleID: "ru.yandex.desktop.music") == "Яндекс Музыка", "source: Yandex Music name")
check(NowPlayingSource.displayName(bundleID: "org.example.Player") == "Player", "source: unknown bundle uses last component")
check(NowPlayingSource.displayName(bundleID: "") == "Плеер", "source: empty bundle has fallback name")

// MARK: 5. Цвет обложки

check(DominantColor.pick([]) == nil, "color: empty input is nil")
let orange = RGB8(r: 230, g: 120, b: 30)
let gray = RGB8(r: 128, g: 128, b: 128)
let pixels = Array(repeating: gray, count: 300) + Array(repeating: orange, count: 80)
check(DominantColor.pick(pixels) == orange, "color: saturated color wins over larger gray area")
check(DominantColor.pick(Array(repeating: gray, count: 10)) == gray, "color: gray-only image falls back to gray")
let black = RGB8(r: 5, g: 5, b: 5)
check(DominantColor.pick(Array(repeating: black, count: 50) + [RGB8(r: 20, g: 90, b: 220)]) == RGB8(r: 20, g: 90, b: 220), "color: near-black pixels are ignored when colorful exist")
let forward = DominantColor.pick([RGB8(r: 200, g: 20, b: 20), RGB8(r: 20, g: 20, b: 200)])
let reversed = DominantColor.pick([RGB8(r: 20, g: 20, b: 200), RGB8(r: 200, g: 20, b: 20)])
check(forward == reversed, "color: result does not depend on pixel order")
let dark = DominantColor.visible(RGB8(r: 40, g: 20, b: 10))
check(max(dark.r, dark.g, dark.b) == 180, "tint: dark color is lifted to 180 brightness")
check(dark.r > dark.g && dark.g > dark.b, "tint: lifting keeps hue ordering")
check(DominantColor.visible(orange) == orange, "tint: bright color is unchanged")

let sample = NSImage(size: NSSize(width: 8, height: 8))
sample.lockFocus()
NSColor(red: 0, green: 0.5, blue: 1, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 8, height: 8).fill()
sample.unlockFocus()
let sampled = ArtworkSampler.pixels(of: sample, side: 4)
check(sampled.count == 16, "sampler: returns side*side pixels")
check(sampled.allSatisfy { $0.b > 200 && $0.r < 30 }, "sampler: blue fill is sampled as blue")

// MARK: 6. Эквалайзер

check(NowPlayingEqualizer.heights(at: 1.3, playing: false) == NowPlayingEqualizer.resting, "equalizer: paused is static")
let moving = (0..<50).map { NowPlayingEqualizer.heights(at: Double($0) * 0.07, playing: true) }
check(moving.allSatisfy { $0.count == 3 && $0.allSatisfy { $0 >= 0.3 && $0 <= 1.0001 } }, "equalizer: playing heights stay in 0.3...1")
check(Set(moving.map { $0[0] }).count > 10, "equalizer: playing heights change over time")

// MARK: 7. Настройка

let suite = "notchclip-now-playing-test-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(NowPlayingSettings.isEnabled(defaults: defaults), "settings: liveActivityMusic defaults to on")
defaults.set(false, forKey: NowPlayingSettings.key)
check(!NowPlayingSettings.isEnabled(defaults: defaults), "settings: liveActivityMusic off when stored false")

// MARK: 8. Живой помощник (без команд воспроизведения)

let work = FileManager.default.temporaryDirectory.appendingPathComponent("notchclip-np-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: work) }
do {
    let library = try NowPlayingHelper.library(in: work)
    check(FileManager.default.fileExists(atPath: library.path), "helper: dylib compiles from embedded source")
    let process = NowPlayingHelper.process(library: library)
    let output = Pipe()
    let stdin = Pipe()   // the helper exits when stdin closes, as the app's pipe does on quit
    process.standardInput = stdin
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    // Строка с обложкой бывает длинной: читаем, пока не появится перевод строки или конец потока.
    var collected = Data()
    while !collected.contains(0x0A) {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        collected.append(chunk)
    }
    let line = String(decoding: collected.prefix { $0 != 0x0A }, as: UTF8.self)
    process.terminate()
    process.waitUntilExit()
    let snapshot = NowPlayingSnapshot.parse(line)
    check(snapshot != nil, "helper: perl process prints a parseable snapshot line")
    print("info - live state: \(snapshot?.playback.rawValue ?? "unparsed"), source: \(snapshot?.bundleID ?? "-")")
} catch {
    check(false, "helper: build or run failed: \(error)")
}

// MARK: 9. Монитор: процесс, разбор stdout и остановка

let monitor = NowPlayingMonitor(directory: FileManager.default.temporaryDirectory.appendingPathComponent("notchclip-np-monitor-\(UUID().uuidString)"))
check(monitor.status == .stopped && monitor.snapshot == nil, "monitor: starts stopped with no snapshot")
monitor.setActive(true)
var gotSnapshot = false
for _ in 0..<40 {
    try? await Task.sleep(nanoseconds: 250_000_000)
    if monitor.snapshot != nil { gotSnapshot = true; break }
}
check(gotSnapshot, "monitor: receives a helper snapshot within 10 s")
monitor.setActive(false)
check(monitor.status == .stopped && monitor.snapshot == nil, "monitor: deactivation stops and clears state")
monitor.send(.next)
check(true, "monitor: send while inactive is a no-op")

print(failures == 0 ? "All NowPlaying checks passed." : "\(failures) NowPlaying check(s) failed.")
exit(failures == 0 ? 0 : 1)
