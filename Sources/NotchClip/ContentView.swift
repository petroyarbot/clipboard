import SwiftUI
import AppKit

final class ViewState: ObservableObject {
    @Published var query = ""
    @Published var showingSettings = false
    @Published var confirmClear = false
}

struct ContentView: View {
    @ObservedObject var store: ClipboardStore
    unowned let delegate: AppDelegate
    @AppStorage("hoverEnabled") var hoverEnabled = true
    @AppStorage("shortcut") var shortcut = 0
    @StateObject private var state = ViewState()

    var filtered: [Clip] {
        guard !state.query.isEmpty else { return store.history.clips }
        return store.history.clips.filter { $0.kind == .text && (String(data: $0.data, encoding: .utf8) ?? "").localizedCaseInsensitiveContains(state.query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "clipboard.fill").foregroundStyle(.mint)
                Text("NotchClip").font(.headline)
                Spacer()
                Button { state.showingSettings.toggle() } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Настройки")
                Button { delegate.panel.orderOut(nil) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Закрыть")
            }
            if state.showingSettings {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Открывать при наведении сверху", isOn: $hoverEnabled)
                    Picker("Горячая клавиша", selection: $shortcut) {
                        Text("⌘ ⇧ V").tag(0); Text("⌘ ⇧ C").tag(1); Text("⌘ ⇧ Space").tag(2)
                    }.onChange(of: shortcut) { _ in delegate.registerShortcut() }
                    Text("История хранится локально на этом Mac. Выбор элемента возвращает его в буфер: вставь его через ⌘V.").font(.caption).foregroundStyle(.secondary)
                    Button("Очистить историю", role: .destructive) { state.confirmClear = true }
                        .confirmationDialog("Удалить всю историю?", isPresented: $state.confirmClear) {
                            Button("Очистить", role: .destructive) { store.clear() }
                        }
                    Button("Выйти из NotchClip") { NSApp.terminate(nil) }
                }.padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            TextField("Поиск по тексту", text: $state.query).textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(state.query.isEmpty ? "Здесь появится скопированное" : "Ничего не найдено").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { clip in
                            HStack(spacing: 10) {
                                Button { delegate.select(clip) } label: {
                                    HStack {
                                        if clip.kind == .image, let image = NSImage(data: clip.data) {
                                            Image(nsImage: image).resizable().scaledToFit().frame(width: 64, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                                            Text("Изображение").foregroundStyle(.primary)
                                        } else {
                                            Text(String(data: clip.data, encoding: .utf8) ?? "").lineLimit(3).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                        }
                                        Spacer()
                                    }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { store.remove(clip.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Удалить")
                            }.padding(10).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            HStack { Text("\(store.history.clips.count) / 100"); Spacer(); Text("Выбери элемент → ⌘V") }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 420, height: 510)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .preferredColorScheme(.dark)
    }
}
