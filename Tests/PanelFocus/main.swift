import AppKit
import SwiftUI
import Foundation
@main struct PanelFocusCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("notchclip-focus-\(UUID().uuidString)")
        let board = NSPasteboard(name: .init("notchclip-focus-\(UUID().uuidString)"))
        app.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let source = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            source.title = "NotchClip — тест фокуса"
            let field = NSTextField(string: "Тестовый текст")
            field.frame = NSRect(x: 20, y: 70, width: 240, height: 24)
            source.contentView?.addSubview(field)
            app.activate(ignoringOtherApps: true)
            source.makeKeyAndOrderFront(nil)
            source.makeFirstResponder(field)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard source.isKeyWindow, let screen = NSScreen.main else { fputs("SKIP: cannot establish source key window\n", stderr); exit(2) }
                let initialResponder = source.firstResponder
                let delegate = AppDelegate(store: ClipboardStore(pasteboard: board, fileURL: temporary))
                delegate.panel = ClipPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                delegate.panel.contentView = NSHostingView(rootView: ContentView(store: delegate.store, delegate: delegate))
                delegate.show(on: screen, held: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard source.isKeyWindow, source.firstResponder === initialResponder else { fputs("FAIL: hover stole keyboard focus\n", stderr); exit(1) }
                    delegate.show(on: screen, held: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        guard delegate.panel.isKeyWindow else { fputs("FAIL: keyboard invocation did not focus panel\n", stderr); exit(1) }
                        delegate.close()
                        print("PASS: hover preserves source focus; keyboard invocation focuses panel")
                        exit(0)
                    }
                }
            }
        }
        app.run()
    }
}
