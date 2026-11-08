import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Handles the native drag pasteboard, including files that are created only
// after the drop. It never downloads a URL from the network.
@MainActor final class DropImporter {
    private let store: ClipboardStore
    init(store: ClipboardStore) { self.store = store }

    nonisolated static func needsSourcePermission(_ error: Error, source: URL) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain,
              [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) else { return false }
        // copyItem can report a write error even when the source is protected.
        // Ask for its parent only when that source itself is not readable; a
        // failure writing our own vault cannot be fixed by that permission.
        return !FileManager.default.isReadableFile(atPath: source.path)
    }

    func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self, NSURL.self, NSImage.self], options: nil)
            || pasteboard.availableType(from: [.string]) != nil
    }

    @discardableResult func importPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        let generation = store.importGeneration
        let root = store.filesDirectory
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            receive(promises, into: root, generation: generation)
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls { importFile(url, into: root, generation: generation) }
            return true
        }
        let hasImageBytes = (pasteboard.types ?? []).contains { UTType($0.rawValue)?.conforms(to: .image) == true }
        if hasImageBytes, let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            store.addImported(Clip(kind: .image, data: png), generation: generation)
            return true
        }
        let rawURL = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first
        let rawText = pasteboard.string(forType: .string)
        let text = rawURL.flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0.absoluteString : nil } ?? rawText
        guard let text, !text.isEmpty, let data = text.data(using: .utf8) else { return false }
        let clip = Clip(kind: .text, data: data)
        store.addImported(clip, generation: generation)
        if clip.linkURL != nil, store.history.clips.contains(where: { $0.kind == .text && $0.data == data }) {
            store.errorMessage = "Сохранена ссылка. Чтобы сохранить сам файл, сначала скачай его."
        }
        return true
    }

    private func importFile(_ source: URL, into root: URL, generation: Int) {
        // Keep any grant supplied by AppKit active until copying finishes.
        let scoped = source.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async { [weak store] in
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                let clip = try FileVault.copy(source, into: root)
                Task { @MainActor in store?.addImported(clip, generation: generation) }
            } catch {
                let needsAccess = DropImporter.needsSourcePermission(error, source: source)
                Task { @MainActor in
                    guard let store, generation == store.importGeneration else { return }
                    if needsAccess {
                        store.importDroppedFileWithAccess(source, generation: generation)
                    } else {
                        store.errorMessage = "Не удалось добавить файл: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func receive(_ promises: [NSFilePromiseReceiver], into root: URL, generation: Int) {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("NotchClip-drop-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { store.errorMessage = "Не удалось подготовить папку для файла: \(error.localizedDescription)"; return }
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        var remaining = promises.reduce(0) { $0 + max(1, $1.fileNames.count) }
        for promise in promises {
          promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { [weak store] url, error in
            defer {
                remaining -= 1
                if remaining == 0 { try? FileManager.default.removeItem(at: destination) }
            }
            do {
                if let error { throw error }
                let clip = try FileVault.copy(url, into: root)
                Task { @MainActor in store?.addImported(clip, generation: generation) }
            } catch {
                Task { @MainActor in
                    guard let store, generation == store.importGeneration else { return }
                    store.errorMessage = "Не удалось получить файл: \(error.localizedDescription)"
                }
            }
          }
        }
    }
}

// A hosting view is the actual drop destination; it leaves normal hit testing
// and SwiftUI controls untouched while exposing NSDraggingInfo to AppKit.
@MainActor final class DropHostingView: NSHostingView<AnyView> {
    private let importer: DropImporter
    private weak var delegate: AppDelegate?
    init(rootView: AnyView, store: ClipboardStore, delegate: AppDelegate) {
        self.importer = DropImporter(store: store)
        self.delegate = delegate
        super.init(rootView: rootView)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(promiseTypes + [.fileURL, .URL, .tiff, .png, .string])
    }
    required init(rootView: AnyView) { fatalError("init(rootView:) is not supported") }
    @objc required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = importer.canAccept(sender.draggingPasteboard)
        delegate?.dropTargeted = accepted
        return accepted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        importer.canAccept(sender.draggingPasteboard) ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { delegate?.dropTargeted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        delegate?.dropTargeted = false
        return importer.importPasteboard(sender.draggingPasteboard)
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { delegate?.dropTargeted = false }
}
