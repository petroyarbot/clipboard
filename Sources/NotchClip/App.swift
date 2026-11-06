import AppKit
import SwiftUI
import Carbon

@main struct NotchClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ClipboardStore()
    var panel: NSPanel!
    var status: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var mouseTimer: Timer?
    var wasInTrigger = false
    @AppStorage("hoverEnabled") var hoverEnabled = true
    @AppStorage("shortcut") var shortcut = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = ClipPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 510), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: ContentView(store: store, delegate: self))
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "NotchClip")
        status.button?.target = self
        status.button?.action = #selector(toggle)
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggle() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        registerShortcut()
        store.start()
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHover() }
        }
    }
    func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let keys: [UInt32] = [UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_C), UInt32(kVK_Space)]
        let index = max(0, min(shortcut, keys.count - 1))
        let result = RegisterEventHotKey(keys[index], UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x4E434C50, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { NSLog("NotchClip: shortcut registration failed: %d", result) }
    }
    func checkHover() {
        guard hoverEnabled, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { wasInTrigger = false; return }
        let point = NSEvent.mouseLocation
        let frame = screen.frame
        let inside = abs(point.x - frame.midX) < 100 && point.y >= frame.maxY - 5
        if inside && !wasInTrigger && !panel.isVisible { show(on: screen) }
        wasInTrigger = inside
    }
    @objc func toggle() { if panel.isVisible { panel.orderOut(nil) } else { show(on: NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main) } }
    func show(on screen: NSScreen?) {
        guard let screen else { return }
        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - max(screen.safeAreaInsets.top, 24)))
        panel.makeKeyAndOrderFront(nil)
    }
    func select(_ clip: Clip) { store.select(clip); panel.orderOut(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
