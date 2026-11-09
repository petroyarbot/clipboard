import Foundation
import ImageIO
import Vision

/// Text recognition for image clips with Vision (accurate, Russian and English, language correction).
enum ImageTextRecognizer {
    static let languages = ["ru-RU", "en-US"]

    enum RecognitionError: Error, Equatable {
        case unreadableImage
    }

    /// Runs Vision off the main thread. Lines are joined with "\n".
    static func recognize(imageData: Data) async throws -> String {
        try await Task.detached(priority: .utility) {
            guard let image = cgImage(from: imageData) else { throw RecognitionError.unreadableImage }
            return try recognize(cgImage: image)
        }.value
    }

    /// Synchronous recognition. Call it off the main thread.
    static func recognize(cgImage: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Width times height from the image header, without decoding the pixels. Nil if the data is not an image.
    static func pixelCount(imageData: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return width * height
    }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Recognized text per clip id, saved in `<dataDir>/ocr.json` as {"clipID": "text"}.
///
/// `enqueue` queues an image clip. Jobs run one at a time on a background task. Clips that already have a result are skipped.
/// Images over `maxPixels` get an empty text and are not decoded. `imageData` is called on the background task, so the caller
/// must make it thread-safe (reading a file is fine).
final class OCRCache {
    static let fileName = "ocr.json"
    static let maxPixels = 20_000_000

    typealias Recognizer = (Data) async throws -> String

    private struct Job {
        let id: String
        let imageData: () -> Data?
    }

    private let fileURL: URL
    private let recognizer: Recognizer
    private let pixelCount: (Data) -> Int?
    private let lock = NSLock()
    private var entries: [String: String]
    private var jobs: [Job] = []
    private var queued: Set<String> = []
    private var running = false

    init(dataDirectory: URL,
         recognizer: @escaping Recognizer = { try await ImageTextRecognizer.recognize(imageData: $0) },
         pixelCount: @escaping (Data) -> Int? = ImageTextRecognizer.pixelCount(imageData:)) {
        self.fileURL = dataDirectory.appendingPathComponent(Self.fileName)
        self.recognizer = recognizer
        self.pixelCount = pixelCount
        self.entries = Self.load(from: fileURL)
    }

    /// True when no image is waiting or being read.
    var isIdle: Bool {
        locked { !running && jobs.isEmpty }
    }

    /// Recognized text, or nil if the clip has not been processed. An empty string means no text or a skipped image.
    func text(for clipID: String) -> String? {
        locked { entries[clipID] }
    }

    /// True when the clip's text contains `query`, ignoring case and diacritics. A blank query never matches.
    func matches(query: String, clipID: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let text = text(for: clipID), !text.isEmpty else { return false }
        return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Queues recognition for an image clip. Does nothing if the clip already has a result or is queued.
    func enqueue(clipID: String, imageData: @escaping () -> Data?) {
        let shouldStart: Bool = locked {
            guard entries[clipID] == nil, !queued.contains(clipID) else { return false }
            queued.insert(clipID)
            jobs.append(Job(id: clipID, imageData: imageData))
            guard !running else { return false }
            running = true
            return true
        }
        if shouldStart {
            Task.detached(priority: .utility) {
                await self.drain()
            }
        }
    }

    private func drain() async {
        while let job = nextJob() {
            let stored = await recognize(job)
            locked {
                if let stored {
                    entries[job.id] = stored
                }
                queued.remove(job.id)
            }
            save()
        }
    }

    /// Returns the next job, or clears `running` and returns nil when the queue is empty. Both happen under the lock,
    /// so an enqueue that lands right after cannot be left without a runner.
    private func nextJob() -> Job? {
        locked {
            guard !jobs.isEmpty else {
                running = false
                return nil
            }
            return jobs.removeFirst()
        }
    }

    /// The text to store, or nil when there are no image bytes (nothing is stored, so a later enqueue retries).
    private func recognize(_ job: Job) async -> String? {
        guard let data = job.imageData() else { return nil }
        if let pixels = pixelCount(data), pixels > Self.maxPixels {
            return ""
        }
        return (try? await recognizer(data)) ?? ""
    }

    private func save() {
        let snapshot = locked { entries }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
