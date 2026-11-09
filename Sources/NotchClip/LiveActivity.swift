import AppKit
import Combine
import SwiftUI

/// Агент, ждущий ответа пользователя (для компактного островка).
struct IslandAgentSummary: Equatable {
    let source: String
    let project: String
    let count: Int
}

/// Геометрия экрана: физическая чёлка или плавающая таблетка, если чёлки нет.
struct IslandMetrics: Equatable {
    let frame: CGRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool

    /// Без чёлки островок висит чуть ниже верхнего края.
    var topOffset: CGFloat { hasNotch ? 0 : 6 }

    /// Островок всегда на экране с чёлкой; без него — на экране со строкой меню (первый в списке).
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: hasNotch) ?? NSScreen.screens.first
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    init(screen: NSScreen) {
        frame = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(100, screen.frame.width - left.width - right.width)
            notchHeight = max(IslandState.minimumNotchHeight, screen.safeAreaInsets.top)
            hasNotch = true
        } else {
            notchWidth = 200
            notchHeight = IslandState.minimumNotchHeight
            hasNotch = false
        }
    }
}

/// Состояние, которое читает SwiftUI. Меняется только из `LiveActivityController`.
@MainActor
final class IslandModel: ObservableObject {
    @Published var presentation: IslandPresentation = .idle
    @Published var layout = IslandLayout(width: 190, height: 0, bottomRadius: 0, contentTop: 0)
    @Published var notchWidth: CGFloat = 190
    @Published var notchHeight: CGFloat = IslandState.minimumNotchHeight
    @Published var topOffset: CGFloat = 0
    @Published var agent: IslandAgentSummary?
    @Published var banner: IslandBanner?
    @Published var released = 0

    func adoptGeometry(_ metrics: IslandMetrics) {
        if notchWidth != metrics.notchWidth { notchWidth = metrics.notchWidth }
        if notchHeight != metrics.notchHeight { notchHeight = metrics.notchHeight }
        if topOffset != metrics.topOffset { topOffset = metrics.topOffset }
    }
}

/// Окно островка: не активирует приложение и не становится ключевым, поэтому не забирает фокус ввода.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Связывает таймер, агентов и настройки с окном островка. Вся логика выбора видна через `IslandState`.
@MainActor
final class LiveActivityController {
    /// Открывает полную панель на вкладке.
    var onOpen: ((PanelTab) -> Void)?
    /// Островок появился или скрылся (App по нему решает, нужен ли 25-мс опрос указателя).
    var onVisibilityChanged: (() -> Void)?

    let model = IslandModel()
    private let timer: FocusTimer
    private let agents: AgentMonitor
    private let defaults: UserDefaults
    private var state = IslandState()
    private var panel: IslandPanel?
    private var cancellables = Set<AnyCancellable>()
    private var pointer = PanelBehavior()
    private var panelOpen = false
    private var hovering = false
    private var wasInside = false
    private var wasQuiet = false
    private var handledPhaseEnd: UUID?
    private var doneIDs: Set<String>?
    private var openToken = UUID()
    private var hideWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var expiryWork: DispatchWorkItem?
    /// Экран, выбранный в момент появления островка, и его геометрия (кэш: опрос указателя идёт каждые 25 мс).
    private var pinnedScreen: NSScreen?
    private var metrics: IslandMetrics?

    /// Островок сейчас на экране.
    var isIslandVisible: Bool { panel?.isVisible == true && !panelOpen }

    init(timer: FocusTimer, agents: AgentMonitor, defaults: UserDefaults = .standard) {
        self.timer = timer
        self.agents = agents
        self.defaults = defaults
    }

    func start() {
        Publishers.Merge3(
            timer.$state.map { _ in () },
            timer.$lastTick.map { _ in () },
            timer.$lastPhaseEnd.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.timerChanged() }
        .store(in: &cancellables)

        agents.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] tasks in self?.agentsChanged(tasks) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.screensChanged() }
            .store(in: &cancellables)

        pinScreen()
    }

    /// Полная панель открыта: островок прячется, потому что панель закрывает то же место.
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        if open {
            hideWork?.cancel(); shrinkWork?.cancel(); expiryWork?.cancel()
            hovering = false
            pointer.didClose()
            panel?.orderOut(nil)
            onVisibilityChanged?()
        } else {
            sync()
        }
    }

    /// Указатель внутри островка с таймером: мини-плеер открывается после задержки наведения.
    func pointerMoved(to point: NSPoint, now: TimeInterval, hoverEnabled: Bool, openDelay: Double, closeDelay: Double) {
        let expandable = canExpand
        let inside = expandable && islandRect().contains(point)
        if !hovering {
            if inside && hoverEnabled {
                let action = wasInside
                    ? pointer.pointerStayedInTrigger(at: now, delay: openDelay)
                    : pointer.pointerEnteredTrigger(at: now, delay: openDelay)
                if action == .open {
                    hovering = true
                    pointer.didOpen(held: false)
                    sync()
                }
            } else {
                pointer.pointerLeftTrigger()
            }
        } else if !expandable {
            hovering = false
            pointer.didClose()
            sync()
        } else if pointer.pointerMoved(inside: inside, editing: false, at: now, delay: closeDelay) == .close {
            hovering = false
            pointer.didClose()
            sync()
        }
        wasInside = inside
    }

    /// Островок показывает указатель, поэтому главный триггер панели не должен открывать панель.
    func owns(_ point: NSPoint) -> Bool {
        guard panel?.isVisible == true, !panelOpen else { return false }
        switch model.presentation {
        case .compactTimer, .compactBoth, .miniPlayer, .banner:
            return islandRect().contains(point)
        case .idle, .compactAgent:
            return false
        }
    }

    // MARK: - Входящие события

    private var isQuiet: Bool { IslandState.isQuiet(timer: timer.state, phase: timer.phase) }

    private var canExpand: Bool {
        guard !panelOpen, panel?.isVisible == true else { return false }
        switch model.presentation {
        case .compactTimer, .compactBoth, .miniPlayer: return true
        case .idle, .compactAgent, .banner: return false
        }
    }

    private func timerChanged() {
        if let end = timer.lastPhaseEnd, end.id != handledPhaseEnd {
            handledPhaseEnd = end.id
            state.phaseEnded(
                finished: end.finished,
                next: end.next,
                nextMinutes: end.nextMinutes,
                completedToday: end.completedToday,
                at: Date().timeIntervalSince1970
            )
        }
        let quiet = isQuiet
        if quiet != wasQuiet {
            if quiet { state.quietStarted() } else { state.quietEnded() }
            wasQuiet = quiet
        }
        sync()
    }

    private func agentsChanged(_ tasks: [AgentTask]) {
        let waiting = tasks.filter { $0.state == .needsAction }
        let summary = waiting.first.map {
            IslandAgentSummary(source: $0.source, project: $0.project.isEmpty ? "без проекта" : $0.project, count: waiting.count)
        }
        if model.agent != summary { model.agent = summary }

        let done = Set(tasks.filter { $0.state == .done }.map(\.id))
        if let previous = doneIDs {
            state.agentsFinished(done.subtracting(previous).count, quiet: isQuiet)
        }
        doneIDs = done
        sync()
    }

    private func tapped() {
        let tab: PanelTab = (model.presentation == .compactAgent || model.presentation == .compactBoth) ? .agents : .focus
        onOpen?(tab)
    }

    private func startNext() {
        state.dismissBanner()
        model.banner = nil
        timer.start()
        sync()
    }

    // MARK: - Пересчёт и показ

    private func sync() {
        let now = Date().timeIntervalSince1970
        let inputs = IslandInputs(
            timer: timer.state,
            phase: timer.phase,
            needsActionCount: model.agent?.count ?? 0,
            hovering: hovering,
            focusEnabled: IslandSettings.isEnabled(IslandSettings.focusKey, defaults: defaults),
            agentsEnabled: IslandSettings.isEnabled(IslandSettings.agentsKey, defaults: defaults)
        )
        let next = state.presentation(inputs, now: now)
        if model.banner != state.banner { model.banner = state.banner }
        if model.released != state.releasedAgentDone { model.released = state.releasedAgentDone }
        scheduleExpiry(now: now)
        apply(next)
    }

    private func apply(_ next: IslandPresentation) {
        // Островок появляется на экране, выбранном сейчас; до этого момента экран не меняется.
        if panel?.isVisible != true && next != .idle { pinScreen() }
        guard let metrics else { return }
        model.adoptGeometry(metrics)
        if panelOpen { panel?.orderOut(nil); return }

        if next == .idle {
            guard model.presentation != .idle else { return }
            hideWork?.cancel()
            // Уходящая форма не должна перехватывать клики по строке меню.
            panel?.ignoresMouseEvents = true
            withAnimation(reduceMotion ? nil : IslandAnimation.closeSpring) {
                model.presentation = .idle
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.presentation == .idle else { return }
                self.panel?.orderOut(nil)
                self.onVisibilityChanged?()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.05 : 0.5), execute: work)
            return
        }

        guard let layout = IslandState.layout(for: next, notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight) else { return }
        hideWork?.cancel()
        let window = ensurePanel()

        if !window.isVisible || model.presentation == .idle {
            // Показ: сначала форма размером с вырез, на следующем кадре она вырастает до цели.
            model.presentation = .idle
            model.layout = IslandLayout(width: metrics.notchWidth, height: 0, bottomRadius: 0, contentTop: 0)
            window.ignoresMouseEvents = false
            window.setFrame(windowFrame(width: layout.width, height: layout.height, metrics: metrics), display: false)
            window.orderFrontRegardless()
            onVisibilityChanged?()
            let token = UUID()
            openToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self, self.openToken == token, !self.panelOpen else { return }
                withAnimation(self.morphAnimation(from: .idle, to: next, grows: true)) {
                    self.model.presentation = next
                    self.model.layout = layout
                }
                self.scheduleShrink(to: layout)
            }
            return
        }

        if model.presentation == next && model.layout == layout {
            // Форма та же, но экран мог смениться: переносим окно, размер не трогаем (он может ждать сжатия).
            placeWindow(window, metrics: metrics)
            return
        }
        let grows = layout.width * layout.height > model.layout.width * model.layout.height
        let animation = morphAnimation(from: model.presentation, to: next, grows: grows)
        growWindow(for: layout, next: next, metrics: metrics, window: window)
        withAnimation(animation) {
            model.presentation = next
            model.layout = layout
        }
        scheduleShrink(to: layout)
    }

    private func morphAnimation(from: IslandPresentation, to: IslandPresentation, grows: Bool) -> Animation? {
        if reduceMotion { return nil }
        if to == .idle { return IslandAnimation.closeSpring }
        if from == .idle || grows { return IslandAnimation.openSpring }
        if from == .miniPlayer || to == .miniPlayer { return IslandAnimation.interactive }
        return IslandAnimation.closeSpring
    }

    /// Окно не должно быть меньше формы, иначе она обрежется; лишнее место сжимаем после анимации.
    /// Пока окно больше компактной формы, оно пропускает клики: меню-бар рядом с вырезом остаётся доступным.
    private func growWindow(for layout: IslandLayout, next: IslandPresentation, metrics: IslandMetrics, window: IslandPanel) {
        let current = window.frame
        let height = max(current.height - metrics.topOffset, layout.height)
        let width = max(current.width, layout.width)
        window.setFrame(windowFrame(width: width, height: height, metrics: metrics), display: false)
        let oversized = width > layout.width || height > layout.height
        window.ignoresMouseEvents = oversized && Self.isCompact(next)
    }

    private static func isCompact(_ presentation: IslandPresentation) -> Bool {
        switch presentation {
        case .compactTimer, .compactAgent, .compactBoth: return true
        case .idle, .miniPlayer, .banner: return false
        }
    }

    private func scheduleShrink(to layout: IslandLayout) {
        shrinkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.layout == layout, self.model.presentation != .idle,
                  let window = self.panel, let metrics = self.metrics else { return }
            window.setFrame(self.windowFrame(width: layout.width, height: layout.height, metrics: metrics), display: true)
            window.ignoresMouseEvents = false
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func scheduleExpiry(now: TimeInterval) {
        expiryWork?.cancel()
        expiryWork = nil
        guard let expiry = state.bannerExpiry, expiry > now else { return }
        let work = DispatchWorkItem { [weak self] in self?.sync() }
        expiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (expiry - now) + 0.01, execute: work)
    }

    private func pinScreen() {
        pinnedScreen = IslandMetrics.targetScreen()
        refreshMetrics()
    }

    private func refreshMetrics() {
        metrics = pinnedScreen.map { IslandMetrics(screen: $0) }
    }

    /// Конфигурация экранов сменилась: берём актуальный объект экрана (старый мог устареть) и пересчитываем форму.
    private func screensChanged() {
        if panel?.isVisible == true, let id = pinnedScreen.flatMap(Self.displayID),
           let fresh = NSScreen.screens.first(where: { Self.displayID($0) == id }) {
            pinnedScreen = fresh
            refreshMetrics()
        } else {
            pinScreen()
        }
        if let metrics { model.adoptGeometry(metrics) }
        sync()
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Переносит окно на текущий экран, сохраняя размер. Верх окна всегда совпадает с верхним краем экрана.
    private func placeWindow(_ window: IslandPanel, metrics: IslandMetrics) {
        let size = window.frame.size
        let origin = NSPoint(x: metrics.frame.midX - size.width / 2, y: metrics.frame.maxY - size.height)
        if window.frame.origin != origin { window.setFrame(NSRect(origin: origin, size: size), display: true) }
    }

    private func ensurePanel() -> IslandPanel {
        if let panel { return panel }
        let window = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        let root = LiveIslandView(
            model: model,
            timer: timer,
            onTap: { [weak self] in self?.tapped() },
            onStartNext: { [weak self] in self?.startNext() }
        )
        let hosting = NSHostingView(rootView: root.ignoresSafeArea())
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        panel = window
        return window
    }

    private func windowFrame(width: CGFloat, height: CGFloat, metrics: IslandMetrics) -> NSRect {
        NSRect(
            x: metrics.frame.midX - width / 2,
            y: metrics.frame.maxY - height - metrics.topOffset,
            width: width,
            height: height + metrics.topOffset
        )
    }

    /// Прямоугольник формы на экране, по текущей (уже выбранной) геометрии.
    private func islandRect() -> NSRect {
        guard let metrics else { return .zero }
        let layout = model.layout
        return NSRect(
            x: metrics.frame.midX - layout.width / 2,
            y: metrics.frame.maxY - metrics.topOffset - layout.height,
            width: layout.width,
            height: layout.height
        )
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
