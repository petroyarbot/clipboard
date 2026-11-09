import AppKit
import SwiftUI
import Carbon
import Combine
import ServiceManagement

#if !NOTCHCLIP_TESTING
@main struct NotchClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings {
            SettingsView(delegate: delegate, store: delegate.store, timer: delegate.focusTimer, usage: delegate.usage)
        }
    }
}
#endif

final class ClipPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store: ClipboardStore
    override init() { self.store = ClipboardStore(); super.init() }
    init(store: ClipboardStore) { self.store = store; super.init() }
    @Published var expanded = false
    /// Растёт при каждом открытии панели: содержимое проявляется заново.
    @Published var revealToken = 0
    @Published var editing = false
    @Published var dropTargeted = false
    /// One timer for the whole app, so it keeps running while the panel is closed.
    let focusTimer = FocusTimer()
    let usage = UsageMonitor()
    let agents = AgentMonitor()
    /// The closed-notch Live Activity (timer, agents, phase-end banner).
    var liveActivity: LiveActivityController!
    private var statusCancellables = Set<AnyCancellable>()
    var panel: ClipPanel!
    var status: NSStatusItem!
    var statusMenu: NSMenu!
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var mouseTimer: Timer?
    var wasInTrigger = false
    var behavior = PanelBehavior()
    var isMenuTracking = false
    var hideWork: DispatchWorkItem?
    var openToken = UUID()
    private var settingsCloseObserver: NSObjectProtocol?
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
        let hosting = DropHostingView(rootView: AnyView(ContentView(store: store, delegate: self).ignoresSafeArea()), store: store, delegate: self)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "NotchClip")
        status.button?.target = self; status.button?.action = #selector(toggle)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu = makeStatusMenu()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggle() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        registerShortcut(); store.start()
        usage.start(); agents.start()
        liveActivity = LiveActivityController(timer: focusTimer, agents: agents)
        liveActivity.onOpen = { [weak self] tab in self?.openPanel(on: tab) }
        liveActivity.onVisibilityChanged = { [weak self] in self?.updateHoverPoll() }
        liveActivity.start()
        observeStatusItem()
        setupLoginItem()
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidOpen), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidClose), name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateHoverPoll() }
            .store(in: &statusCancellables)
        updateHoverPoll()
    }

    /// Опрос указателя каждые 25 мс нужен, пока работает наведение на панель, открыта панель или виден островок.
    /// В остальное время таймер остановлен.
    func updateHoverPoll() {
        let needed = hoverEnabled || expanded || liveActivity.isIslandVisible
        if needed {
            guard mouseTimer == nil else { return }
            let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkHover() } }
            RunLoop.main.add(timer, forMode: .common)
            mouseTimer = timer
        } else {
            mouseTimer?.invalidate()
            mouseTimer = nil
            wasInTrigger = false
        }
    }
    /// Правый клик по иконке в строке меню: "Настройки…" и "Выйти".
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Выйти из NotchClip", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }
    /// Закрывает панель и открывает окно настроек. Приложение LSUIElement без строки меню, поэтому
    /// на время окна оно переходит в обычный режим и возвращается в .accessory, когда окно закрыто.
    @objc func openSettings() {
        if panel.isVisible || expanded { close() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        bringSettingsToFront(attempt: 0)
    }

    /// Окно настроек создаёт SwiftUI не сразу: ищем его после такта цикла событий и выводим на передний план.
    private func bringSettingsToFront(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            guard let window = NSApp.windows.first(where: Self.isSettingsWindow) else {
                if attempt < 20 { self.bringSettingsToFront(attempt: attempt + 1) }
                return
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.watchSettingsClose(window)
        }
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains("Settings") == true
            || window.title.contains("Настройки")
            || window.title.contains("Settings")
    }

    /// Когда окно настроек закрывается, приложение снова становится фоновым (.accessory).
    private func watchSettingsClose(_ window: NSWindow) {
        if let settingsCloseObserver { NotificationCenter.default.removeObserver(settingsCloseObserver) }
        settingsCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            NSApp.setActivationPolicy(.accessory)
            if let token = self?.settingsCloseObserver { NotificationCenter.default.removeObserver(token) }
            self?.settingsCloseObserver = nil
        }
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    /// Menu bar text: the running focus timer and the count of tasks waiting for the user.
    func observeStatusItem() {
        Publishers.CombineLatest3(focusTimer.$state, focusTimer.$lastTick, agents.$tasks)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateStatusTitle() }
            .store(in: &statusCancellables)
        updateStatusTitle()
    }
    func updateStatusTitle() {
        guard let button = status?.button else { return }
        var parts: [String] = []
        if focusTimer.state == .running { parts.append(focusTimer.compactText) }
        let needs = agents.needsActionCount
        if needs > 0 { parts.append("●\(needs)") }
        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        button.imagePosition = parts.isEmpty ? .imageOnly : .imageLeading
    }
    func setupLoginItem() {
        if CommandLine.arguments.contains("--enable-login-item") {
            do { try SMAppService.mainApp.register() }
            catch { NSLog("NotchClip login item error: %@", error.localizedDescription) }
        }
        let text: String
        switch SMAppService.mainApp.status {
        case .enabled: text = "enabled"
        case .notRegistered: text = "notRegistered"
        case .requiresApproval: text = "requiresApproval"
        case .notFound: text = "notFound"
        @unknown default: text = "unknown"
        }
        NSLog("NotchClip login item status: %@", text)
    }
    func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let keys: [UInt32] = [UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_C), UInt32(kVK_Space)]
        let result = RegisterEventHotKey(keys[max(0, min(shortcut, keys.count - 1))], UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x4E434C50, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { store.errorMessage = "Не удалось включить горячую клавишу. Попробуй другую в настройках." }
    }
    @objc func menuDidOpen(_ note: Notification) { isMenuTracking = true }
    @objc func menuDidClose(_ note: Notification) { isMenuTracking = false }
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
        // Over the Live Activity the mini player takes the hover; the full panel waits for a click.
        liveActivity.pointerMoved(to: point, now: now, hoverEnabled: hoverEnabled, openDelay: hoverOpenDelay, closeDelay: hoverCloseDelay)
        let islandOwnsPointer = liveActivity.owns(point)
        if hoverEnabled && insideTrigger && !islandOwnsPointer {
            let action = wasInTrigger
                ? behavior.pointerStayedInTrigger(at: now, delay: hoverOpenDelay)
                : behavior.pointerEnteredTrigger(at: now, delay: hoverOpenDelay)
            if action == .open { show(on: screen, held: false) }
        } else { behavior.pointerLeftTrigger() }
        wasInTrigger = insideTrigger
        if expanded && behavior.pointerMoved(inside: insideTrigger || panel.frame.contains(point), editing: editing || isMenuTracking, at: now, delay: hoverCloseDelay) == .close {
            close()
        }
    }

    @objc func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            guard let button = status.button else { return }
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            return
        }
        if expanded { close() }
        else { show(on: NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main, held: true) }
    }
    func show(on screen: NSScreen?, held: Bool) {
        guard let screen else { return }
        hideWork?.cancel()
        revealToken &+= 1
        liveActivity.setPanelOpen(true)
        behavior.didOpen(held: held)
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            collapsedWidth = max(100, screen.frame.width - left.width - right.width)
            collapsedHeight = max(20, screen.safeAreaInsets.top)
        } else { collapsedWidth = 190; collapsedHeight = 24 }
        placePanel(on: screen)
        expanded = false
        panel.contentView?.layoutSubtreeIfNeeded()
        if held { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
        let token = UUID(); openToken = token
        // Give AppKit one frame to present the collapsed shape before expanding it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self, self.openToken == token else { return }
            withAnimation(self.panelOpenAnimation) { self.expanded = true }
            self.updateHoverPoll()
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
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var panelOpenAnimation: Animation? { IslandAnimation.panelOpen(duration: animationDuration, bounce: animationBounce, reduceMotion: reduceMotion) }
    var panelCloseAnimation: Animation? { IslandAnimation.panelClose(duration: animationDuration, reduceMotion: reduceMotion) }
    func close() {
        openToken = UUID(); behavior.didClose(); editing = false
        withAnimation(panelCloseAnimation) { expanded = false }
        updateHoverPoll()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.liveActivity.setPanelOpen(false)
        }
        hideWork?.cancel(); hideWork = work
        let delay = reduceMotion ? 0 : animationDuration + 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// Opens the full panel on a given tab (island taps).
    func openPanel(on tab: PanelTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: PanelTab.storageKey)
        show(on: NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main, held: true)
    }
    func select(_ clip: Clip) { if store.select(clip) { close() } }
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        usage.stop(); agents.stop()
    }
}
