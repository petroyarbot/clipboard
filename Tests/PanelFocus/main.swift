import AppKit
import SwiftUI
import Foundation

// Checks that hovering the notch keeps the source window's keyboard focus, and that a keyboard
// invocation focuses the panel. Built and run by scripts/test-focus.sh, which needs a GUI session.
@main struct PanelFocusCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        let runID = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("notchclip-focus-\(runID)")
        let board = NSPasteboard(name: .init("notchclip-focus-\(runID)"))
        let suiteName = "notchclip-focus-\(runID)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        app.setActivationPolicy(.regular)

        func fail(_ message: String) -> Never {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }

        // Watchdog: a stuck GUI step must not hang the whole test run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fail("focus check timed out") }

        /// Polls every 50 ms until `condition` holds, re-activating this app first when `activate` is set.
        /// Fails with `what` after `timeout` seconds instead of guessing a fixed delay.
        func waitUntil(_ what: String, timeout: TimeInterval = 10, activate: Bool = true,
                       _ condition: @escaping () -> Bool, then next: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(timeout)
            func poll() {
                if activate { app.activate(ignoringOtherApps: true) }
                if condition() { next(); return }
                if Date() >= deadline { fail(what) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
            poll()
        }

        let source = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        source.title = "NotchClip — тест фокуса"
        let field = NSTextField(string: "Тестовый текст")
        field.frame = NSRect(x: 20, y: 70, width: 240, height: 24)
        source.contentView?.addSubview(field)
        source.makeKeyAndOrderFront(nil)
        source.makeFirstResponder(field)

        waitUntil("cannot make the source window key", { source.isKeyWindow }) {
            guard let screen = NSScreen.main else { fail("no main screen") }
            let initialResponder = source.firstResponder
            let delegate = AppDelegate(store: ClipboardStore(pasteboard: board, fileURL: temporary))
            // show() reads the Live Activity, which applicationDidFinishLaunching normally creates. Use an isolated
            // defaults suite so the test does not touch the user's settings.
            delegate.liveActivity = LiveActivityController(timer: delegate.focusTimer, agents: delegate.agents, defaults: defaults)
            delegate.panel = ClipPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            delegate.panel.contentView = NSHostingView(rootView: ContentView(store: delegate.store, delegate: delegate))
            delegate.show(on: screen, held: false)

            // Hover must not activate the app or move keyboard focus, so do not re-activate while polling.
            waitUntil("panel did not appear on hover", activate: false, { delegate.panel.isVisible }) {
                // The focus change, if any, happens asynchronously after the panel is ordered in. Give it a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard source.isKeyWindow, source.firstResponder === initialResponder else { fail("hover stole keyboard focus") }
                    delegate.show(on: screen, held: true)
                    waitUntil("keyboard invocation did not focus panel", { delegate.panel.isKeyWindow }) {
                        delegate.close()
                        source.orderOut(nil)
                        defaults.removePersistentDomain(forName: suiteName)
                        try? FileManager.default.removeItem(at: temporary)
                        board.releaseGlobally()
                        print("PASS: hover preserves source focus; keyboard invocation focuses panel")
                        exit(0)
                    }
                }
            }
        }
        app.run()
    }
}
