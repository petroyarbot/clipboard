import Foundation

// Checks for PanelTab.swift. Built and run by scripts/test.sh.

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

check(PanelTab.restore(nil) == .clipboard, "default tab is Буфер when nothing is stored")
check(PanelTab.restore("unknown") == .clipboard, "unknown stored tab falls back to Буфер")
check(PanelTab.restore("agents") == .agents, "stored agents tab is restored")
check(PanelTab.restore("focus") == .focus, "stored focus tab is restored")
check(PanelTab.allCases.map(\.title) == ["Буфер", "Фокус", "Агенты", "Полка", "Музыка"], "tab titles are in display order")
check(PanelTab.music.symbol == "music.note", "music uses the music note symbol")
check(PanelTab.allCases.allSatisfy { PanelTab.restore($0.rawValue) == $0 }, "every tab survives a raw value round trip")

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("all panel tab checks passed")
