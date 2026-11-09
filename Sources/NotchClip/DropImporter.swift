import AppKit
import SwiftUI

// Handles the native drag pasteboard, including files that are created only
// after the drop. It never downloads a URL from the network. Files and images
// go through the same chooser as clipboard polling (ClipboardStore.importFiles).
@MainActor final class DropImporter {
    private let store: ClipboardStore
    init(store: ClipboardStore) { self.store = store }

    // Every type a drag source may offer for something we can import.
    static let dragTypes: [NSPasteboard.PasteboardType] = {
        let names = NSFilePromiseReceiver.readableDraggedTypes + [
            "public.file-url", "public.url", "public.image", "public.png", "public.jpeg", "public.heic",
            "org.webmproject.webp", "public.tiff", "com.apple.pasteboard.promised-file-url", "NSPromiseContentsPboardType",
        ]
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return (unique + [NSPasteboard.PasteboardType.string.rawValue]).map { NSPasteboard.PasteboardType($0) }
    }()

    func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self, NSURL.self, NSImage.self], options: nil)
            || pasteboard.availableType(from: Self.dragTypes) != nil
    }

    @discardableResult func importPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        if store.importFiles(from: pasteboard, dropped: true) { return true }
        let generation = store.importGeneration
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
        registerForDraggedTypes(DropImporter.dragTypes)
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

/// Passive drop surface over the closed notch. It does not activate the app.
@MainActor final class ShelfDropView: NSView {
    weak var delegate: AppDelegate?
    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(frame: .zero)
        registerForDraggedTypes(DropImporter.dragTypes)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let delegate else { return false }
        defer { delegate.scheduleShelfDropHide() }
        let board = sender.draggingPasteboard
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            Task { @MainActor in
                let items = await delegate.shelf.add(urls: urls)
                if !items.isEmpty { delegate.liveActivity?.showToast("На полке: \(items.count)") }
            }
            return true
        }
        if let image = PasteboardImages.rawCandidates(from: board).lazy.compactMap(PasteboardImages.png(from:)).first {
            Task { @MainActor in
                if await delegate.shelf.add(data: image, named: "Изображение.png") != nil {
                    delegate.liveActivity?.showToast("На полке: 1")
                }
            }
            return true
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            Task { @MainActor in
                if await delegate.shelf.addText(text) != nil { delegate.liveActivity?.showToast("На полке: 1") }
            }
            return true
        }
        return false
    }
}
