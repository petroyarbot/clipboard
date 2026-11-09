import AppKit
import Foundation
import UniformTypeIdentifiers

// Standalone checks for ImageTextRecognizer.swift and OCRCache. Built and run by scripts/test-ocr.sh.
// The real Vision test draws its own image, so no user data is read.

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

/// Draws `text` on a white 1400 x 300 PNG.
func makeTextImage(_ text: String) -> Data {
    let width = 1400
    let height = 300
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (text as NSString).draw(
        at: NSPoint(x: 60, y: 110),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 96, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
    )
    NSGraphicsContext.restoreGraphicsState()

    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Counts calls and the highest number of recognitions running at once. Thread-safe.
final class FakeRecognizer {
    private let queue = DispatchQueue(label: "fake-recognizer")
    private var calls = 0
    private var active = 0
    private var maxActive = 0

    var callCount: Int { queue.sync { calls } }
    var peakConcurrency: Int { queue.sync { maxActive } }

    func recognize(_ data: Data) async throws -> String {
        queue.sync {
            calls += 1
            active += 1
            maxActive = max(maxActive, active)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        queue.sync { active -= 1 }
        return "text of \(String(decoding: data, as: UTF8.self))"
    }

    /// Built inside this nonisolated method. A closure written in top-level code after an `await` is main-actor
    /// isolated, so the recognizer would wait for the main thread, which `waitIdle` keeps blocked.
    func recognizer() -> OCRCache.Recognizer {
        { data in try await self.recognize(data) }
    }
}

/// Polls until the cache has no running or queued work. The main thread is blocked here, so the cache must not need it.
@discardableResult
func waitIdle(_ cache: OCRCache, timeout: TimeInterval = 60) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !cache.isIdle && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    return cache.isIdle
}

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("notchclip-ocr-tests-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

// MARK: - Real Vision recognition

let image = makeTextImage("Привет NotchClip 123")
check(ImageTextRecognizer.pixelCount(imageData: image) == 1400 * 300, "pixel count reads the PNG header")
check(ImageTextRecognizer.pixelCount(imageData: Data("not an image".utf8)) == nil, "pixel count of non-image data is nil")

let recognized = try await ImageTextRecognizer.recognize(imageData: image)
check(recognized.contains("NotchClip") && recognized.contains("123"),
      "OCR finds NotchClip and 123 (got: \(recognized.debugDescription))")

do {
    _ = try await ImageTextRecognizer.recognize(imageData: Data("garbage".utf8))
    check(false, "unreadable data throws unreadableImage")
} catch let error as ImageTextRecognizer.RecognitionError {
    check(error == .unreadableImage, "unreadable data throws unreadableImage")
} catch {
    check(false, "unreadable data throws unreadableImage")
}

// MARK: - Cache with a fake recognizer

let dataDir = root.appendingPathComponent("data", isDirectory: true)
let fake = FakeRecognizer()
let cache = OCRCache(dataDirectory: dataDir, recognizer: fake.recognizer(), pixelCount: { _ in nil })
check(cache.text(for: "a") == nil, "nothing is recognized before enqueue")
check(cache.isIdle, "a new cache is idle")

cache.enqueue(clipID: "a", imageData: { Data("A".utf8) })
cache.enqueue(clipID: "b", imageData: { Data("B".utf8) })
cache.enqueue(clipID: "a", imageData: { Data("A".utf8) })
waitIdle(cache)
check(cache.text(for: "a") == "text of A" && cache.text(for: "b") == "text of B", "queued images are recognized")
check(fake.callCount == 2, "a duplicate enqueue does not recognize twice")
check(fake.peakConcurrency == 1, "only one image is recognized at a time")
check(cache.matches(query: "TEXT of a", clipID: "a"), "matching ignores case")
check(!cache.matches(query: "zzz", clipID: "a"), "an absent word does not match")
check(!cache.matches(query: "   ", clipID: "a"), "a blank query matches nothing")
check(!cache.matches(query: "text", clipID: "missing"), "an unknown clip does not match")

cache.enqueue(clipID: "gone", imageData: { nil })
waitIdle(cache)
check(cache.text(for: "gone") == nil, "a clip without image data stores nothing")

let reloadedFake = FakeRecognizer()
let reloaded = OCRCache(dataDirectory: dataDir, recognizer: reloadedFake.recognizer(), pixelCount: { _ in nil })
check(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("ocr.json").path), "results are saved to ocr.json")
check(reloaded.text(for: "a") == "text of A", "saved results load in a new cache")
reloaded.enqueue(clipID: "a", imageData: { Data("A".utf8) })
waitIdle(reloaded)
check(reloadedFake.callCount == 0, "a clip with a saved result is not recognized again")

let bigFake = FakeRecognizer()
let bigCache = OCRCache(dataDirectory: root.appendingPathComponent("big", isDirectory: true),
                        recognizer: bigFake.recognizer(),
                        pixelCount: { _ in 25_000_000 })
bigCache.enqueue(clipID: "huge", imageData: { Data("H".utf8) })
waitIdle(bigCache)
check(bigFake.callCount == 0 && bigCache.text(for: "huge") == "", "images over 20 MP are skipped and stored as empty text")

let corruptDir = root.appendingPathComponent("corrupt", isDirectory: true)
try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
try Data("{not json".utf8).write(to: corruptDir.appendingPathComponent("ocr.json"))
check(OCRCache(dataDirectory: corruptDir, recognizer: { _ in "" }).text(for: "x") == nil,
      "a corrupt ocr.json starts an empty cache")

// MARK: - Cache with the real recognizer

let realCache = OCRCache(dataDirectory: root.appendingPathComponent("real", isDirectory: true))
realCache.enqueue(clipID: "img", imageData: { image })
waitIdle(realCache, timeout: 60)
check(realCache.matches(query: "notchclip", clipID: "img"), "the cache finds NotchClip in the generated image")
check((realCache.text(for: "img") ?? "").contains("123"), "the cache stores the recognized digits")

try? FileManager.default.removeItem(at: root)

if failures > 0 {
    print("\(failures) OCR check(s) failed")
    exit(1)
}
print("All OCR tests passed")
