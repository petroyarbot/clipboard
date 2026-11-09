import Foundation

/// Чистые правила окна настроек: соответствие пресетов сохранённым значениям,
/// список ключей для сброса и проверка установки хуков. Без SwiftUI, тестируется отдельно.
enum SettingsMapping {
    /// Ключи UserDefaults, которые сбрасывает "Сбросить настройки". История, счётчики и вкладка не входят.
    static let resettableKeys: [String] = [
        "hoverEnabled", "shortcut", "thoughtShortcut", "saveToDownloads",
        "panelWidth", "panelHeight",
        "animationDuration", "animationBounce",
        "hoverOpenDelay", "hoverCloseDelay",
        "focusTimer.focusMinutes", "focusTimer.shortBreakMinutes", "focusTimer.longBreakMinutes",
        "focusTimer.soundEnabled", "focusTimer.focusSeconds",
        "liveActivityFocus", "liveActivityAgents", "liveActivityMusic",
        "screenshotsToHistory", "screenshotsMoveEnabled", "recognizeImageText",
        "focusShieldDND", "focusShieldSummary", "focusShieldApps", "focusShieldSites",
        "focusShieldShortcutOn", "focusShieldShortcutOff", "shelfRetentionDays", "assistantVaultPath",
    ]

    /// Ключи прогресса и данных, которые сброс настроек не трогает.
    static let preservedKeys: [String] = [
        "panelTab", "focusTimer.cycle", "focusTimer.count", "focusTimer.countDay",
    ]
}

/// Чувствительность наведения: пара задержек открытия и закрытия (секунды).
enum HoverSensitivity: CaseIterable, Equatable {
    case immediate
    case normal
    case slow

    var openDelay: Double {
        switch self {
        case .immediate: return 0
        case .normal: return 0
        case .slow: return 0.25
        }
    }

    var closeDelay: Double {
        switch self {
        case .immediate: return 0.15
        case .normal: return 0.30
        case .slow: return 0.6
        }
    }

    /// Пресет, если пара задержек совпадает с одним из трёх; иначе nil ("Свои значения").
    static func matching(open: Double, close: Double) -> HoverSensitivity? {
        allCases.first { abs($0.openDelay - open) < 0.001 && abs($0.closeDelay - close) < 0.001 }
    }
}

/// Плавность анимации панели, сопоставленная с сохранённой упругостью (animationBounce).
enum PanelSmoothness: CaseIterable, Equatable {
    case noBounce
    case soft
    case elastic

    var bounce: Double {
        switch self {
        case .noBounce: return 0
        case .soft: return 0.12
        case .elastic: return 0.3
        }
    }

    /// Ближайший пресет к сохранённому значению упругости.
    static func from(bounce: Double) -> PanelSmoothness {
        if bounce < 0.06 { return .noBounce }
        if bounce < 0.21 { return .soft }
        return .elastic
    }
}

/// Пресеты размера панели (ширина × высота, пункты).
enum PanelSizePreset: CaseIterable, Equatable {
    case compact
    case medium
    case large

    var width: Double {
        switch self {
        case .compact: return 480
        case .medium: return 620
        case .large: return 760
        }
    }

    var height: Double {
        switch self {
        case .compact: return 400
        case .medium: return 500
        case .large: return 600
        }
    }

    static func matching(width: Double, height: Double) -> PanelSizePreset? {
        allCases.first { $0.width == width && $0.height == height }
    }
}

/// Допустимый диапазон размеров панели, как и раньше в ручном вводе.
enum PanelSizeRange {
    static let width: ClosedRange<Double> = 420...800
    static let height: ClosedRange<Double> = 360...650
    static let step: Double = 10

    static func clamped(width: Double, height: Double) -> (width: Double, height: Double) {
        (min(max(width, 420), 800), min(max(height, 360), 650))
    }
}

/// Установка хуков агентов: проверка по содержимому файлов (сами файлы читает UI).
enum AgentHookStatus {
    static let claudeMarker = "notchclip-hook"
    static let codexMarker = "codex-notify-wrapper"

    static func claudeInstalled(settingsText: String?) -> Bool {
        settingsText?.contains(claudeMarker) ?? false
    }

    static func codexInstalled(configText: String?) -> Bool {
        configText?.contains(codexMarker) ?? false
    }
}
