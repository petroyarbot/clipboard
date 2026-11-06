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
    var behavior = PanelBehavior()
    var hideWork: DispatchWorkItem?
    var openToken = UUID()
    @Published var collapsedWidth: CGFloat = 190
    @Published var collapsedHeight: CGFloat = 28
    @AppStorage("hoverEnabled") var hoverEnabled = true
    @AppStorage("shortcut") var shortcut = 0
    @AppStorage("panelWidth") var panelWidth = 620.0
    @AppStorage("panelHeight") var panelHeight = 500.0
    @AppStorage("animationDuration") var animationDuration = 0.30
    @AppStorage("animationBounce") var animationBounce = 0.12
    @AppStorage("hoverOpenDelay") var hoverOpenDelay = 0.0
    @AppStorage("hoverCloseDelay") var hoverCloseDelay = 0.30
    var size: NSSize { NSSize(width: panelWidth, height: panelHeight) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = ClipPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .init(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.onEscape = { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: ContentView(store: store, delegate: self).ignoresSafeArea())
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
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
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkHover() } }
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
        let now = ProcessInfo.processInfo.systemUptime
        if hoverEnabled && insideTrigger {
            let action = wasInTrigger
                ? behavior.pointerStayedInTrigger(at: now, delay: hoverOpenDelay)
                : behavior.pointerEnteredTrigger(at: now, delay: hoverOpenDelay)
            if action == .open { show(on: screen, held: false) }
        } else { behavior.pointerLeftTrigger() }
        wasInTrigger = insideTrigger
        if expanded && behavior.pointerMoved(inside: insideTrigger || panel.frame.contains(point), editing: editing, at: now, delay: hoverCloseDelay) == .close {
            close()
        }
    }

    @objc func toggle() {
        if expanded { close() }
        else { show(on: NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main, held: true) }
    }
    func show(on screen: NSScreen?, held: Bool) {
        guard let screen else { return }
        hideWork?.cancel()
        behavior.didOpen(held: held)
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            collapsedWidth = max(100, screen.frame.width - left.width - right.width)
            collapsedHeight = max(20, screen.safeAreaInsets.top)
        } else { collapsedWidth = 190; collapsedHeight = 24 }
        placePanel(on: screen)
        expanded = false
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        let token = UUID(); openToken = token
        // Give AppKit one frame to present the collapsed shape before expanding it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self, self.openToken == token else { return }
            withAnimation(self.animation) { self.expanded = true }
        }
    }
    func placePanel(on screen: NSScreen) {
        let width = min(size.width, screen.frame.width)
        let height = min(size.height, screen.frame.height)
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
    }
    func updatePanelSize() {
        if let screen = panel.screen ?? NSScreen.main { placePanel(on: screen) }
    }
    var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: animationDuration, dampingFraction: 1 - animationBounce)
    }
    func close() {
        openToken = UUID(); behavior.didClose(); editing = false
        withAnimation(animation) { expanded = false }
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork?.cancel(); hideWork = work
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : animationDuration + 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func select(_ clip: Clip) { store.select(clip); close() }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
