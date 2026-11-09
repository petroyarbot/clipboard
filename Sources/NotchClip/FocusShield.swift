import AppKit
import ApplicationServices
import Foundation

/// Ключи настроек защиты фокуса. Активна только во время фазы фокуса.
enum FocusShieldSettings {
    /// Включить Не беспокоить через быстрые команды (Bool, по умолчанию true).
    static let dndKey = "focusShieldDND"
    /// Имя быстрой команды "включить фокус" (String).
    static let shortcutOnKey = "focusShieldShortcutOn"
    /// Имя быстрой команды "выключить фокус" (String).
    static let shortcutOffKey = "focusShieldShortcutOff"
    /// Bundle id приложений, которые скрываются во время фокуса ([String], по умолчанию []).
    static let appsKey = "focusShieldApps"
    /// Домены сайтов, которые закрываются во время фокуса ([String], по умолчанию []).
    static let sitesKey = "focusShieldSites"
    /// Сводка бейджей Dock за перерыв (Bool, по умолчанию true).
    static let summaryKey = "focusShieldSummary"

    static let defaultShortcutOn = "NotchClip Фокус вкл"
    static let defaultShortcutOff = "NotchClip Фокус выкл"

    static func dndEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: dndKey) as? Bool ?? true
    }

    static func summaryEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: summaryKey) as? Bool ?? true
    }

    static func shortcutOn(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: shortcutOnKey) ?? defaultShortcutOn
    }

    static func shortcutOff(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: shortcutOffKey) ?? defaultShortcutOff
    }

    static func apps(_ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: appsKey) ?? []
    }

    static func sites(_ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: sitesKey) ?? []
    }
}

/// Изменение бейджа приложения в Dock за время фокуса.
struct BadgeDelta: Equatable {
    let name: String
    let delta: Int
}

/// Чистые правила защиты фокуса: без AppKit-состояния и без побочных эффектов.
enum FocusShieldRules {
    /// Приводит домен или URL-фрагмент к виду "youtube.com": без схемы, пути, порта и "www.".
    static func normalizeDomain(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        if let cut = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        if let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        while text.hasSuffix(".") { text.removeLast() }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text.isEmpty ? nil : text
    }

    /// Хост страницы ("m.youtube.com"), нормализованный. Для about:blank и мусора — nil.
    static func host(from urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host else { return nil }
        return normalizeDomain(host)
    }

    /// Совпадение хоста с доменом: сам домен или любой его поддомен. "notyoutube.com" не совпадает с "youtube.com".
    static func matches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// Первый домен из блоклиста, которому принадлежит URL (нормализованный), или nil.
    static func blockedDomain(for urlString: String, in domains: [String]) -> String? {
        guard let host = host(from: urlString) else { return nil }
        for raw in domains {
            guard let domain = normalizeDomain(raw) else { continue }
            if matches(host: host, domain: domain) { return domain }
        }
        return nil
    }

    /// Блокировать приложение только во время фокуса и только если его bundle id в списке.
    static func isAppBlocked(bundleID: String?, blocklist: [String], focusActive: Bool) -> Bool {
        guard focusActive, let bundleID, !bundleID.isEmpty else { return false }
        let id = bundleID.lowercased()
        return blocklist.contains { $0.lowercased() == id }
    }

    /// Числовое значение бейджа Dock. Пусто, "•" и нечисловой текст считаются нулём.
    static func badgeValue(_ label: String?) -> Int {
        guard let label else { return 0 }
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text), value > 0 else { return 0 }
        return value
    }

    /// Приросты бейджей между снимками. Только положительные, по убыванию, затем по имени.
    static func badgeDeltas(start: [String: String], end: [String: String]) -> [BadgeDelta] {
        let names = Set(start.keys).union(end.keys)
        return names
            .map { name in
                BadgeDelta(name: name,
                           delta: badgeValue(end[name]) - badgeValue(start[name]))
            }
            .filter { $0.delta > 0 }
            .sorted { $0.delta != $1.delta ? $0.delta > $1.delta : $0.name < $1.name }
    }

    /// "Telegram +12 · Mail +3" или nil, если приростов нет.
    static func summaryText(_ deltas: [BadgeDelta]) -> String? {
        guard !deltas.isEmpty else { return nil }
        return deltas.map { "\($0.name) +\($0.delta)" }.joined(separator: " · ")
    }

    /// Время "14:25" в локальной зоне.
    static func timeText(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// "Telegram на паузе до 14:25" / "youtube.com на паузе до 14:25".
    static func pauseToast(name: String, until: Date) -> String {
        "\(name) на паузе до \(timeText(until))"
    }

    /// Какие из нужных быстрых команд нет в выводе `shortcuts list` (одно имя на строку).
    static func missingShortcuts(listOutput: String, required: [String]) -> [String] {
        let installed = Set(listOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) })
        return required.filter { !installed.contains($0) }
    }

    /// Текст статуса для пользователя или nil, если всё на месте.
    static func shortcutStatus(missing: [String]) -> String? {
        guard !missing.isEmpty else { return nil }
        return "Создай быстрые команды «\(missing.joined(separator: "» и «"))» в приложении «Команды»"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// Чтение бейджей Dock через Accessibility. Нужен доступ "Универсальный доступ".
enum DockBadges {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос доступа. Вызывать только когда пользователь включил сводку.
    @discardableResult
    static func requestAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Название приложения -> текст бейджа ("12", "•"). Пусто без доступа.
    static func snapshot() -> [String: String] {
        guard isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        // A stuck Dock must not freeze the main thread for the default 6 s.
        AXUIElementSetMessagingTimeout(root, 0.5)
        var result: [String: String] = [:]
        for list in children(of: root) where text(list, kAXRoleAttribute as String) == "AXList" {
            for item in children(of: list) {
                guard let title = text(item, kAXTitleAttribute as String),
                      let label = text(item, "AXStatusLabel")
                else { continue }
                result[title] = label
            }
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let items = ref as? [AXUIElement]
        else { return [] }
        return items
    }

    private static func text(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}

/// Защита фокуса. Включается из `FocusTimer` на старте фазы фокуса и выключается на её конце.
/// Время конца передаётся как `Date`; сам таймер сюда не импортируется.
@MainActor
final class FocusShield: ObservableObject {
    /// Browsers with AppleScript tab access: bundle id -> (application name, tab expression).
    private static let browsers: [String: (app: String, tab: String)] = [
        "com.apple.Safari": ("Safari", "current tab of front window"),
        "com.google.Chrome": ("Google Chrome", "active tab of front window"),
        "company.thebrowser.Browser": ("Arc", "active tab of front window"),
        "ru.yandex.desktop.yandex-browser": ("Yandex", "active tab of front window")
    ]
    private static let siteInterval: TimeInterval = 2
    private nonisolated static let scriptQueue = DispatchQueue(label: "NotchClip.focusshield.applescript", qos: .utility)

    /// Идёт ли защита прямо сейчас.
    @Published private(set) var isActive = false
    /// Текст про быстрые команды или nil, если DND готов к работе.
    @Published private(set) var dndStatus: String?
    /// Текст про доступ к браузеру (Автоматизация) или nil.
    @Published private(set) var siteStatus: String?
    /// Текст про доступ к Accessibility для сводки или nil.
    @Published private(set) var summaryStatus: String?
    /// Сводка последнего перерыва, например "Telegram +12 · Mail +3".
    @Published private(set) var lastSummary: String?

    /// Всплывающее сообщение для островка ("Telegram на паузе до 14:25").
    var onToast: ((String) -> Void)?

    private let defaults: UserDefaults
    private let clock: () -> Date
    private let runShortcut: (String) -> Void
    private let listShortcuts: () -> String

    private var shortcutCache: (date: Date, output: String)?
    private var shortcutLookupInProgress = false
    private var endDate: Date?
    private var activationObserver: NSObjectProtocol?
    private var siteTimer: Timer?
    private var siteCheckInProgress = false
    private var dndOnStart = false
    private var summaryOnStart = false
    private var startBadges: [String: String] = [:]

    init(
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = { Date() },
        runShortcut: @escaping (String) -> Void = FocusShield.runShortcutInBackground,
        listShortcuts: @escaping () -> String = FocusShield.installedShortcuts
    ) {
        self.defaults = defaults
        self.clock = clock
        self.runShortcut = runShortcut
        self.listShortcuts = listShortcuts
    }

    // MARK: - Управление

    /// Старт защиты на фазу фокуса, которая закончится в `endDate`.
    func start(endDate: Date) {
        self.endDate = endDate
        guard !isActive else { return }
        isActive = true
        dndOnStart = FocusShieldSettings.dndEnabled(defaults)
        summaryOnStart = FocusShieldSettings.summaryEnabled(defaults)

        if dndOnStart {
            refreshShortcutStatus()
            runShortcut(FocusShieldSettings.shortcutOn(defaults))
        } else {
            dndStatus = nil
        }

        if summaryOnStart {
            summaryStatus = DockBadges.isTrusted ? nil : "Включи NotchClip в «Универсальный доступ», чтобы считать бейджи"
            startBadges = DockBadges.snapshot()
        } else {
            summaryStatus = nil
            startBadges = [:]
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            handleActivation(bundleID: frontmost.bundleIdentifier, name: frontmost.localizedName ?? "Приложение")
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let name = app?.localizedName ?? bundleID ?? "Приложение"
            Task { @MainActor in self?.handleActivation(bundleID: bundleID, name: name) }
        }

        if !FocusShieldSettings.sites(defaults).isEmpty {
            siteTimer = Timer.scheduledTimer(withTimeInterval: Self.siteInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkFrontmostBrowser() }
            }
        }
    }

    /// Конец фокуса: выключает DND, снимает наблюдение и возвращает сводку перерыва (или nil).
    @discardableResult
    func stop(blocking: Bool = false) -> String? {
        guard isActive else { return nil }
        isActive = false
        endDate = nil

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        siteTimer?.invalidate()
        siteTimer = nil

        if dndOnStart {
            let name = FocusShieldSettings.shortcutOff(defaults)
            if blocking {
                // At quit a background job would die with the process and leave Do Not Disturb on.
                Self.runShortcutAndWait(name, timeout: 3)
            } else {
                runShortcut(name)
            }
        }

        var summary: String?
        if summaryOnStart {
            let endBadges = DockBadges.snapshot()
            summary = FocusShieldRules.summaryText(FocusShieldRules.badgeDeltas(start: startBadges, end: endBadges))
        }
        startBadges = [:]
        lastSummary = summary
        return summary
    }

    /// Вызывать при включении сводки в настройках: показывает системный запрос доступа.
    func enableSummaryAccess() {
        let trusted = DockBadges.requestAccess()
        summaryStatus = trusted ? nil : "Включи NotchClip в «Универсальный доступ», чтобы считать бейджи"
    }

    // MARK: - Приложения

    private func handleActivation(bundleID: String?, name: String) {
        guard FocusShieldRules.isAppBlocked(bundleID: bundleID,
                                            blocklist: FocusShieldSettings.apps(defaults),
                                            focusActive: isActive),
              let bundleID
        else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.hide() }
        onToast?(FocusShieldRules.pauseToast(name: name, until: endDate ?? clock()))
    }

    // MARK: - Сайты

    private func checkFrontmostBrowser() {
        guard isActive,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let browser = Self.browsers[bundleID]
        else { return }
        let domains = FocusShieldSettings.sites(defaults)
        guard !domains.isEmpty else { return }

        guard !siteCheckInProgress else { return }
        siteCheckInProgress = true
        let readSource = Self.readScript(browser), closeSource = Self.closeScript(browser)
        // AppleScript can hang for seconds while a browser is busy: never run it on the main thread.
        Self.scriptQueue.async { [weak self] in
            let url = Self.runAppleScript(readSource)
            var closed = false
            var blocked: String?
            if let url, let domain = FocusShieldRules.blockedDomain(for: url, in: domains) {
                blocked = domain
                closed = Self.runAppleScript(closeSource) != nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.siteCheckInProgress = false
                guard self.isActive else { return }
                guard url != nil else {
                    self.siteStatus = "Разреши NotchClip управлять браузером: Настройки → Конфиденциальность → Автоматизация"
                    return
                }
                self.siteStatus = nil
                if closed, let blocked { self.onToast?(FocusShieldRules.pauseToast(name: blocked, until: self.endDate ?? self.clock())) }
            }
        }
    }

    private static func readScript(_ browser: (app: String, tab: String)) -> String {
        """
        tell application "\(browser.app)"
          if (count of windows) is 0 then return ""
          return URL of \(browser.tab)
        end tell
        """
    }

    private static func closeScript(_ browser: (app: String, tab: String)) -> String {
        """
        tell application "\(browser.app)"
          if (count of windows) is 0 then return ""
          set URL of \(browser.tab) to "about:blank"
          return "ok"
        end tell
        """
    }

    /// Возвращает строку результата или nil при ошибке (например, нет Automation-доступа).
    private nonisolated static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result?.stringValue ?? ""
    }

    // MARK: - Быстрые команды

    private func refreshShortcutStatus() {
        let required = [FocusShieldSettings.shortcutOn(defaults), FocusShieldSettings.shortcutOff(defaults)]
        if let cache = shortcutCache, clock().timeIntervalSince(cache.date) < 600 {
            dndStatus = FocusShieldRules.shortcutStatus(missing: FocusShieldRules.missingShortcuts(listOutput: cache.output, required: required))
            return
        }
        guard !shortcutLookupInProgress else { return }
        shortcutLookupInProgress = true
        let lookup = listShortcuts
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = lookup()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.shortcutLookupInProgress = false
                self.shortcutCache = (self.clock(), output)
                guard self.isActive, self.dndOnStart else { return }
                let current = [FocusShieldSettings.shortcutOn(self.defaults), FocusShieldSettings.shortcutOff(self.defaults)]
                self.dndStatus = FocusShieldRules.shortcutStatus(missing: FocusShieldRules.missingShortcuts(listOutput: output, required: current))
            }
        }
    }

    /// Вывод `shortcuts list`. Пустая строка, если утилита недоступна.
    nonisolated static func installedShortcuts() -> String {
        runProcess("/usr/bin/shortcuts", ["list"]).output
    }

    /// Запускает команду и ждёт не дольше `timeout` секунд (для выхода из приложения).
    nonisolated static func runShortcutAndWait(_ name: String, timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runProcess("/usr/bin/shortcuts", ["run", name])
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Запускает быструю команду, не блокируя главный поток.
    nonisolated static func runShortcutInBackground(_ name: String) {
        DispatchQueue.global(qos: .utility).async {
            _ = runProcess("/usr/bin/shortcuts", ["run", name])
        }
    }

    private nonisolated static func runProcess(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
