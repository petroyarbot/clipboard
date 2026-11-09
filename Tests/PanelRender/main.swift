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

        final class FrameBox: ObservableObject {
            @Published var frames: [FocusLayoutElement: CGRect] = [:]
        }
        let renderDir = URL(fileURLWithPath: "/tmp/claude-501/nc-render", isDirectory: true)
        try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)
        let fixtureDir = root.appendingPathComponent("activity", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        let dayKey = ISO8601DateFormatter()
        dayKey.formatOptions = [.withFullDate]
        let record = ActivityDayRecord(day: dayKey.string(from: Date()), seconds: ["com.anthropic.Claude": 2400, "com.example.NotchClip": 1200, "com.deepseek.desktop": 600], names: ["com.anthropic.Claude": "Claude", "com.example.NotchClip": "NotchClip", "com.deepseek.desktop": "DeepSeek"], focusSeconds: 1260, sessions: 1)
        let dateKey = dayKey.string(from: Date())
        let recordURL = fixtureDir.appendingPathComponent("activity-\(dateKey).json")
        try JSONEncoder().encode(record).write(to: recordURL)
        let tracker = ActivityTracker(dataDir: fixtureDir)
        let timerDefaults = UserDefaults(suiteName: "notchclip-panel-render-\(UUID())")!
        timerDefaults.set(25 * 60, forKey: "focusTimer.focusSeconds")
        let recentKey = "focusTimer.recentSeconds"
        let savedRecents = UserDefaults.standard.string(forKey: recentKey)
        UserDefaults.standard.set("300,600", forKey: recentKey)
        defer { if let savedRecents { UserDefaults.standard.set(savedRecents, forKey: recentKey) } else { UserDefaults.standard.removeObject(forKey: recentKey) } }
        let timer = FocusTimer(defaults: timerDefaults, playSound: {}, notify: { _ in })

        func capture(_ name: String, running: Bool) throws {
            let frames = FrameBox()
            let view = ZStack {
                Color.black
                ScrollView(showsIndicators: false) {
                    FocusView(timer: timer, tracker: tracker).padding(.horizontal, 22)
                }
            }
                .frame(width: 620, height: 500, alignment: .top)
                .onPreferenceChange(FocusLayoutFramesKey.self) { frames.frames = $0 }
            let hosting = NSHostingView(rootView: AnyView(view))
            hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 500)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = true
            window.backgroundColor = .black
            window.contentView = hosting
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            spin(0.15)
            hosting.layoutSubtreeIfNeeded()
            if !running, let wheel = frames.frames[.wheel], let stats = frames.frames[.stats] {
                if wheel.intersects(stats) { throw NSError(domain: "PanelRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Focus wheel and stats overlap: \(wheel), \(stats)"]) }
            } else if !running {
                throw NSError(domain: "PanelRender", code: 2, userInfo: [NSLocalizedDescriptionKey: "Focus wheel/stats frames missing: \(frames.frames)"])
            }
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw NSError(domain: "PanelRender", code: 3) }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "PanelRender", code: 4) }
            try png.write(to: renderDir.appendingPathComponent(name))
            window.orderOut(nil)
        }
        try capture("focus-idle.png", running: false)
        timer.start()
        try capture("focus-running.png", running: true)
        timer.reset()

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
