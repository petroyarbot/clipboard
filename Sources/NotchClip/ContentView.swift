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
    @StateObject private var state = ViewState()

    var filtered: [Clip] {
        store.history.ordered.filter { clip in
            let typeMatches = state.filter == 0 || (state.filter == 1 && clip.kind == .text) || (state.filter == 2 && clip.kind == .image)
            let queryMatches = state.query.isEmpty || (clip.kind == .text && (String(data: clip.data, encoding: .utf8) ?? "").localizedCaseInsensitiveContains(state.query))
            return typeMatches && queryMatches
        }
    }
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: delegate.expanded ? 28 : 14, style: .continuous)
                .fill(Color.black)
                .frame(width: delegate.expanded ? 620 : 190, height: delegate.expanded ? 500 : 28)
            if delegate.expanded {
                content.padding(.horizontal, 22).padding(.top, 36).padding(.bottom, 18)
                    .frame(width: 620, height: 500)
                    .transition(.opacity.animation(.easeInOut(duration: 0.16)))
            }
        }.frame(width: 620, height: 500, alignment: .top).preferredColorScheme(.dark)
            .onChange(of: delegate.expanded) { open in
                if !open { state.editingID = nil; state.showingSettings = false }
            }
    }
    var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NotchClip").font(.headline)
                Spacer()
                Button { state.showingSettings.toggle(); delegate.editing = state.showingSettings } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Настройки")
                Button { delegate.close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Закрыть")
            }
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.showingSettings {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Открывать при наведении сверху", isOn: $hoverEnabled)
                    Picker("Горячая клавиша", selection: $shortcut) {
                        Text("⌘ ⇧ V").tag(0); Text("⌘ ⇧ C").tag(1); Text("⌘ ⇧ Space").tag(2)
                    }.onChange(of: shortcut) { _ in delegate.registerShortcut() }
                    Text("История хранится локально без шифрования.").font(.caption).foregroundStyle(.secondary)
                    Button("Очистить незакреплённую историю", role: .destructive) { state.confirmClear = true }
                        .confirmationDialog("Удалить незакреплённые записи?", isPresented: $state.confirmClear) {
                            Button("Очистить", role: .destructive) { store.clear() }
                        }
                    Button("Выйти из NotchClip") { NSApp.terminate(nil) }
                }.padding(10).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск в истории", text: $state.query).textFieldStyle(.plain)
            }.padding(9).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
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
    func section(_ title: String, items: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
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
        }.padding(.horizontal, 10).padding(.vertical, 3).background(.white.opacity(clip.isPinned ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    func finishEditing() { state.editingID = nil; delegate.editing = state.showingSettings }
}
