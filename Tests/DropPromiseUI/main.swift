import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class PromiseSource: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private var provider: NSFilePromiseProvider?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ("Перетащи отсюда →" as NSString).draw(at: NSPoint(x: 25, y: 110), withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.labelColor])
    }
    override func mouseDown(with event: NSEvent) {
        let p = NSFilePromiseProvider(fileType: UTType.pdf.identifier, delegate: self)
        provider = p
        let item = NSDraggingItem(pasteboardWriter: p)
        let preview = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 60, height: 60))
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 60, height: 60), contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "promise-test.pdf" }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try Data("NotchClip promise test".utf8).write(to: url); print("PROMISE_WRITTEN"); fflush(stdout); completionHandler(nil) }
        catch { print("PROMISE_WRITE_ERROR \(error)"); fflush(stdout); completionHandler(error) }
    }
}

@MainActor final class HarnessDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var store: ClipboardStore!
    var panelDelegate: AppDelegate!
    var monitor: Timer?
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchclip-promise-test-\(UUID())")
    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ClipboardStore(pasteboard: NSPasteboard(name: .init("notchclip-promise-test-\(UUID())")), fileURL: root.appendingPathComponent("history.json"))
        panelDelegate = AppDelegate(store: store)
        window = NSWindow(contentRect: NSRect(x: 300, y: 250, width: 600, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NotchClip: тест приёма файла"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 250))
        let source = PromiseSource(frame: NSRect(x: 0, y: 0, width: 290, height: 250))
        let target = DropHostingView(rootView: AnyView(Text("← Отпусти файл здесь").font(.system(size: 20)).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.green.opacity(0.25))), store: store, delegate: panelDelegate)
        target.frame = NSRect(x: 310, y: 0, width: 290, height: 250)
        content.addSubview(source); content.addSubview(target); window.contentView = content
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        monitor = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let clip = self.store.history.clips.first, clip.kind == .file,
               let url = self.store.managedFileURL(for: clip), let bytes = try? Data(contentsOf: url), bytes == Data("NotchClip promise test".utf8) {
                try? Data("PASS: real NSFilePromiseProvider drag imported correct file bytes".utf8).write(to: URL(fileURLWithPath: "/tmp/notchclip-promise-result.txt")); self.monitor?.invalidate()
            } else if let error = self.store.errorMessage { try? Data("ERROR: \(error)".utf8).write(to: URL(fileURLWithPath: "/tmp/notchclip-promise-result.txt")); self.monitor?.invalidate() }
        }
        print("READY: drag from blue left box to green right box"); fflush(stdout)
    }
    func applicationWillTerminate(_ notification: Notification) { try? FileManager.default.removeItem(at: root) }
}
@main struct PromiseHarness {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = HarnessDelegate(); app.delegate = delegate; app.run()
    }
}
