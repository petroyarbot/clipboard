import AppKit
import SwiftUI

/// Регрессия: открытая панель не должна оставаться чёрной (содержимое всегда видно в покое).
@main struct PanelRender {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchclip-render-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let savedTab = defaults.string(forKey: PanelTab.storageKey)
        defer { if let savedTab { defaults.set(savedTab, forKey: PanelTab.storageKey) } else { defaults.removeObject(forKey: PanelTab.storageKey) } }

        func litShare(_ view: NSView) -> Double {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
            view.cacheDisplay(in: view.bounds, to: rep)
            var lit = 0, total = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    total += 1
                    if c.alphaComponent > 0.5, max(c.redComponent, c.greenComponent, c.blueComponent) > 0.2 { lit += 1 }
                }
            }
            return total == 0 ? 0 : Double(lit) / Double(total)
        }
        func spin(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }

        var failed = false
        for tab in [PanelTab.focus, .clipboard] {
            defaults.set(tab.rawValue, forKey: PanelTab.storageKey)
            let store = ClipboardStore(pasteboard: NSPasteboard(name: .init("notchclip-render-\(UUID())")), fileURL: root.appendingPathComponent("h-\(tab.rawValue).json"), downloadsDirectory: root.appendingPathComponent("D", isDirectory: true))
            let delegate = AppDelegate(store: store)
            delegate.collapsedWidth = 190; delegate.collapsedHeight = 24
            let size = NSSize(width: 620, height: 500)
            let hosting = NSHostingView(rootView: AnyView(ContentView(store: store, delegate: delegate).ignoresSafeArea()))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            // Открытие как в приложении: сначала свёрнуто, затем expanded = true в анимации на следующем проходе цикла.
            delegate.expanded = false
            window.orderFrontRegardless()
            spin(0.1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { delegate.expanded = true }
            }
            // Сразу после установки expanded (без прокрутки цикла для анимации) содержимое уже должно быть в покое видимо.
            spin(0.02)
            hosting.layoutSubtreeIfNeeded()
            let early = litShare(hosting)
            spin(1.0)
            hosting.layoutSubtreeIfNeeded()
            let settled = litShare(hosting)
            print("\(tab.rawValue): early lit \(early), settled lit \(settled)")
            if settled < 0.01 { print("FAIL \(tab.rawValue): panel black after 1 s"); failed = true }
            // Без анимации вообще: expanded = true в транзакции без анимации.
            delegate.expanded = false
            spin(0.3)
            var instant = Transaction(); instant.disablesAnimations = true
            withTransaction(instant) { delegate.expanded = true }
            hosting.layoutSubtreeIfNeeded()
            let immediate = litShare(hosting)
            print("\(tab.rawValue): immediate lit \(immediate)")
            if immediate < 0.01 { print("FAIL \(tab.rawValue): panel black immediately"); failed = true }
            window.orderOut(nil)
        }
        if failed { exit(1) }
        print("Panel render tests passed")
    }
}
