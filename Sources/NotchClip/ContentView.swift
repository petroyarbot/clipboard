import SwiftUI
import AppKit

final class ViewState: ObservableObject {
    @Published var query = ""
    @Published var showingSettings = false
    @Published var confirmClear = false
    @Published var filter = 0
    @Published var editingID: UUID?
    @Published var editText = ""
}

struct ContentView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var delegate: AppDelegate
    @AppStorage("hoverEnabled") var hoverEnabled = true
    @AppStorage("shortcut") var shortcut = 0
    @AppStorage("panelWidth") var panelWidth = 620.0
    @AppStorage("panelHeight") var panelHeight = 500.0
    @AppStorage("animationDuration") var animationDuration = 0.30
    @AppStorage("animationBounce") var animationBounce = 0.12
    @AppStorage("hoverOpenDelay") var hoverOpenDelay = 0.0
    @AppStorage("hoverCloseDelay") var hoverCloseDelay = 0.30
    @StateObject private var state = ViewState()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var filtered: [Clip] {
        store.history.ordered.filter { clip in
            let typeMatches = state.filter == 0 || (state.filter == 1 && clip.kind == .text) || (state.filter == 2 && clip.kind == .image)
            let queryMatches = state.query.isEmpty || (clip.kind == .text && (String(data: clip.data, encoding: .utf8) ?? "").localizedCaseInsensitiveContains(state.query))
            return typeMatches && queryMatches
        }
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
                .opacity(delegate.expanded ? 1 : 0)
                .allowsHitTesting(delegate.expanded)
        }
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onChange(of: delegate.expanded) { open in
            if !open { state.editingID = nil; state.showingSettings = false }
        }
    }
    var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "clipboard").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Text("Буфер обмена").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { state.showingSettings.toggle() } label: { Image(systemName: state.showingSettings ? "gearshape.fill" : "gearshape").frame(width: 30, height: 30).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Настройки").help("Настройки")
                Button { delegate.close() } label: { Image(systemName: "xmark").frame(width: 30, height: 30).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Закрыть").help("Закрыть")
            }
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.showingSettings {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle("Открывать при наведении", isOn: $hoverEnabled)
                        Picker("Горячая клавиша", selection: $shortcut) {
                            Text("⌘ ⇧ V").tag(0); Text("⌘ ⇧ C").tag(1); Text("⌘ ⇧ Space").tag(2)
                        }.onChange(of: shortcut) { _ in delegate.registerShortcut() }
                        settingSlider("Ширина", value: $panelWidth, range: 420...800, step: 10, unit: "пт")
                            .onChange(of: panelWidth) { _ in delegate.updatePanelSize() }
                        settingSlider("Высота", value: $panelHeight, range: 360...650, step: 10, unit: "пт")
                            .onChange(of: panelHeight) { _ in delegate.updatePanelSize() }
                        settingSlider("Длительность", value: $animationDuration, range: 0.2...0.8, step: 0.05, unit: "с")
                        settingSlider("Упругость", value: $animationBounce, range: 0...0.35, step: 0.05, unit: "")
                        settingSlider("Задержка открытия", value: $hoverOpenDelay, range: 0...0.8, step: 0.05, unit: "с")
                        settingSlider("Задержка закрытия", value: $hoverCloseDelay, range: 0...1.5, step: 0.05, unit: "с")
                        Text("История хранится локально без шифрования.").font(.caption).foregroundStyle(.secondary)
                        Button("Очистить незакреплённую историю", role: .destructive) { state.confirmClear = true }
                            .confirmationDialog("Удалить незакреплённые записи?", isPresented: $state.confirmClear) {
                                Button("Очистить", role: .destructive) { store.clear() }
                            }
                        Button("Выйти из NotchClip") { NSApp.terminate(nil) }
                    }.padding(10)
                }.frame(maxHeight: 240).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск в истории", text: $state.query).textFieldStyle(.plain)
                    .font(.system(size: 14))
            }.padding(.horizontal, 12).padding(.vertical, 10).modifier(GlassSurface(reduceTransparency: reduceTransparency))
            Picker("Фильтр", selection: $state.filter) {
                Text("Все").tag(0); Text("Текст").tag(1); Text("Изображения").tag(2)
            }.pickerStyle(.segmented)
            if filtered.isEmpty {
                Spacer(); Text(state.query.isEmpty ? "Здесь появится скопированное" : "Ничего не найдено").foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if filtered.contains(where: \.isPinned) { section("Закреплено", items: filtered.filter(\.isPinned)) }
                        if filtered.contains(where: { !$0.isPinned }) { section("Недавние", items: filtered.filter { !$0.isPinned }) }
                    }
                }
            }
            HStack { Text("Выбери запись, затем нажми ⌘V"); Spacer(); Text("\(store.history.clips.count) записей") }.font(.caption).foregroundStyle(.secondary)
        }
    }
    func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 145, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(unit == "пт" ? "\(Int(value.wrappedValue)) \(unit)" : String(format: "%.2f %@", value.wrappedValue, unit))
                .monospacedDigit().frame(width: 65, alignment: .trailing)
        }.font(.system(size: 13))
    }
    func section(_ title: String, items: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(items) { clip in row(clip) }
        }
    }
    func row(_ clip: Clip) -> some View {
        HStack(spacing: 10) {
            if state.editingID == clip.id {
                TextField("Текст", text: $state.editText, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                Button("Сохранить") { store.edit(clip.id, text: state.editText); finishEditing() }.disabled(state.editText.isEmpty)
                Button("Отмена") { finishEditing() }
            } else {
                Button { delegate.select(clip) } label: {
                    HStack {
                        if clip.kind == .image, let image = NSImage(data: clip.data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 72, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                            Text("Изображение").foregroundStyle(.primary)
                        } else {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(String(data: clip.data, encoding: .utf8) ?? "").lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(.primary)
                        }
                        Spacer()
                    }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { store.togglePin(clip.id) } label: { Image(systemName: clip.isPinned ? "pin.fill" : "pin") }.buttonStyle(.plain).foregroundStyle(clip.isPinned ? .purple : .secondary).help(clip.isPinned ? "Открепить" : "Закрепить")
                if clip.kind == .text {
                    Button { state.editingID = clip.id; state.editText = String(data: clip.data, encoding: .utf8) ?? ""; delegate.editing = true } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("Редактировать")
                }
                Button { store.remove(clip.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Удалить")
            }
        }.font(.system(size: 14)).padding(.horizontal, 12).padding(.vertical, 5)
            .background(.white.opacity(clip.isPinned ? 0.11 : 0.055), in: RoundedRectangle(cornerRadius: 10))
    }
    func finishEditing() { state.editingID = nil; delegate.editing = false }
}

// The top edge stays attached to the screen while the lower corners expand.
struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let top = min(16, rect.width / 6, rect.height / 3)
        let bottom = min(26, rect.width / 3, max(0, rect.height - top))
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
