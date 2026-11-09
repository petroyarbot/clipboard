import Foundation

// Checks for SettingsMapping.swift (presets, reset keys, hook status). Built and run by scripts/test.sh.

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

// Hover sensitivity: pair of delays <-> preset.
check(HoverSensitivity.immediate.openDelay == 0 && HoverSensitivity.immediate.closeDelay == 0.15, "Сразу is 0 / 0.15")
check(HoverSensitivity.normal.openDelay == 0 && HoverSensitivity.normal.closeDelay == 0.3, "Обычно is 0 / 0.30")
check(HoverSensitivity.slow.openDelay == 0.25 && HoverSensitivity.slow.closeDelay == 0.6, "Медленно is 0.25 / 0.6")
check(HoverSensitivity.matching(open: 0, close: 0.3) == .normal, "0 / 0.30 (defaults, fresh install and reset) maps to Обычно")
check(HoverSensitivity.matching(open: 0.0000001, close: 0.3) == .normal, "tiny float noise still matches")
check(HoverSensitivity.matching(open: 0, close: 0.15) == .immediate, "0 / 0.15 maps to Сразу")
check(HoverSensitivity.matching(open: 0.25, close: 0.6) == .slow, "0.25 / 0.6 maps to Медленно")
check(HoverSensitivity.matching(open: 0.1, close: 0.3) == nil, "old 0.1 / 0.3 is custom now")
check(HoverSensitivity.matching(open: 0.5, close: 0.5) == nil, "unknown pair is custom")

// Panel smoothness: bounce value <-> preset.
check(PanelSmoothness.noBounce.bounce == 0 && PanelSmoothness.soft.bounce == 0.12 && PanelSmoothness.elastic.bounce == 0.3, "preset bounce values")
check(PanelSmoothness.from(bounce: 0) == .noBounce, "bounce 0 is Без отскока")
check(PanelSmoothness.from(bounce: 0.12) == .soft, "default bounce 0.12 is Мягко")
check(PanelSmoothness.from(bounce: 0.35) == .elastic, "max bounce 0.35 is Упруго")
check(PanelSmoothness.from(bounce: 0.05) == .noBounce, "small bounce 0.05 snaps to Без отскока")
check(PanelSmoothness.from(bounce: 0.2) == .soft, "0.2 snaps to Мягко")
check(PanelSmoothness.from(bounce: 0.25) == .elastic, "0.25 snaps to Упруго")
for preset in PanelSmoothness.allCases {
    check(PanelSmoothness.from(bounce: preset.bounce) == preset, "round trip \(preset)")
}

// Size presets and range.
check(PanelSizePreset.matching(width: 620, height: 500) == .medium, "620x500 is Средний")
check(PanelSizePreset.matching(width: 620, height: 510) == nil, "620x510 is custom")
check(PanelSizeRange.clamped(width: 900, height: 100) == (800, 360), "size clamps to the allowed range")
check(PanelSizeRange.clamped(width: 500, height: 600) == (500, 600), "in-range size is unchanged")

// Reset keys: our settings only, never history, counters or the open tab.
let reset = SettingsMapping.resettableKeys
check(Set(reset).count == reset.count, "reset keys are unique")
check(reset.contains("hoverEnabled") && reset.contains("panelWidth") && reset.contains("saveToDownloads"), "reset covers general, panel and buffer settings")
check(reset.contains("focusTimer.soundEnabled") && reset.contains("focusTimer.focusMinutes"), "reset covers focus settings")
check(reset.contains("liveActivityFocus") && reset.contains("liveActivityAgents"), "reset covers live activity toggles")
check(reset.allSatisfy { !SettingsMapping.preservedKeys.contains($0) }, "reset never touches preserved keys")
check(!reset.contains("focusTimer.count") && !reset.contains("focusTimer.countDay") && !reset.contains("focusTimer.cycle"), "focus statistics are kept")
check(!reset.contains("panelTab"), "open tab is kept")

// Agent hook status: markers in the files.
check(AgentHookStatus.claudeInstalled(settingsText: "{\"command\":\"/x/notchclip-hook.sh\"}"), "claude hook marker is detected")
check(!AgentHookStatus.claudeInstalled(settingsText: "{}"), "claude without marker is not installed")
check(!AgentHookStatus.claudeInstalled(settingsText: nil), "missing claude settings is not installed")
check(AgentHookStatus.codexInstalled(configText: "notify = [\"/x/codex-notify-wrapper.sh\"]"), "codex wrapper marker is detected")
check(!AgentHookStatus.codexInstalled(configText: "model = \"o3\""), "codex without marker is not installed")
check(!AgentHookStatus.codexInstalled(configText: nil), "missing codex config is not installed")

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("all settings mapping checks passed")
