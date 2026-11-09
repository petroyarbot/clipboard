import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct StoredFile: Codable {
    let id: UUID
    let name: String
}

// Recognises image files for import: by extension when it names a known type, otherwise by magic bytes.
enum ImageFiles {
    // Folders the user keeps files in. A file here is always imported as a file, never as an image clip.
    static let userFolderMarkers = ["/Desktop/", "/Documents/", "/Downloads/"]
    // App containers, caches and temporary folders, where apps such as Telegram keep media.
    static let appStorageMarkers = ["/Library/Group Containers/", "/Library/Containers/", "/Library/Caches/", "/private/var/folders/"]

    static func isInAppStorage(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if userFolderMarkers.contains(where: { path.contains($0) }) { return false }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        return appStorageMarkers.contains(where: { path.contains($0) })
            || path.hasPrefix(temporary.hasSuffix("/") ? temporary : temporary + "/")
    }

    // A known image extension decides; a missing or unknown one is decided by the first bytes.
    static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) { return type.conforms(to: .image) }
        return sniffedExtension(of: url) != nil
    }

    // The extension of the image format named by the file's first bytes, or nil.
    static func sniffedExtension(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 12)) ?? Data())
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        func text(_ value: String) -> [UInt8] { Array(value.utf8) }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts(text("GIF8")) { return "gif" }
        if starts(text("RIFF")) && starts(text("WEBP"), at: 8) { return "webp" }
        if starts(text("ftyp"), at: 4), head.count >= 12,
           ["heic", "heix", "heim", "heis", "hevc", "mif1", "msf1"].contains(String(decoding: head[8..<12], as: UTF8.self)) { return "heic" }
        return nil
    }

    // The name to store: the source's own name, plus the extension its bytes name when the name has none.
    static func storedName(for source: URL) -> String {
        let name = source.lastPathComponent
        guard source.pathExtension.isEmpty, let ext = sniffedExtension(of: source) else { return name }
        return "\(name).\(ext)"
    }
}

enum FileVault {
    // Stores one dropped or copied file. An image from app storage becomes an image clip (PNG); anything else a file clip.
    static func clip(for source: URL, into root: URL) throws -> Clip {
        if ImageFiles.isInAppStorage(source), ImageFiles.isImage(source), let data = try? Data(contentsOf: source),
           let png = PasteboardImages.png(from: data) {
            return Clip(kind: .image, data: png)
        }
        return try copy(source, into: root)
    }

    static func copy(_ source: URL, into root: URL) throws -> Clip {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        guard attributes.isRegularFile == true, attributes.isDirectory != true else {
            throw NSError(domain: "NotchClip", code: 1, userInfo: [NSLocalizedDescriptionKey: "Можно добавить только обычный файл, не папку."])
        }
        let record = StoredFile(id: UUID(), name: ImageFiles.storedName(for: source))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = root.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(record.name))
            return Clip(kind: .file, data: try JSONEncoder().encode(record))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
    static func url(for clip: Clip, root: URL) -> URL? {
        guard clip.kind == .file, let record = try? JSONDecoder().decode(StoredFile.self, from: clip.data), record.name == URL(fileURLWithPath: record.name).lastPathComponent else { return nil }
        return root.appendingPathComponent(record.id.uuidString, isDirectory: true).appendingPathComponent(record.name)
    }
}

// Raw image bytes that apps put on the pasteboard, converted to PNG for storage.
enum PasteboardImages {
    static let types: [NSPasteboard.PasteboardType] = ["public.png", "public.jpeg", "public.heic", "org.webmproject.webp", "public.tiff"].map { NSPasteboard.PasteboardType($0) }

    /// True when the pasteboard offers image data. Reads type names only, so it is cheap on every change.
    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.types ?? []).contains { types.contains($0) || $0 == .tiff }
    }

    /// Copies the bytes of each item's first image type, TIFF as a last resort. Nothing is decoded here.
    static func rawCandidates(from pasteboard: NSPasteboard) -> [Data] {
        var candidates: [Data] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let type = types.first(where: { item.types.contains($0) }), let data = item.data(forType: type) else { continue }
            candidates.append(data)
        }
        if candidates.isEmpty, let tiff = pasteboard.data(forType: .tiff) { candidates.append(tiff) }
        return candidates
    }

    // ImageIO decodes PNG, JPEG, HEIC, WebP and TIFF, so every format goes through one path.
    static func png(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// Writes copies into the Downloads folder on a serial background queue.
enum DownloadsWriter {
    private static let queue = DispatchQueue(label: "NotchClip.downloads", qos: .utility)

    static func save(named name: String, in directory: URL, write: @escaping (URL) throws -> Void) {
        queue.async {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var number = 1
                var target = directory.appendingPathComponent(name)
                while FileManager.default.fileExists(atPath: target.path) {
                    number += 1
                    target = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
                }
                try write(target)
            } catch {
                NSLog("NotchClip: could not save a copy to Downloads: %@", error.localizedDescription)
            }
        }
    }
}

private struct FolderHasNoMedia: Error {}

// One file-promise drag. `remaining` counts receivers that have not finished, not files.
@MainActor private final class PromiseBatch {
    let destination: URL
    let pasteboard: NSPasteboard
    let generation: Int
    let typeNames: [String]
    var remaining: Int
    var imported = 0
    var lastError: Error?
    var finished = false
    init(destination: URL, pasteboard: NSPasteboard, generation: Int, typeNames: [String], remaining: Int) {
        self.destination = destination; self.pasteboard = pasteboard; self.generation = generation; self.typeNames = typeNames; self.remaining = remaining
    }
}

// Progress of one receiver: it finishes after all its files arrive, or after its first error.
@MainActor private final class PromiseReceiverProgress {
    let expected: Int
    var seen = 0
    var done = false
    init(expected: Int) { self.expected = expected }
}

private struct PromiseTimeout: Error {}

@MainActor final class ClipboardStore: ObservableObject {
    static let downloadsKey = "saveToDownloads"
    static let accessFailureMessage = "Приложение не дало доступ к файлу. Попробуй «Копировать» или «Сохранить как»."
    static let folderWithoutMediaMessage = "В папке нет изображений или медиафайлов."
    static let missingFileMessage = "Файл не найден."
    static let fullDiskAccessMessage = "Нет доступа к файлам другого приложения. Дай NotchClip «Полный доступ к диску»."
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    nonisolated static let maxFolderFiles = 20

    // Opens a TCC-protected file read-only to see whether Full Disk Access is granted. Reads no content.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let probe = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
        guard FileManager.default.fileExists(atPath: probe), let handle = FileHandle(forReadingAtPath: probe) else { return false }
        try? handle.close()
        return true
    }

    @Published private(set) var history: History
    @Published var errorMessage: String?
    private let pasteboard: NSPasteboard
    private let fileURL: URL
    private let downloadsDirectory: URL
    private var changeCount: Int
    private var timer: Timer?
    private var canSave = true
    private(set) var importGeneration = 0
    var filesDirectory: URL { fileURL.deletingLastPathComponent().appendingPathComponent("Files", isDirectory: true) }

    init(pasteboard: NSPasteboard = .general, fileURL: URL? = nil, downloadsDirectory: URL? = nil) {
        self.pasteboard = pasteboard
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchClip", isDirectory: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("history.json")
        self.downloadsDirectory = downloadsDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        self.history = (try? Data(contentsOf: self.fileURL)).flatMap { try? JSONDecoder().decode(History.self, from: $0) } ?? History()
        self.changeCount = pasteboard.changeCount
        if FileManager.default.fileExists(atPath: self.fileURL.path), (try? JSONDecoder().decode(History.self, from: Data(contentsOf: self.fileURL))) == nil {
            self.errorMessage = "Не удалось прочитать сохранённую историю. Файл не будет перезаписан до восстановления."
            self.canSave = false
        }
    }
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func poll() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        let ignored = ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType"]
        guard !(pasteboard.types ?? []).contains(where: { ignored.contains($0.rawValue) }) else { return }
        if Self.hasFileItems(pasteboard) {
            importFiles(from: pasteboard, dropped: false)
        } else if let value = pasteboard.string(forType: .string), !value.isEmpty, let data = value.data(using: .utf8) {
            add(Clip(kind: .text, data: data))
        } else {
            importFiles(from: pasteboard, dropped: false)
        }
    }
    func importFileSynchronously(_ url: URL) throws {
        guard canSave else { throw NSError(domain: "NotchClip", code: 2, userInfo: [NSLocalizedDescriptionKey: "Историю нельзя сохранить."]) }
        let clip = try FileVault.copy(url, into: filesDirectory)
        add(clip, capture: true)
    }

    nonisolated static func hasFileItems(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    // The one import chooser for clipboard polling and drag-and-drop. Order: file
    // promises, readable file URLs (folders contribute their media), then raw image
    // bytes. Returns false only when the pasteboard offers none of these, so the caller
    // can fall back to text.
    @discardableResult
    func importFiles(from pasteboard: NSPasteboard, dropped: Bool) -> Bool {
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !promises.isEmpty || !urls.isEmpty || PasteboardImages.hasImage(pasteboard) else { return false }
        guard canSave else { errorMessage = "Историю нельзя сохранить."; return true }
        let generation = importGeneration
        let typeNames = (pasteboard.types ?? []).map(\.rawValue)
        if !promises.isEmpty {
            receivePromises(promises, pasteboard: pasteboard, generation: generation, typeNames: typeNames)
        } else if !urls.isEmpty {
            importURLs(urls, pasteboard: pasteboard, generation: generation, dropped: dropped, typeNames: typeNames)
        } else {
            // Image-only pasteboard: bytes are copied now and converted off the main actor.
            addImage(PasteboardImages.rawCandidates(from: pasteboard), generation: generation)
        }
        return true
    }

    // Used only after a file import has failed: copies the image bytes now, converts them off the main actor.
    private func addImageFallback(from pasteboard: NSPasteboard, generation: Int) -> Bool {
        let candidates = PasteboardImages.rawCandidates(from: pasteboard)
        guard !candidates.isEmpty else { return false }
        addImage(candidates, generation: generation)
        return true
    }

    // Decodes to PNG on a background queue, then adds on the main actor through addImported's generation guard.
    private func addImage(_ candidates: [Data], generation: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let png = candidates.lazy.compactMap(PasteboardImages.png(from:)).first
            Task { @MainActor in
                guard let self else { return }
                if let png {
                    self.addImported(Clip(kind: .image, data: png), generation: generation)
                } else if generation == self.importGeneration {
                    self.errorMessage = Self.accessFailureMessage
                }
            }
        }
    }

    private func importURLs(_ urls: [URL], pasteboard: NSPasteboard, generation: Int, dropped: Bool, typeNames: [String]) {
        let root = filesDirectory
        let downloads = downloadsDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var clips: [ImportedClip] = []
            var failures: [ImportFailure] = []
            var lines = typeNames.map { "type: \($0)" }
            for url in urls {
                lines.append("file url: \(url.path) readable=\(FileManager.default.isReadableFile(atPath: url.path))")
                do {
                    let fromDownloads = Self.isInside(url, directory: downloads)
                    clips += try Self.copyFiles(from: url, into: root).map { ImportedClip(clip: $0, fromDownloads: fromDownloads) }
                } catch {
                    lines.append("error: \(error.localizedDescription)")
                    failures.append(ImportFailure(url: url, needsAccess: Self.needsSourcePermission(error, source: url),
                                                  noMedia: error is FolderHasNoMedia, missing: !FileManager.default.fileExists(atPath: url.path),
                                                  denied: Self.isPermissionDenied(error, source: url)))
                }
            }
            let result = URLImportResult(clips: clips, failures: failures, diagnostics: lines.joined(separator: "\n"))
            Task { @MainActor in self?.finishURLImport(result, pasteboard: pasteboard, dropped: dropped, generation: generation) }
        }
    }

    // Copies one file, or the media files directly inside a folder (at most maxFolderFiles).
    nonisolated static func copyFiles(from original: URL, into root: URL) throws -> [Clip] {
        let scoped = original.startAccessingSecurityScopedResource()
        defer { if scoped { original.stopAccessingSecurityScopedResource() } }
        let source = original.resolvingSymlinksInPath()
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard isFolder else { return [try FileVault.clip(for: source, into: root)] }
        let items = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey], options: [.skipsHiddenFiles])
            .filter(isMedia)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !items.isEmpty else { throw FolderHasNoMedia() }
        var clips: [Clip] = []
        var lastError: Error?
        for item in items.prefix(maxFolderFiles) {
            do { clips.append(try FileVault.clip(for: item, into: root)) } catch { lastError = error }
        }
        if clips.isEmpty, let lastError { throw lastError }
        return clips
    }

    nonisolated private static func isMedia(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
              values.isRegularFile == true, let type = values.contentType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
    }

    private func finishURLImport(_ result: URLImportResult, pasteboard: NSPasteboard, dropped: Bool, generation: Int) {
        if !result.clips.isEmpty {
            for item in result.clips { addImported(item.clip, generation: generation, fromDownloads: item.fromDownloads) }
            return
        }
        if addImageFallback(from: pasteboard, generation: generation) { return }
        guard generation == importGeneration else { return }
        if dropped, result.failures.count == 1, result.failures[0].needsAccess {
            importDroppedFileWithAccess(result.failures[0].url, generation: generation)
            return
        }
        writeImportDiagnostics(result.diagnostics)
        if result.failures.allSatisfy(\.noMedia) { errorMessage = Self.folderWithoutMediaMessage }
        else if result.failures.allSatisfy(\.missing) { errorMessage = Self.missingFileMessage }
        else if result.failures.contains(where: \.denied) { errorMessage = Self.fullDiskAccessMessage }
        else { errorMessage = Self.accessFailureMessage }
    }

    private func receivePromises(_ promises: [NSFilePromiseReceiver], pasteboard: NSPasteboard, generation: Int, typeNames: [String]) {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("NotchClip-drop-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { errorMessage = "Не удалось подготовить папку для файла: \(error.localizedDescription)"; return }
        let batch = PromiseBatch(destination: destination, pasteboard: pasteboard, generation: generation, typeNames: typeNames,
                                 remaining: promises.count)
        let root = filesDirectory
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        for promise in promises {
            let receiver = PromiseReceiverProgress(expected: max(1, promise.fileNames.count))
            promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { [weak self] url, error in
                let result: Result<Clip, Error>
                do {
                    if let error { throw error }
                    result = .success(try FileVault.clip(for: url, into: root))
                } catch {
                    result = .failure(error)
                }
                Task { @MainActor in self?.promiseFinished(result, receiver: receiver, batch: batch) }
            }
        }
        // A receiver that never calls back must not keep the temporary folder and the import open forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !batch.finished else { return }
            batch.lastError = batch.lastError ?? PromiseTimeout()
            self.finishPromiseBatch(batch)
        }
    }

    private func promiseFinished(_ result: Result<Clip, Error>, receiver: PromiseReceiverProgress, batch: PromiseBatch) {
        switch result {
        case .success(let clip):
            batch.imported += 1
            receiver.seen += 1
            addImported(clip, generation: batch.generation)
        case .failure(let error):
            batch.lastError = error
            receiver.seen = receiver.expected
        }
        if !receiver.done && receiver.seen >= receiver.expected {
            receiver.done = true
            batch.remaining -= 1
        }
        if batch.remaining == 0 { finishPromiseBatch(batch) }
    }

    private func finishPromiseBatch(_ batch: PromiseBatch) {
        guard !batch.finished else { return }
        batch.finished = true
        try? FileManager.default.removeItem(at: batch.destination)
        guard batch.imported == 0 else { return }
        if addImageFallback(from: batch.pasteboard, generation: batch.generation) { return }
        var lines = batch.typeNames.map { "type: \($0)" }
        lines.append("file promise error: \(batch.lastError?.localizedDescription ?? "none")")
        writeImportDiagnostics(lines.joined(separator: "\n"))
        if batch.generation == importGeneration { errorMessage = Self.accessFailureMessage }
    }

    // True when `url` is inside `directory`. Both paths are resolved and standardized first.
    nonisolated static func isInside(_ url: URL, directory: URL) -> Bool {
        let file = url.resolvingSymlinksInPath().standardizedFileURL.path
        let folder = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return file.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    nonisolated static func needsSourcePermission(_ error: Error, source: URL) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain,
              [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) else { return false }
        // copyItem can report a write error even when the source is protected.
        // Ask for its parent only when that source itself is not readable; a
        // failure writing our own vault cannot be fixed by that permission.
        return !FileManager.default.isReadableFile(atPath: source.path)
    }

    // True when the file exists but macOS refuses access (sandbox/TCC denial, EPERM, or unreadable mode bits).
    nonisolated static func isPermissionDenied(_ error: Error, source: URL) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == EPERM { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == EPERM { return true }
        let fm = FileManager.default
        return fm.fileExists(atPath: source.path) && !fm.isReadableFile(atPath: source.path)
    }

    // Overwrites a small text report with the pasteboard type names and file-URL
    // readability. It never contains clip contents.
    private func writeImportDiagnostics(_ text: String) {
        let directory = fileURL.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try text.write(to: directory.appendingPathComponent("last-import-failure.txt"), atomically: true, encoding: .utf8)
            } catch {
                NSLog("NotchClip: could not write import diagnostics: %@", error.localizedDescription)
            }
        }
    }

    nonisolated static func shouldRetryDroppedFileAccess(_ error: Error, usedCachedBookmark: Bool, sourceReadable: Bool) -> Bool {
        let error = error as NSError
        return usedCachedBookmark && !sourceReadable && error.domain == NSCocoaErrorDomain &&
            [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)
    }
    func importDroppedFileWithAccess(_ source: URL, generation: Int, reuseSavedAccess: Bool = true) {
        guard generation == importGeneration, canSave else { return }
        let parent = source.deletingLastPathComponent().standardizedFileURL
        let key = "dropFolderBookmark"
        var stale = false
        var folder = (reuseSavedAccess ? UserDefaults.standard.data(forKey: key) : nil).flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        if stale || folder?.standardizedFileURL != parent { folder = nil }
        let usedCachedBookmark = folder != nil
        if folder == nil {
            let panel = NSOpenPanel()
            panel.title = "Доступ к перетаскиваемому файлу"
            panel.message = "macOS закрыла доступ к файлу. Выбери предложенную папку, чтобы сохранить файл. Приложение получит доступ к файлам выбранной папки."
            panel.prompt = "Разрешить"
            panel.directoryURL = parent
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let selected = panel.url else {
                errorMessage = "Не удалось получить доступ к файлу."
                return
            }
            guard selected.standardizedFileURL == parent else {
                errorMessage = "Выбери папку, содержащую перетаскиваемый файл."
                return
            }
            folder = selected
        }
        guard let folder else { return }
        let accessing = folder.startAccessingSecurityScopedResource()
        let sourceInFolder = folder.appendingPathComponent(source.lastPathComponent)
        let root = filesDirectory
        let fromDownloads = Self.isInside(source, directory: downloadsDirectory)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            do {
                let clip = try FileVault.clip(for: sourceInFolder, into: root)
                let bookmark = try? folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                Task { @MainActor in
                    guard let self else { return }
                    if let bookmark { UserDefaults.standard.set(bookmark, forKey: key) }
                    self.addImported(clip, generation: generation, fromDownloads: fromDownloads)
                }
            } catch {
                let retry = Self.shouldRetryDroppedFileAccess(error, usedCachedBookmark: usedCachedBookmark,
                    sourceReadable: FileManager.default.isReadableFile(atPath: sourceInFolder.path))
                Task { @MainActor in
                    guard let self, generation == self.importGeneration else { return }
                    UserDefaults.standard.removeObject(forKey: key)
                    if retry { self.importDroppedFileWithAccess(source, generation: generation, reuseSavedAccess: false) }
                    else { self.errorMessage = "Не удалось открыть файл даже после выбора папки: \(error.localizedDescription)" }
                }
            }
        }
    }
    // `fromDownloads`: the original file already lives in Downloads, so no second copy is saved there.
    func addImported(_ clip: Clip, generation: Int, fromDownloads: Bool = false) {
        guard generation == importGeneration, canSave else {
            if let url = managedFileURL(for: clip) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            if !canSave { errorMessage = "Историю нельзя сохранить." }
            return
        }
        add(clip, capture: true, copyToDownloads: !fromDownloads)
    }
    func managedFileURL(for clip: Clip) -> URL? { FileVault.url(for: clip, root: filesDirectory) }
    @discardableResult func select(_ clip: Clip) -> Bool {
        var objects: [NSPasteboardWriting] = []
        var text: String?
        switch clip.kind {
        case .file:
            guard let url = exportFile(for: clip) else { return false }
            objects = [url as NSURL]
        case .image:
            guard let image = NSImage(data: clip.data) else { errorMessage = "Не удалось прочитать изображение."; return false }
            objects = [image]
        case .text:
            guard let value = String(data: clip.data, encoding: .utf8) else { errorMessage = "Не удалось прочитать текст."; return false }
            text = value
        }
        pasteboard.clearContents()
        let success = text.map { pasteboard.setString($0, forType: .string) } ?? pasteboard.writeObjects(objects)
        guard success else { errorMessage = "Не удалось вернуть запись в буфер обмена."; return false }
        changeCount = pasteboard.changeCount; add(clip); return true
    }
    func exportFile(for clip: Clip) -> URL? {
        guard let source = managedFileURL(for: clip), FileManager.default.fileExists(atPath: source.path) else {
            errorMessage = "Сохранённый файл не найден."; return nil
        }
        let exports = FileManager.default.temporaryDirectory.appendingPathComponent("NotchClip-exports", isDirectory: true)
        if let old = try? FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for item in old where UUID(uuidString: item.lastPathComponent) != nil {
                if let date = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < Date().addingTimeInterval(-86400) {
                    try? FileManager.default.removeItem(at: item)
                }
            }
        }
        let folder = exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let exported = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: exported)
            return exported
        } catch { errorMessage = "Не удалось подготовить файл: \(error.localizedDescription)"; return nil }
    }
    func togglePin(_ id: UUID) { let previous = history.clips; history.togglePin(id); persistAndClean(previous) }
    func edit(_ id: UUID, text: String) { history.edit(id, text: text); _ = save() }
    func remove(_ id: UUID) { let previous = history.clips; history.remove(id); persistAndClean(previous) }
    func clear() { importGeneration += 1; let previous = history.clips; history.clear(); persistAndClean(previous) }
    func clearAll() { importGeneration += 1; let previous = history.clips; history.clearAll(); persistAndClean(previous) }

    // `capture` marks a newly imported or copied item. Only those are also saved to
    // Downloads; re-selecting an existing item, relaunching, and loading history never are.
    // A Downloads copy is saved only for a NEW clip: a deduplicated image is already in history and already saved.
    private func add(_ clip: Clip, capture: Bool = false, copyToDownloads: Bool = true) {
        let previous = history.clips
        let inserted = history.add(clip)
        guard persistAndClean(previous), capture, inserted, copyToDownloads else { return }
        let enabled = UserDefaults.standard.object(forKey: Self.downloadsKey) as? Bool ?? true
        if enabled { saveCopyToDownloads(clip) }
    }

    private func saveCopyToDownloads(_ clip: Clip) {
        let directory = downloadsDirectory
        switch clip.kind {
        case .text:
            return
        case .image:
            let data = clip.data
            DownloadsWriter.save(named: "NotchClip \(Self.stampFormatter.string(from: Date())).png", in: directory) { target in
                try data.write(to: target, options: .withoutOverwriting)
            }
        case .file:
            guard let source = managedFileURL(for: clip) else { return }
            DownloadsWriter.save(named: source.lastPathComponent, in: directory) { target in
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
    }
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    @discardableResult private func persistAndClean(_ old: [Clip]) -> Bool {
        guard save() else { return false }
        let retained = Set(history.clips.map(\.id))
        for item in old where item.kind == .file && !retained.contains(item.id) {
            if let url = managedFileURL(for: item) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        return true
    }
    @discardableResult private func save() -> Bool {
        guard canSave else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(history).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            errorMessage = nil; return true
        } catch { errorMessage = "Не удалось сохранить историю: \(error.localizedDescription)"; return false }
    }
}

// Per-file failure from a folder or file-URL import, kept until the main actor decides.
private struct ImportFailure {
    let url: URL
    let needsAccess: Bool
    let noMedia: Bool
    let missing: Bool
    let denied: Bool
}

// A clip from a file import, and whether its original file already lives in Downloads.
private struct ImportedClip {
    let clip: Clip
    let fromDownloads: Bool
}

private struct URLImportResult {
    let clips: [ImportedClip]
    let failures: [ImportFailure]
    let diagnostics: String
}
