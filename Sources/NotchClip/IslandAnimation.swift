import SwiftUI

/// Все константы движения панели и островка. Меняются только здесь.
enum IslandAnimation {
    static let openResponse = 0.42
    static let openDamping = 0.8
    static let closeResponse = 0.45
    static let closeDamping = 1.0
    static let interactiveResponse = 0.38
    static let interactiveDamping = 0.8

    /// Пружины для формы (чёрной фигуры).
    static let openSpring = Animation.spring(response: openResponse, dampingFraction: openDamping)
    static let closeSpring = Animation.spring(response: closeResponse, dampingFraction: closeDamping)
    static let interactive = Animation.interactiveSpring(response: interactiveResponse, dampingFraction: interactiveDamping)

    /// Плавная анимация содержимого (`.smooth` есть с macOS 14, для macOS 13 берём критически демпфированную пружину).
    static let smooth: Animation = {
        if #available(macOS 14.0, *) { return .smooth(duration: 0.3) }
        return .spring(response: 0.3, dampingFraction: 1.0)
    }()

    /// Содержимое появляется чуть позже формы, исчезает быстрее неё.
    static let contentIn = smooth.delay(0.1)
    static let contentOut = Animation.easeOut(duration: 0.12)
    static let crossfade = Animation.easeInOut(duration: 0.15)

    /// Открытие полной панели: длительность и упругость из настроек, по умолчанию как выше.
    /// nil при "Уменьшить движение": форма меняется мгновенно, остаётся только проявление содержимого.
    static func panelOpen(duration: Double, bounce: Double, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        let response = openResponse * duration / 0.30
        let damping = min(max(openDamping + (0.12 - bounce), 0.5), 1)
        return .spring(response: response, dampingFraction: damping)
    }

    static func panelClose(duration: Double, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: closeResponse * duration / 0.30, dampingFraction: closeDamping)
    }

    static func reveal(visible: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return crossfade }
        return visible ? contentIn : contentOut
    }
}

/// Видимость слоя островка. Чистая функция от состояния: непрозрачность 1 при `visible`, иначе 0, без отдельной
/// модели прогресса и без blur. Анимация только сглаживает переход; итоговое значение всегда определяется `visible`.
struct IslandReveal: ViewModifier {
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .animation(IslandAnimation.reveal(visible: visible, reduceMotion: reduceMotion), value: visible)
            .allowsHitTesting(visible)
    }
}
