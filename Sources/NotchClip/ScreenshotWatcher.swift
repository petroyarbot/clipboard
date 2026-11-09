import Foundation
import UniformTypeIdentifiers

/// Watches the macOS screenshot folder and reports screenshots created after `start()`.
///
/// Flow: a directory watch (plus a 2 s rescan) finds new files whose names start with a screenshot prefix and whose
/// type is an image. Each one waits until its size is stable (up to ~6 s), then:
/// After an optional move to ~/Pictures/Скриншоты, `onScreenshot(url)` runs on the main queue.
final class ScreenshotWatcher {
    static let historyKey = "screenshotsToHistory"
    static let moveKey = "screenshotsMoveEnabled"
    static let namePrefixes = ["Снимок экрана", "Screenshot", "Screen Shot"]
    static let stableTimeout: TimeInterval = 6

    let directory: URL
    let libraryDirectory: URL
    private let defaults: UserDefaults
    private let onScreenshot: (URL) -> Void
    private let fileSize: (URL) -> Int64?
    private let clock: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    private var seen: Set<String> = []
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var scanGeneration = 0
    private var scanInProgress = false

    init(directory: URL = ScreenshotWatcher.systemDirectory(),
         libraryDirectory: URL = ScreenshotWatcher.defaultLibraryDirectory(),
         defaults: UserDefaults = .standard,
         fileSize: @escaping (URL) -> Int64? = ScreenshotWatcher.fileSize(at:),
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         onScreenshot: @escaping (URL) -> Void) {
        self.directory = directory
        self.libraryDirectory = libraryDirectory
        self.defaults = defaults
        self.fileSize = fileSize
        self.clock = clock
        self.sleep = sleep
        self.onScreenshot = onScreenshot
    }

    deinit {
        stop()
    }

    /// The folder from the system screenshot setting (`com.apple.screencapture` location), or ~/Desktop.
    static func systemDirectory(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture"),
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let raw = defaults?.string(forKey: "location")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    static func defaultLibraryDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Скриншоты", isDirectory: true)
    }

    static func fileSize(at url: URL) -> Int64? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    /// True for "Снимок экрана…", "Screenshot…" and "Screen Shot…" files with an image type. Screen recordings are excluded.
    static func isScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), namePrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Snapshots the folder (existing files are ignored) and starts watching. Must be called on the main thread.
    func start() {
        guard timer == nil else { return }
        seen = Set(listScreenshots().map(\.lastPathComponent))

        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let watch = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )
            watch.setEventHandler { [weak self] in self?.rescan() }
            watch.setCancelHandler { close(descriptor) }
            watch.resume()
            source = watch
        }
        // The directory watch misses some writes, so a periodic rescan backs it up.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.rescan()
        }
    }

    func stop() {
        scanGeneration += 1
        scanInProgress = false
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
    }

    /// Finds screenshots that appeared since the last scan and waits for each to finish writing. Main thread only.
    func rescan() {
        guard !scanInProgress else { return }
        scanInProgress = true
        let generation = scanGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let urls = self.listScreenshots()
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.scanGeneration else { return }
                self.scanInProgress = false
                self.processScan(urls, generation: generation)
            }
        }
    }

    private func processScan(_ urls: [URL], generation: Int) {
        for url in urls where !seen.contains(url.lastPathComponent) {
            seen.insert(url.lastPathComponent)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let size = Self.awaitStableSize(
                    sample: { self.fileSize(url) },
                    clock: self.clock,
                    sleep: self.sleep,
                    timeout: Self.stableTimeout
                )
                DispatchQueue.main.async { [weak self] in
                    guard size != nil, let self, generation == self.scanGeneration else { return }
                    self.deliver(url)
                }
            }
        }
    }

    /// Samples the size until it is non-zero and unchanged for `stableSamples` samples in a row.
    /// After `timeout` it returns the last non-zero size, so a file that keeps growing is still delivered. Nil if the file never gets bytes.
    static func awaitStableSize(sample: () -> Int64?,
                                clock: () -> TimeInterval,
                                sleep: (TimeInterval) -> Void,
                                timeout: TimeInterval = ScreenshotWatcher.stableTimeout,
                                interval: TimeInterval = 0.25,
                                stableSamples: Int = 2) -> Int64? {
        let start = clock()
        var last: Int64?
        var matches = 0
        while true {
            let size = sample()
            if let size, size > 0, size == last {
                matches += 1
            } else {
                matches = 0
            }
            last = size
            if matches >= stableSamples { return size }
            if clock() - start >= timeout {
                if let last, last > 0 { return last }
                return nil
            }
            sleep(interval)
        }
    }

    /// Moves a file into `destination`, creating the folder if needed. A taken name gets " 2", " 3", ... before the extension.
    @discardableResult
    static func move(_ url: URL, to destination: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = uniqueURL(named: url.lastPathComponent, in: destination, fileManager: fileManager)
        try fileManager.moveItem(at: url, to: target)
        return target
    }

    static func uniqueURL(named name: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let file = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(file)
            index += 1
        }
        return candidate
    }

    private func deliver(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let destination = flag(Self.moveKey) ? ((try? Self.move(url, to: libraryDirectory)) ?? url) : url
        if flag(Self.historyKey) { onScreenshot(destination) }
    }

    /// Settings default to true when the key was never written.
    private func flag(_ key: String) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    private func listScreenshots() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter(Self.isScreenshot)
    }
}
