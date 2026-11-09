import AppKit
import QuickLook
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Состояние полки: выбор и подсветка при перетаскивании. Модель, потому что локальный тулчейн без макроса @State.
@MainActor final class ShelfViewState: ObservableObject {
    @Published var selection: Set<UUID> = []
    @Published var targeted = false
}

@MainActor final class ShelfHoverState: ObservableObject {
    @Published var hovering = false
}

@MainActor final class ShelfThumbnailState: ObservableObject {
    @Published var image: NSImage?
}

/// Полка: горизонтальный ряд плиток 64 pt. Пустая полка показывает подсказку. Перетаскивание наружу
/// отдаёт файлы по URL (несколько выбранных сразу), внутрь принимает файлы, картинки и текст.
struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @StateObject private var ui = ShelfViewState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if store.items.isEmpty {
                emptyState
            } else {
                tiles
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ui.targeted ? Color.accentColor : Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .onDrop(of: [UTType.fileURL, UTType.image, UTType.plainText], isTargeted: $ui.targeted, perform: handleDrop)
        .onChange(of: store.items.map(\.id)) { ids in
            ui.selection = ui.selection.intersection(Set(ids))
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack {
            Text("Полка")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            if !store.items.isEmpty {
                Button("Очистить полку") {
                    ui.selection.removeAll()
                    store.clear()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 18))
            Text("Перетащи сюда файлы")
                .font(.system(size: 12))
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: .infinity, minHeight: 72)
    }

    private var tiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(store.items) { item in
                    let url = store.url(for: item)
                    let isSelected = ui.selection.contains(item.id)
                    ShelfTile(
                        item: item,
                        url: url,
                        isSelected: isSelected,
                        dragURLs: isSelected ? store.items.filter { ui.selection.contains($0.id) }.map { store.url(for: $0) } : [url],
                        onClick: { modifiers in select(item.id, modifiers: modifiers) },
                        onPreview: { ShelfQuickLook.shared.show(previewURLs(for: item), at: index(of: item)) },
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                        onRemove: {
                            ui.selection.remove(item.id)
                            store.remove(ids: [item.id])
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if ui.selection.contains(id) { ui.selection.remove(id) } else { ui.selection.insert(id) }
        } else {
            ui.selection = [id]
        }
    }

    private func index(of item: ShelfItem) -> Int {
        store.items.firstIndex(of: item) ?? 0
    }

    /// Quick Look листает выбранные элементы, если они есть, иначе всю полку.
    private func previewURLs(for item: ShelfItem) -> [URL] {
        let chosen = store.items.filter { ui.selection.contains($0.id) }
        let source = chosen.contains(item) ? chosen : store.items
        return source.map { store.url(for: $0) }
    }

    // MARK: Приём

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Своё перетаскивание наружу не должно вернуться копией.
        guard !ShelfDragState.isDragging else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await ShelfDropLoader.fileURL(from: provider) {
                    urls.append(url)
                } else if provider.canLoadObject(ofClass: NSImage.self),
                          let data = await ShelfDropLoader.pngData(from: provider) {
                    await store.add(data: data, named: "Изображение.png")
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = await ShelfDropLoader.text(from: provider) {
                    await store.addText(text)
                }
            }
            if !urls.isEmpty { await store.add(urls: urls) }
        }
        return true
    }
}

/// Плитка: миниатюра или значок, имя в одну строку, ✕ при наведении.
struct ShelfTile: View {
    let item: ShelfItem
    let url: URL
    let isSelected: Bool
    let dragURLs: [URL]
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onPreview: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    @StateObject private var hover = ShelfHoverState()

    var body: some View {
        VStack(spacing: 4) {
            ShelfThumbnail(url: url)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(isSelected ? 0.22 : 0.08)))
                .overlay(alignment: .topTrailing) {
                    if hover.hovering {
                        Button(action: onRemove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                    }
                }
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 72)
        }
        .frame(width: 72)
        .contentShape(Rectangle())
        .onHover { hover.hovering = $0 }
        .background(
            ShelfDragSource(
                dragURLs: dragURLs,
                onClick: onClick,
                onPreview: onPreview,
                onReveal: onReveal,
                onRemove: onRemove
            )
        )
    }
}

/// Миниатюра через Quick Look; если её нет, значок файла.
struct ShelfThumbnail: View {
    let url: URL
    @StateObject private var thumbnail = ShelfThumbnailState()

    var body: some View {
        Image(nsImage: thumbnail.image ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .scaledToFit()
            .padding(4)
            .task(id: url) {
                thumbnail.image = await ShelfThumbnail.make(for: url, size: 64)
            }
    }

    static func make(for url: URL, size: CGFloat) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .all
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

// MARK: - Перетаскивание наружу (AppKit)

/// Принимает клики и перетаскивание. Прозрачен для кнопки ✕ в правом верхнем углу, которую рисует SwiftUI.
struct ShelfDragSource: NSViewRepresentable {
    let dragURLs: [URL]
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onPreview: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    func makeNSView(context: Context) -> ShelfDragNSView {
        let view = ShelfDragNSView()
        view.apply(self)
        return view
    }

    func updateNSView(_ view: ShelfDragNSView, context: Context) {
        view.apply(self)
    }
}

/// Пока идёт перетаскивание из полки, приём на полку выключен, чтобы не получить копию.
enum ShelfDragState {
    @MainActor static var isDragging = false
}

final class ShelfDragNSView: NSView, NSDraggingSource {
    private var dragURLs: [URL] = []
    private var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    private var onPreview: () -> Void = {}
    private var onReveal: () -> Void = {}
    private var onRemove: () -> Void = {}
    private var mouseDownPoint: NSPoint?

    override var isFlipped: Bool { true }

    func apply(_ source: ShelfDragSource) {
        dragURLs = source.dragURLs
        onClick = source.onClick
        onPreview = source.onPreview
        onReveal = source.onReveal
        onRemove = source.onRemove
    }

    /// Правый верхний угол отдаём SwiftUI, чтобы сработала кнопка ✕.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), local.x > bounds.maxX - 24, local.y < 24 { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            onPreview()
        } else {
            onClick(event.modifierFlags)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4, !dragURLs.isEmpty else { return }
        mouseDownPoint = nil
        let items = dragURLs.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(index, 4)) * 6
            item.setDraggingFrame(NSRect(x: offset, y: -offset, width: 48, height: 48), contents: icon)
            return item
        }
        ShelfDragState.isDragging = true
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(menuItem("Quick Look", #selector(previewAction)))
        menu.addItem(menuItem("Показать в Finder", #selector(revealAction)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Удалить с полки", #selector(removeAction)))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func previewAction() { onPreview() }
    @objc private func revealAction() { onReveal() }
    @objc private func removeAction() { onRemove() }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        ShelfDragState.isDragging = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ShelfDragState.isDragging = false
    }
}

// MARK: - Quick Look

@MainActor
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(index, 0), urls.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

    // Quick Look вызывает источник на главном потоке, поэтому изоляция главного актора безопасна.
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

// MARK: - Загрузка из перетаскивания

enum ShelfDropLoader {
    static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    static func pngData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: bitmap.representation(using: .png, properties: [:]))
            }
        }
    }

    static func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString) as String?)
            }
        }
    }
}
