import Foundation

@MainActor
func runTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ name: String) {
        if condition {
            print("ok   - \(name)")
        } else {
            failures += 1
            print("FAIL - \(name)")
        }
    }

    typealias Rules = FocusShieldRules

    // 1. Домены и хосты.
    check(Rules.normalizeDomain("https://www.YouTube.com/watch?v=1") == "youtube.com", "normalizes scheme, www, case and path")
    check(Rules.normalizeDomain("youtube.com:443") == "youtube.com", "normalizes port")
    check(Rules.normalizeDomain("   ") == nil, "empty domain is rejected")
    check(Rules.host(from: "https://m.youtube.com/shorts") == "m.youtube.com", "host from page URL")
    check(Rules.host(from: "about:blank") == nil, "about:blank has no host")
    check(Rules.matches(host: "m.youtube.com", domain: "youtube.com"), "subdomain m.youtube.com matches youtube.com")
    check(Rules.matches(host: "youtube.com", domain: "youtube.com"), "exact domain matches")
    check(!Rules.matches(host: "notyoutube.com", domain: "youtube.com"), "notyoutube.com does not match youtube.com")
    check(!Rules.matches(host: "youtube.com.evil.net", domain: "youtube.com"), "suffix trick does not match")
    check(Rules.blockedDomain(for: "https://m.youtube.com/", in: ["youtube.com"]) == "youtube.com", "blocked domain returned for subdomain")
    check(Rules.blockedDomain(for: "https://notyoutube.com/", in: ["youtube.com"]) == nil, "lookalike host is not blocked")
    check(Rules.blockedDomain(for: "https://example.com/", in: ["https://youtube.com/"]) == nil, "unrelated host is not blocked")
    check(Rules.blockedDomain(for: "https://youtube.com/", in: ["https://www.youtube.com/"]) == "youtube.com", "blocklist entry is normalized too")
    check(Rules.blockedDomain(for: "about:blank", in: ["youtube.com"]) == nil, "blank tab is not blocked")

    // 2. Блокировка приложений только во время фокуса.
    check(Rules.isAppBlocked(bundleID: "ru.keepcoder.Telegram", blocklist: ["ru.keepcoder.telegram"], focusActive: true), "blocked app during focus (case-insensitive)")
    check(!Rules.isAppBlocked(bundleID: "ru.keepcoder.Telegram", blocklist: ["ru.keepcoder.Telegram"], focusActive: false), "app is not blocked outside focus")
    check(!Rules.isAppBlocked(bundleID: "com.apple.Notes", blocklist: ["ru.keepcoder.Telegram"], focusActive: true), "unlisted app is not blocked")
    check(!Rules.isAppBlocked(bundleID: nil, blocklist: ["ru.keepcoder.Telegram"], focusActive: true), "nil bundle id is not blocked")
    check(!Rules.isAppBlocked(bundleID: "com.apple.Notes", blocklist: [], focusActive: true), "empty blocklist blocks nothing")

    // 3. Бейджи Dock.
    check(Rules.badgeValue("12") == 12, "numeric badge")
    check(Rules.badgeValue(" 3 ") == 3, "badge trims spaces")
    check(Rules.badgeValue("•") == 0, "dot badge counts as zero")
    check(Rules.badgeValue("abc") == 0, "non-numeric badge counts as zero")
    check(Rules.badgeValue("-2") == 0 && Rules.badgeValue("0") == 0, "zero and negative badges count as zero")
    check(Rules.badgeValue(nil) == 0, "missing badge counts as zero")

    let plus12 = Rules.badgeDeltas(start: ["Telegram": "3"], end: ["Telegram": "15"])
    check(plus12 == [BadgeDelta(name: "Telegram", delta: 12)], "numeric delta Telegram +12")
    check(Rules.badgeDeltas(start: [:], end: ["Mail": "4"]) == [BadgeDelta(name: "Mail", delta: 4)], "new badge counts from zero")
    check(Rules.badgeDeltas(start: ["Slack": "•"], end: ["Slack": "•"]).isEmpty, "unchanged dot badge gives no delta")
    check(Rules.badgeDeltas(start: ["Slack": "•"], end: ["Slack": "5"]) == [BadgeDelta(name: "Slack", delta: 5)], "dot turning into number counts the number")
    check(Rules.badgeDeltas(start: ["Slack": "3"], end: ["Slack": "•"]).isEmpty, "number turning into dot is not a gain")
    check(Rules.badgeDeltas(start: ["Mail": "9"], end: ["Mail": "2"]).isEmpty, "decreasing badge is ignored")
    let sorted = Rules.badgeDeltas(start: ["B": "1", "A": "1"], end: ["A": "3", "B": "9", "C": "2"])
    check(sorted.map(\.name) == ["B", "A", "C"] && sorted.map(\.delta) == [8, 2, 2], "deltas sorted by size then name")

    // 4. Текст сводки и тостов.
    check(Rules.summaryText([]) == nil, "no summary when nothing changed")
    check(Rules.summaryText(plus12 + [BadgeDelta(name: "Mail", delta: 3)]) == "Telegram +12 · Mail +3", "summary text joins deltas")

    var calendar = Calendar.current
    calendar.timeZone = TimeZone.current
    let until = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 14, minute: 25))!
    check(Rules.timeText(until) == "14:25", "time text uses HH:mm")
    check(Rules.pauseToast(name: "Telegram", until: until) == "Telegram на паузе до 14:25", "app toast text")
    check(Rules.pauseToast(name: "youtube.com", until: until) == "youtube.com на паузе до 14:25", "site toast text")

    // 5. Быстрые команды.
    let required = ["NotchClip Фокус вкл", "NotchClip Фокус выкл"]
    check(Rules.missingShortcuts(listOutput: "NotchClip Фокус вкл \nNotchClip Фокус выкл\nДругая\n", required: required).isEmpty, "both shortcuts installed (trailing spaces ignored)")
    let missing = Rules.missingShortcuts(listOutput: "NotchClip Фокус вкл\nДругая\n", required: required)
    check(missing == ["NotchClip Фокус выкл"], "detects the missing shortcut")
    check(Rules.missingShortcuts(listOutput: "", required: required) == required, "empty list means all shortcuts missing")
    check(Rules.shortcutStatus(missing: []) == nil, "no status when shortcuts exist")
    check(Rules.shortcutStatus(missing: missing)?.hasPrefix("Создай быстрые команды") == true, "status asks to create shortcuts")

    return failures
}

let failureCount = MainActor.assumeIsolated { runTests() }
print(failureCount == 0 ? "All focus shield tests passed" : "\(failureCount) focus shield check(s) failed")
exit(failureCount == 0 ? 0 : 1)
