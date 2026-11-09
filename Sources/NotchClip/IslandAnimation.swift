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

/// Эффект проявления для `.transition`: blur 6 -> 0, scale 0.96 -> 1, opacity 0 -> 1.
/// Применяется только как transition вставки/удаления, поэтому у содержимого в покое нет постоянной модели
/// "прогресса": нечему зависнуть на промежуточном значении.
private struct RevealEffect: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden ? 6 : 0)
            .scaleEffect(hidden ? 0.96 : 1)
    }
}

extension AnyTransition {
    /// Проявление с блюром; при "Уменьшить движение" только прозрачность.
    static func reveal(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .modifier(active: RevealEffect(hidden: true), identity: RevealEffect(hidden: false))
    }
}

/// Состояние вставки (класс: макрос @State недоступен в CLT, как и в SettingsView).
private final class RevealModel: ObservableObject {
    @Published var shown: Bool
    @Published var generation = 0
    @Published var settledGeneration = -1
    var pending = 0
    init(shown: Bool) { self.shown = shown }
}

/// Содержимое вставляется в иерархию уже после показа окна (на следующем проходе цикла событий) и проявляется
/// как transition вставки. Никакого постоянного blur/opacity на всей панели: в покое у содержимого эффектов нет.
/// Каждое открытие (`visible` стал true или сменился `token`) вставляет содержимое заново.
/// Страховка: если через 0.8 с содержимое всё ещё помечено "в анимации", оно пересоздаётся без transition.
struct IslandReveal: ViewModifier {
    let visible: Bool
    let token: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: RevealModel

    init(visible: Bool, token: Int = 0) {
        self.visible = visible
        self.token = token
        _model = StateObject(wrappedValue: RevealModel(shown: visible))
    }

    func body(content: Content) -> some View {
        Group {
            if model.shown {
                content
                    .id(model.generation)
                    .transition(model.settledGeneration == model.generation ? .identity : .reveal(reduceMotion: reduceMotion))
            }
        }
        .allowsHitTesting(visible)
        .onChange(of: visible) { apply($0) }
        .onChange(of: token) { _ in if visible { apply(true) } }
    }

    private func apply(_ on: Bool) {
        let model = model
        let visible = visible
        model.pending &+= 1
        let ticket = model.pending
        guard on else {
            withAnimation(IslandAnimation.reveal(visible: false, reduceMotion: reduceMotion)) { model.shown = false }
            return
        }
        // Убираем старое содержимое без анимации, на следующем проходе цикла вставляем с transition.
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) { model.shown = false; model.generation &+= 1 }
        let animation = IslandAnimation.reveal(visible: true, reduceMotion: reduceMotion)
        DispatchQueue.main.async {
            guard model.pending == ticket, visible else { return }
            withAnimation(animation) { model.shown = true }
        }
        // Страховка: пересоздать содержимое без transition, если проявление не завершилось.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard model.pending == ticket, visible, model.shown else { return }
            var instant = Transaction(); instant.disablesAnimations = true
            withTransaction(instant) { model.generation &+= 1; model.settledGeneration = model.generation }
        }
    }
}
