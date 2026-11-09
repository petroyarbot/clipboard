import Foundation

// Проверки чистого редьюсера островка. Время двигается явно; таймер получает фейковые часы.

final class FakeClock {
    var now: Date
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("ok   - \(name)")
    } else {
        print("FAIL - \(name)")
        failures += 1
    }
}

func inputs(_ timer: FocusState = .idle, phase: FocusPhase = .focus, needs: Int = 0, hover: Bool = false,
            focus: Bool = true, agents: Bool = true) -> IslandInputs {
    IslandInputs(timer: timer, phase: phase, needsActionCount: needs, hovering: hover, focusEnabled: focus, agentsEnabled: agents)
}

let now: TimeInterval = 1_000_000
let fresh = IslandState()

// 1. Выбор презентации.
check(fresh.presentation(inputs(), now: now) == .idle, "nothing active shows idle")
check(fresh.presentation(inputs(.running), now: now) == .compactTimer, "running timer shows compact timer")
check(fresh.presentation(inputs(.paused), now: now) == .compactTimer, "paused timer keeps compact timer")
check(fresh.presentation(inputs(needs: 2), now: now) == .compactAgent, "needs action shows compact agent")
check(fresh.presentation(inputs(.running, needs: 1), now: now) == .compactBoth, "agent and timer share the island")
check(fresh.presentation(inputs(.running, hover: true), now: now) == .miniPlayer, "hover on running timer opens mini player")
check(fresh.presentation(inputs(.paused, hover: true), now: now) == .miniPlayer, "hover on paused timer opens mini player")
check(fresh.presentation(inputs(.running, needs: 1, hover: true), now: now) == .miniPlayer, "focus opens on hover with agent")
check(fresh.presentation(inputs(needs: 1, hover: true), now: now) == .compactAgent, "hover with agent only stays compact")
check(fresh.presentation(inputs(hover: true), now: now) == .idle, "hover without activity stays idle")

// Настройки.
check(fresh.presentation(inputs(.running, focus: false), now: now) == .idle, "focus setting off hides the timer")
check(fresh.presentation(inputs(.running, needs: 1, agents: false), now: now) == .compactTimer, "agents setting off hides the agent")
check(fresh.presentation(inputs(needs: 3, agents: false), now: now) == .idle, "both settings off shows idle")

var toastState = IslandState()
toastState.showToast("Сохранено", at: now)
var musicInputs = inputs()
musicInputs.musicPlaying = true
check(fresh.presentation(musicInputs, now: now) == .compactMusic, "music shows when idle")
musicInputs.hovering = true
check(fresh.presentation(musicInputs, now: now) == .compactMusic, "hover on music opens the buffer by default (no mini player)")
musicInputs.musicHover = .openMiniPlayer
check(fresh.presentation(musicInputs, now: now) == .musicPlayer, "hover expands music when mini player is chosen")
musicInputs.musicHover = .openBuffer
check(fresh.presentation(inputs(.running, hover: true), now: now) == .miniPlayer, "music hover setting does not change the focus mini player")
musicInputs.hovering = false
check(toastState.presentation(musicInputs, now: now + 1) == .toast, "toast beats music")
check(toastState.presentation(inputs(.running), now: now + 1) == .toast, "toast beats focus")
check(toastState.presentation(inputs(needs: 1), now: now + 1) == .toast, "toast beats agent")
check(toastState.presentation(musicInputs, now: now + 2.5) == .compactMusic, "toast expires after 2.5 seconds")
musicInputs.musicEnabled = false
check(fresh.presentation(musicInputs, now: now) == .idle, "disabled music stays hidden")

var combo = inputs(.running)
combo.musicPlaying = true
check(fresh.presentation(combo, now: now) == .compactFocusMusic, "focus and music share island")
combo.needsActionCount = 2
check(fresh.presentation(combo, now: now) == .compactBoth, "agent and focus outrank music")
combo.focusEnabled = false
check(fresh.presentation(combo, now: now) == .compactAgentMusic, "agent and music share island")
combo.hovering = true
combo.musicHover = .openMiniPlayer
check(fresh.presentation(combo, now: now) == .musicPlayer, "music hover works with agent")
combo.musicEnabled = false
check(fresh.presentation(combo, now: now) == .compactAgent, "disabled music leaves agent")

// 2. Тихий режим: done копится во время фокуса, needsAction показывается сразу.
check(IslandState.isQuiet(timer: .running, phase: .focus), "quiet while a focus phase runs")
check(!IslandState.isQuiet(timer: .running, phase: .shortBreak), "not quiet during a break")
check(!IslandState.isQuiet(timer: .paused, phase: .focus), "not quiet while paused")
check(!IslandState.isQuiet(timer: .idle, phase: .focus), "not quiet when idle")

var quiet = IslandState()
quiet.agentsFinished(2, quiet: true)
quiet.agentsFinished(1, quiet: false)
check(quiet.queuedAgentDone == 2, "done events queue only in quiet mode")
check(quiet.presentation(inputs(.running), now: now) == .compactTimer, "queued done leaves the island unchanged")
check(quiet.presentation(inputs(.running, needs: 1), now: now) == .compactBoth, "needs action shares island during quiet mode")

// 3. Баннер окончания фазы: приоритет, срок жизни, подпись.
quiet.phaseEnded(finished: .focus, next: .shortBreak, nextMinutes: 5, completedToday: 3, at: now)
check(quiet.queuedAgentDone == 0, "phase end clears the queue")
check(quiet.banner?.agentsDone == 2, "phase end carries the queued done count")
check(quiet.banner.map(IslandState.bannerSubtitle) == "Сегодня: 3 · дальше: перерыв 5 мин · 2 агента закончили", "banner subtitle is one line with agents")
check(quiet.banner.map { IslandState.bannerTitle(finished: $0.finished) } == "Фокус окончен", "banner title after focus")
check(quiet.banner.map { IslandState.nextButtonTitle(next: $0.next) } == "Перерыв", "banner button starts the break")
check(quiet.presentation(inputs(), now: now + 1) == .banner, "banner shows over idle")
check(quiet.presentation(inputs(needs: 1), now: now + 1) == .banner, "banner beats needs action")
check(quiet.presentation(inputs(.running, needs: 1), now: now + 1) == .banner, "banner beats timer and agent")
check(quiet.presentation(inputs(), now: now + 3.99) == .banner, "banner still shown at 3.99 s")
check(quiet.presentation(inputs(needs: 1), now: now + 4) == .compactAgent, "banner expires at 4 s and needs action returns")
check(quiet.bannerExpiry == now + 4, "banner expiry is start plus 4 s")
check(quiet.presentation(inputs(focus: false), now: now + 1) == .idle, "focus setting off hides the banner")

var dismissed = quiet
dismissed.dismissBanner()
check(dismissed.presentation(inputs(), now: now + 1) == .idle, "dismissed banner disappears at once")

// 4. Пауза отдаёт очередь в мини-плеер; возобновление очищает.
var paused = IslandState()
paused.agentsFinished(2, quiet: true)
paused.quietEnded()
check(paused.releasedAgentDone == 2 && paused.queuedAgentDone == 0, "pause releases the queued done events")
paused.quietStarted()
check(paused.releasedAgentDone == 0 && paused.queuedAgentDone == 2, "resume moves the released count back into the queue")
check(paused.presentation(inputs(.running), now: now) == .compactTimer, "resumed focus keeps the queued count out of the island")
paused.phaseEnded(finished: .focus, next: .shortBreak, nextMinutes: 5, completedToday: 1, at: now)
check(paused.banner?.agentsDone == 2, "pause then resume still reports the agents in the phase-end banner")

// Пауза, затем пауза снова: счёт не растёт и не теряется.
var pausedTwice = IslandState()
pausedTwice.agentsFinished(2, quiet: true)
pausedTwice.quietEnded()
pausedTwice.quietStarted()
pausedTwice.quietEnded()
check(pausedTwice.releasedAgentDone == 2 && pausedTwice.queuedAgentDone == 0, "second pause releases the same two events")

// Пропуск фокуса: quietEnded (фаза сменилась на перерыв), затем фокус снова — счёт сохраняется.
var skipped = IslandState()
skipped.agentsFinished(3, quiet: true)
skipped.quietEnded()
check(skipped.releasedAgentDone == 3, "skip moves the queue into the released count")
skipped.quietStarted()
check(skipped.queuedAgentDone == 3 && skipped.releasedAgentDone == 0, "skip then focus again keeps the count of three")

// 5. Геометрия.
let bothWings = CompactWings(showsTimer: true, showsAgent: true, clock: "59:59", agentProject: "NotchClip", agentCount: 2)
let compact = IslandState.layout(for: .compactBoth, notchWidth: 200, notchHeight: 32, wings: bothWings)
check(compact?.width == 200 + 2 * (compact?.wing ?? 0) && compact?.height == 32 && compact?.bottomRadius == 12, "compact island is notch plus two equal wings, notch high")
check((compact?.wing ?? 0) >= IslandState.minimumWingWidth, "compact wing is at least the minimum width")

// Ширина крыла по времени: m:ss и h:mm:ss, без дёрганья внутри одного формата.
func timerWing(_ clock: String) -> CGFloat {
    IslandState.compactWingWidth(CompactWings(showsTimer: true, clock: clock))
}
func clockWidth(_ text: String) -> CGFloat {
    IslandState.textWidth(text, size: 13, weight: .semibold, digits: true)
}
let w444 = timerWing("4:44")
let w5959 = timerWing("59:59")
let w235959 = timerWing("23:59:59")
check(w444 == w5959, "m:ss wing width is the same for 4:44 and 59:59 (no jitter as the timer counts)")
check(w235959 > w5959, "h:mm:ss wing is wider than m:ss wing")
check(w444 >= IslandState.minimumWingWidth, "4:44 wing keeps the minimum width")
check(w5959 >= clockWidth("59:59") + IslandState.wingEdgePadding + IslandState.wingNotchGap, "59:59 fits inside the wing with edge padding and notch gap")
check(w235959 >= clockWidth("23:59:59") + IslandState.wingEdgePadding + IslandState.wingNotchGap, "23:59:59 fits inside the wing with edge padding and notch gap")
check(timerWing("1:05:00") == w235959, "1:05:00 uses the h:mm:ss reserved width")
check(IslandState.compactWingWidth(CompactWings(showsTimer: true, showsAgent: true, clock: "59:59", agentCount: 12)) >= IslandState.minimumWingWidth, "timer plus agent wing keeps the minimum width")
let mini = IslandState.layout(for: .miniPlayer, notchWidth: 200, notchHeight: 32)
check(mini?.width == 440 && mini?.height == 150 && mini?.bottomRadius == 30 && mini?.contentTop == 32, "mini player is 440x150 below the notch")
let bannerLayout = IslandState.layout(for: .banner, notchWidth: 200, notchHeight: 32)
check(bannerLayout?.width == 460 && bannerLayout?.height == 104 && bannerLayout?.bottomRadius == 22, "banner is 460x104")
check(IslandState.layout(for: .idle, notchWidth: 200, notchHeight: 32) == nil, "idle has no layout")

// 6. Склонения.
check(IslandState.agentsFinishedText(1) == "1 агент закончил", "one agent")
check(IslandState.agentsFinishedText(2) == "2 агента закончили", "two agents")
check(IslandState.agentsFinishedText(5) == "5 агентов закончили", "five agents")
check(IslandState.agentsFinishedText(11) == "11 агентов закончили", "eleven agents")
check(IslandState.agentsFinishedText(22) == "22 агента закончили", "twenty-two agents")

// 7. Настройки по умолчанию включены.
let musicSuite = UserDefaults(suiteName: "island-music-hover-\(UUID().uuidString)")!
check(IslandSettings.musicHoverAction(defaults: musicSuite) == .openBuffer, "hover on music defaults to the buffer")
musicSuite.set("miniPlayer", forKey: IslandSettings.hoverMusicActionKey)
check(IslandSettings.musicHoverAction(defaults: musicSuite) == .openMiniPlayer, "hover on music can be set to the mini player")
musicSuite.set("garbage", forKey: IslandSettings.hoverMusicActionKey)
check(IslandSettings.musicHoverAction(defaults: musicSuite) == .openBuffer, "unknown stored value falls back to the buffer")
let suite = UserDefaults(suiteName: "island-tests-\(UUID().uuidString)")!
check(IslandSettings.isEnabled(IslandSettings.focusKey, defaults: suite), "focus live activity defaults to on")
check(IslandSettings.isEnabled(IslandSettings.agentsKey, defaults: suite), "agents live activity defaults to on")
suite.set(false, forKey: IslandSettings.agentsKey)
check(!IslandSettings.isEnabled(IslandSettings.agentsKey, defaults: suite), "agents live activity can be turned off")

// 8. Сквозной путь через FocusTimer с фейковыми часами: конец фазы даёт баннер на 4 с.
@MainActor
func endToEnd() -> Int {
    var local = 0
    let defaults = UserDefaults(suiteName: "island-timer-\(UUID().uuidString)")!
    let clock = FakeClock(Date(timeIntervalSince1970: 1_700_000_000))
    let timer = FocusTimer(defaults: defaults, clock: { clock.now }, playSound: {}, notify: { _ in })
    timer.setMinutes(1, for: .focus)
    timer.start()
    clock.advance(timer.remaining)
    timer.tick()
    let end = timer.lastPhaseEnd
    if end?.finished != .focus || end?.next != .shortBreak { local += 1; print("FAIL - timer reports focus end") } else { print("ok   - timer reports focus end with next break") }

    var island = IslandState()
    let start = clock.now.timeIntervalSince1970
    if let end {
        island.phaseEnded(finished: end.finished, next: end.next, nextMinutes: end.nextMinutes, completedToday: end.completedToday, at: start)
    }
    let idleInputs = IslandInputs(timer: timer.state, phase: timer.phase)
    if island.presentation(idleInputs, now: start + 3.9) != .banner { local += 1; print("FAIL - banner after focus end") } else { print("ok   - banner appears after focus end") }
    clock.advance(4)
    if island.presentation(idleInputs, now: clock.now.timeIntervalSince1970) == .banner { local += 1; print("FAIL - banner expires after 4 s") } else { print("ok   - banner expires after 4 s") }

    // Пропуск фазы баннер не даёт.
    let skipped = FocusTimer(defaults: UserDefaults(suiteName: "island-skip-\(UUID().uuidString)")!, clock: { clock.now }, playSound: {}, notify: { _ in })
    skipped.start(); skipped.skip()
    if skipped.lastPhaseEnd != nil { local += 1; print("FAIL - skip does not raise a phase end") } else { print("ok   - skip does not raise a phase end") }
    return local
}

failures += MainActor.assumeIsolated { endToEnd() }

print(failures == 0 ? "All island tests passed" : "\(failures) island check(s) failed")
exit(failures == 0 ? 0 : 1)
