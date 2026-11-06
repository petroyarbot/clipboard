import AppKit
import SwiftUI
import Carbon

@main struct NotchClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

final class ClipPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = ClipboardStore()
    @Published var expanded = false
    @Published var editing = false
    var panel: ClipPanel!
    var status: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var mouseTimer: Timer?
    var wasInTrigger = false
    var heldOpen = false
    var closeWork: DispatchWorkItem?
    var hideWork: DispatchWorkItem?
    @AppStorage("hoverEnabled") var hoverEnabled = true
    @AppStorage("shortcut") var shortcut = 0
    let size = NSSize(width: 620, height: 500)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = ClipPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .init(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.onEscape = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: ContentView(store: store, delegate: self))
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "NotchClip")
        status.button?.target = self; status.button?.action = #selector(toggle)
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggle() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        registerShortcut(); store.start()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkHover() } }
        RunLoop.main.add(timer, forMode: .common); mouseTimer = timer
    }
    func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let keys: [UInt32] = [UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_C), UInt32(kVK_Space)]
        let result = RegisterEventHotKey(keys[max(0, min(shortcut, keys.count - 1))], UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x4E434C50, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { store.errorMessage = "Не удалось включить горячую клавишу. Попробуй другую в настройках." }
    }
    func checkHover() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let frame = screen.frame
        let notchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(180, frame.width - left.width - right.width)
        } else { notchWidth = 200 }
        let insideTrigger = abs(point.x - frame.midX) < notchWidth / 2 && point.y >= frame.maxY - max(screen.safeAreaInsets.top, 8)
        if hoverEnabled && insideTrigger && !wasInTrigger && !expanded { show(on: screen, held: false) }
        wasInTrigger = insideTrigger
        guard expanded, !heldOpen, !editing else { closeWork?.cancel(); closeWork = nil; return }
        if insideTrigger || panel.frame.contains(point) { closeWork?.cancel(); closeWork = nil }
        else if closeWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.close() }
            closeWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }
    @objc func toggle() {
        if expanded { close() }
        else { show(on: NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main, held: true) }
    }
    func show(on screen: NSScreen?, held: Bool) {
        guard let screen else { return }
        closeWork?.cancel(); closeWork = nil; hideWork?.cancel()
        heldOpen = held
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height))
        panel.makeKeyAndOrderFront(nil)
        withAnimation(animation) { expanded = true }
    }
    var animation: Animation? { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86) }
    func close() {
        closeWork?.cancel(); closeWork = nil; heldOpen = false; editing = false
        withAnimation(animation) { expanded = false }
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork?.cancel(); hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.4), execute: work)
    }
    func select(_ clip: Clip) { store.select(clip); close() }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
