import AppKit
import SwiftUI

/// Compact input card, 460 x 120. Enter saves, Shift+Enter adds a line, Esc cancels.
/// Focus: the text field takes first responder whenever `ThoughtCaptureModel.requestFocus()` runs
/// (ThoughtCapture.begin() does that). The hosting window must be able to become key,
/// for example a borderless NSPanel with `canBecomeKey` returning true, otherwise typing does not reach the field.
struct ThoughtCaptureView: View {
    @ObservedObject var model: ThoughtCaptureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ThoughtTextEditor(
                    text: $model.text,
                    focusRequest: model.focusRequest,
                    onSubmit: { model.onSubmit?(model.text) },
                    onCancel: { model.onCancel?() }
                )
                if model.text.isEmpty {
                    Text("Мысль… (Ctrl+Пробел — диктовка)")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(.leading, 5)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                if !model.context.chipText.isEmpty {
                    Text(model.context.chipText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Enter — сохранить · Shift+Enter — строка · Esc — отмена")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: 460, height: 120)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }
}

/// Multi-line AppKit field. SwiftUI's TextField on macOS 13 cannot tell Enter from Shift+Enter, so this wraps NSTextView.
struct ThoughtTextEditor: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var onSubmit: @MainActor () -> Void
    var onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ThoughtTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        context.coordinator.textView = textView

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ThoughtTextView else { return }
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            textView.requestFocus()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: ThoughtTextView?
        var lastFocusRequest = -1

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// Enter saves, Shift+Enter inserts a newline, Esc cancels. While an input method has marked text (Russian IME, dictation), keys go to the system.
@MainActor
final class ThoughtTextView: NSTextView {
    var onSubmit: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
        case 53: // Escape
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    /// Makes this view first responder once its window is key. Retries for about a second, because the window may still be opening.
    func requestFocus(attempt: Int = 0) {
        guard attempt < 20 else { return }
        if let window {
            window.makeFirstResponder(self)
            if window.isKeyWindow { return }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.requestFocus(attempt: attempt + 1)
        }
    }
}
