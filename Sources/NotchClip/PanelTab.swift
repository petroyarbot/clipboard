import Foundation

/// Вкладки панели. Выбор сохраняется между открытиями.
enum PanelTab: String, CaseIterable, Equatable {
    case clipboard
    case focus
    case agents
    case shelf
    case music

    static let storageKey = "panelTab"

    var title: String {
        switch self {
        case .clipboard: return "Буфер"
        case .focus: return "Фокус"
        case .agents: return "Агенты"
        case .shelf: return "Полка"
        case .music: return "Музыка"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .focus: return "timer"
        case .agents: return "sparkles"
        case .shelf: return "tray.full"
        case .music: return "music.note"
        }
    }

    /// Восстанавливает вкладку из UserDefaults; неизвестное значение даёт "Буфер".
    static func restore(_ raw: String?) -> PanelTab {
        raw.flatMap(PanelTab.init(rawValue:)) ?? .clipboard
    }
}
