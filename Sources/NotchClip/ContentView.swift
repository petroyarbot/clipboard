import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class ViewState: ObservableObject {
    @Published var ocrRevision = 0
    @Published var query = ""
    @Published var confirmHistoryClear = false
    @Published var filter = 0
    @Published var editingID: UUID?
    @Published var editText = ""
    @Published var previewID: UUID?
    @Published var isEditing = false
}

struct ContentView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var delegate: AppDelegate
    @AppStorage("panelWidth") var panelWidth = 620.0
    @AppStorage("panelHeight") var panelHeight = 500.0
    @AppStorage(PanelTab.storageKey) private var tabRaw = PanelTab.clipboard.rawValue
    @StateObject private var state = ViewState()
    @AppStorage("recognizeImageText") private var recognizeImageText = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var filtered: [Clip] {
        _ = state.ocrRevision
        return store.history.ordered.filter { clip in
            let isLink = link(for: clip) != nil
            let typeMatches = state.filter == 0 || (state.filter == 1 && clip.kind == .text && !isLink) || (state.filter == 2 && (clip.kind == .image || isImageFile(clip))) || (state.filter == 3 && clip.kind == .file) || (state.filter == 4 && isLink)
            let value = clip.kind == .file ? fileName(for: clip) : (String(data: clip.data, encoding: .utf8) ?? "")
            let queryMatches = state.query.isEmpty || value.localizedCaseInsensitiveContains(state.query) || (recognizeImageText && delegate.ocr.matches(query: state.query, clipID: clip.id.uuidString))
            return typeMatches && queryMatches
        }
    }
    var tab: PanelTab { PanelTab.restore(tabRaw) }
    var tabBinding: Binding<PanelTab> {
        Binding(get: { PanelTab.restore(tabRaw) }, set: { value in withAnimation(IslandAnimation.interactive) { tabRaw = value.rawValue } })
    }
    var body: some View {
        let width = delegate.expanded ? panelWidth : Double(delegate.collapsedWidth)
        let height = delegate.expanded ? panelHeight : Double(delegate.collapsedHeight)
        let shape = NotchShape()
        shape.fill(Color.black)
        .frame(width: width, height: height, alignment: .top)
        .overlay(alignment: .top) {
            content.padding(.horizontal, 22).padding(.top, max(delegate.collapsedHeight + 8, 36)).padding(.bottom, 18)
                .frame(width: panelWidth, height: panelHeight, alignment: .top)
        }
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear { enqueueOCR() }
        .onChange(of: store.history.clips.count) { _ in enqueueOCR() }
        .onChange(of: recognizeImageText) { _ in enqueueOCR() }
        .onChange(of: tabRaw) { _ in delegate.liveActivity?.updateMusicActivity() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if recognizeImageText && !state.query.isEmpty { state.ocrRevision += 1 }
        }
        .onChange(of: delegate.expanded) { open in
            if !open { state.editingID = nil; state.previewID = nil; state.isEditing = false }
        }
    }
    func enqueueOCR() {
        guard recognizeImageText else { return }
        for clip in store.history.ordered.filter({ $0.kind == .image }).prefix(100) {
            let data = clip.data
            delegate.ocr.enqueue(clipID: clip.id.uuidString) { data }
        }
    }
    func copyOCR(_ clip: Clip) {
        guard let text = delegate.ocr.text(for: clip.id.uuidString), !text.isEmpty else {
            store.errorMessage = "Текст ещё распознаётся или не найден."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if state.previewID != nil {
                    Image(systemName: "clipboard").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Просмотр")
                        .font(.system(size: 15, weight: .semibold)).fixedSize()
                } else {
                    PanelTabBar(selection: tabBinding, agents: delegate.agents)
                }
                if state.previewID == nil && tab == .clipboard {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Поиск в истории", text: $state.query).textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }.padding(.horizontal, 10).frame(height: 32)
                        .modifier(GlassSurface(reduceTransparency: reduceTransparency))
                } else { Spacer(minLength: 0) }
                Button {
                    if state.previewID != nil { closePreview() }
                    else { delegate.openSettings() }
                } label: {
                    Image(systemName: state.previewID != nil ? "chevron.left" : "slider.horizontal.3")
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(state.previewID != nil ? "Назад к истории" : "Настройки").help(state.previewID != nil ? "Назад к истории" : "Настройки")
                Button { delegate.close() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Закрыть").help("Закрыть")
            }
            if let error = store.errorMessage {
                VStack(alignment: .leading, spacing: 2) {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    if error == ClipboardStore.fullDiskAccessMessage {
                        Button("Открыть настройки") { NSWorkspace.shared.open(ClipboardStore.fullDiskAccessURL) }
                            .buttonStyle(.link).font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let id = state.previewID, let clip = store.history.clips.first(where: { $0.id == id }) {
                preview(clip)
            } else {
                switch tab {
                case .clipboard: history
                case .focus:
                    ScrollView(showsIndicators: false) {
                        FocusView(timer: delegate.focusTimer, tracker: delegate.activityTracker)
                            .padding(.top, 6).padding(.bottom, 4)
                    }
                case .agents: AgentsView(usage: delegate.usage, agents: delegate.agents)
                case .shelf: ShelfView(store: delegate.shelf)
                case .music:
                    if let monitor = delegate.liveActivity?.music { NowPlayingPanelView(monitor: monitor) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if delegate.dropTargeted { Text("Отпусти, чтобы сохранить").font(.system(size: 13, weight: .medium)).padding(10).background(.ultraThinMaterial, in: Capsule()) }
        }
    }
    var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    filterBar(showIcons: true).fixedSize(horizontal: true, vertical: false)
                    filterBar(showIcons: false).fixedSize(horizontal: true, vertical: false)
                    ScrollView(.horizontal, showsIndicators: false) { filterBar(showIcons: false).fixedSize(horizontal: true, vertical: false) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { state.confirmHistoryClear = true } label: {
                    Label("Очистить", systemImage: "trash").font(.system(size: 12)).fixedSize()
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Очистить историю")
            }.fixedSize(horizontal: false, vertical: true)
            .confirmationDialog("Очистить историю?", isPresented: $state.confirmHistoryClear, titleVisibility: .visible) {
                Button("Очистить незакреплённые", role: .destructive) { store.clear() }
                Button("Очистить всё, включая закреплённые", role: .destructive) { store.clearAll() }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Сохранённые копии файлов из удалённых записей тоже будут удалены. Текущий системный буфер не изменится.")
            }
            .onChange(of: state.confirmHistoryClear) { showing in delegate.editing = showing || state.isEditing }
            if filtered.isEmpty {
                Spacer()
                Text(state.query.isEmpty ? "Скопируй текст или изображение" : "Ничего не найдено")
                    .foregroundStyle(.secondary).font(.system(size: 13)).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { clip in row(clip) }
                    }
                }
            }
        }
    }
    func filterBar(showIcons: Bool) -> some View {
        HStack(spacing: 5) {
            filterButton("Все", icon: nil, value: 0)
            filterButton("Текст", icon: showIcons ? "text.alignleft" : nil, value: 1)
            filterButton(showIcons ? "Изображения" : "Фото", icon: showIcons ? "photo" : nil, value: 2)
            filterButton("Файлы", icon: showIcons ? "doc" : nil, value: 3)
            filterButton("Ссылки", icon: showIcons ? "link" : nil, value: 4)
        }
    }
    func filterButton(_ title: String, icon: String?, value: Int) -> some View {
        Button { state.filter = value } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }.font(.system(size: 12, weight: state.filter == value ? .semibold : .regular))
                .padding(.horizontal, 8).frame(height: 27)
                .background(state.filter == value ? Color.white.opacity(0.22) : Color.white.opacity(0.06), in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel(value == 2 ? "Изображения" : title).accessibilityAddTraits(state.filter == value ? .isSelected : [])
    }

    func link(for clip: Clip) -> URL? { clip.linkURL }
    func fileName(for clip: Clip) -> String { (try? JSONDecoder().decode(StoredFile.self, from: clip.data))?.name ?? "Файл" }
    func isImageFile(_ clip: Clip) -> Bool {
        guard clip.kind == .file, let url = store.managedFileURL(for: clip), let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
    func image(for clip: Clip) -> NSImage? {
        if clip.kind == .image { return NSImage(data: clip.data) }
        guard isImageFile(clip), let url = store.managedFileURL(for: clip) else { return nil }
        return NSImage(contentsOf: url)
    }
    func closePreview() { state.previewID = nil; state.isEditing = false; delegate.editing = false }
    func openPreview(_ clip: Clip, edit: Bool = false) {
        state.previewID = clip.id; state.isEditing = edit; state.editText = String(data: clip.data, encoding: .utf8) ?? ""; delegate.editing = edit
    }
    func preview(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(clip.kind == .image ? "Просмотр изображения" : clip.kind == .file ? fileName(for: clip) : "Просмотр текста")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if clip.kind == .image && recognizeImageText { Button("Скопировать текст") { copyOCR(clip) } }
                if clip.kind == .text && !state.isEditing {
                    Button("Редактировать") { state.isEditing = true; delegate.editing = true }
                }
                if state.isEditing {
                    Button("Отмена") { state.isEditing = false; delegate.editing = false; state.editText = String(data: clip.data, encoding: .utf8) ?? "" }
                    Button("Сохранить") { store.edit(clip.id, text: state.editText); state.isEditing = false; delegate.editing = false }.disabled(state.editText.isEmpty)
                } else { Button("Копировать") { delegate.select(clip) } }
            }
            if clip.kind == .text {
                if state.isEditing {
                    TextEditor(text: $state.editText).font(.system(size: 14)).scrollContentBackground(.hidden)
                        .padding(8).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ScrollView { Text(String(data: clip.data, encoding: .utf8) ?? "").font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
            } else if let image = image(for: clip) {
                GeometryReader { geometry in Image(nsImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height) }
            } else {
                Spacer(); Label(fileName(for: clip), systemImage: "doc").frame(maxWidth: .infinity); Spacer()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    @ViewBuilder func row(_ clip: Clip) -> some View {
        if clip.kind == .file {
            rowContent(clip).onDrag {
                guard let url = store.exportFile(for: clip) else { return NSItemProvider() }
                return NSItemProvider(object: url as NSURL)
            }
        } else { rowContent(clip) }
    }
    func rowContent(_ clip: Clip) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button { delegate.select(clip) } label: {
                    HStack(spacing: 9) {
                        if let image = image(for: clip) {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 44, height: 30).clipped().clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(clip.kind == .file ? fileName(for: clip) : "Изображение").lineLimit(1)
                        } else {
                            Image(systemName: clip.kind == .file ? "doc" : link(for: clip) != nil ? "link" : "doc.text")
                                .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 28, height: 28)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            Text(clip.kind == .file ? fileName(for: clip) : (String(data: clip.data, encoding: .utf8) ?? ""))
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                    }.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Вернуть в буфер обмена")
                if clip.isPinned { Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(.purple).help("Закреплено") }
                Text(clip.createdAt, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Button { openPreview(clip) } label: { Image(systemName: "eye").frame(width: 26, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Просмотр записи").help("Просмотр")
            }.font(.system(size: 13)).padding(.horizontal, 4).padding(.vertical, 1)
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1).padding(.leading, 41)
        }.contentShape(Rectangle()).contextMenu {
            Button("Просмотреть", systemImage: "eye") { openPreview(clip) }
            Button("Копировать", systemImage: "doc.on.doc") { delegate.select(clip) }
            if clip.kind == .image && recognizeImageText { Button("Скопировать текст") { copyOCR(clip) } }
            Button(clip.isPinned ? "Открепить" : "Закрепить", systemImage: clip.isPinned ? "pin.slash" : "pin") { store.togglePin(clip.id) }
            if clip.kind == .text { Button("Редактировать", systemImage: "pencil") { openPreview(clip, edit: true) } }
            Button("Удалить", systemImage: "trash", role: .destructive) { store.remove(clip.id) }
        }
    }

}

// The top edge stays attached to the screen while the lower corners expand.
struct NotchShape: Shape {
    var bottomRadius: CGFloat = 26
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(16, rect.width / 6, rect.height / 3)
        let bottom = min(bottomRadius, rect.width / 3, max(0, rect.height - top))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct GlassSurface: ViewModifier {
    var reduceTransparency: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(white: 0.20), in: RoundedRectangle(cornerRadius: 11))
        } else {
            glass(content)
        }
    }
    @ViewBuilder private func glass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 11))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
        }
        #else
        content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
        #endif
    }
}
