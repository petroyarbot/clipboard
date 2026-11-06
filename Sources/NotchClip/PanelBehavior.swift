import Foundation

/// Timing and pointer behavior, independent of the window system.
struct PanelBehavior {
    enum Action { case none, open, close }
    private var triggerSince: TimeInterval?
    private var outsideSince: TimeInterval?
    private var isOpen = false
    private var held = false

    mutating func pointerEnteredTrigger(at now: TimeInterval, delay: TimeInterval) -> Action {
        triggerSince = now
        return pointerStayedInTrigger(at: now, delay: delay)
    }
    mutating func pointerStayedInTrigger(at now: TimeInterval, delay: TimeInterval) -> Action {
        guard !isOpen, let start = triggerSince, now - start >= max(0, delay) else { return .none }
        triggerSince = nil
        return .open
    }
    mutating func pointerLeftTrigger() { triggerSince = nil }
    mutating func didOpen(held: Bool) { isOpen = true; self.held = held; outsideSince = nil; triggerSince = nil }
    mutating func didClose() { isOpen = false; held = false; outsideSince = nil; triggerSince = nil }
    mutating func pointerMoved(inside: Bool, editing: Bool, at now: TimeInterval, delay: TimeInterval) -> Action {
        guard isOpen else { return .none }
        if inside { held = false; outsideSince = nil; return .none }
        guard !held, !editing else { outsideSince = nil; return .none }
        guard let start = outsideSince else { outsideSince = now; return delay <= 0 ? .close : .none }
        return now - start >= max(0, delay) ? .close : .none
    }
}
