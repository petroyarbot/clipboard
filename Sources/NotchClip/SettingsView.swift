import SwiftUI
import AppKit
import ServiceManagement

/// Окно настроек (scene `Settings`): пять вкладок. Ключи UserDefaults те же, что и раньше.
struct SettingsView: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var store: ClipboardStore
    @ObservedObject var timer: FocusTimer
    @ObservedObject var usage: UsageMonitor

    var body: some View {
        TabView {
            GeneralSettingsTab(delegate: delegate)
                .tabItem { Label("Общие", systemImage: "gearshape") }
            PanelSettingsTab(delegate: delegate)
                .tabItem { Label("Панель", systemImage: "rectangle.topthird.inset.filled") }
            BufferSettingsTab(store: store)
                .tabItem { Label("Буфер", systemImage: "doc.on.clipboard") }
            FocusSettingsTab(timer: timer)
                .tabItem { Label("Фокус", systemImage: "timer") }
            AgentsSettingsTab(usage: usage)
                .tabItem { Label("Агенты", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Общие

private struct GeneralSettingsTab: View {
    @ObservedObject var delegate: AppDelegate
    @AppStorage("hoverEnabled") private var hoverEnabled = true
    @AppStorage("shortcut") private var shortcut = 0
    @AppStorage("hoverOpenDelay") private var openDelay = 0.0
    @AppStorage("hoverCloseDelay") private var closeDelay = 0.30
    @StateObject private var state = GeneralTabState()

    var body: some View {
        Form {
            Section {
                Toggle("Запускать при входе", isOn: Binding(get: { state.loginStatus == .enabled }, set: setLaunchAtLogin))
                if state.loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Открыть настройки") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    } label: {
                        Text("Нужно разрешение в Объектах входа").foregroundStyle(.secondary)
                    }
                }
                if let loginError = state.loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                Picker("Горячая клавиша", selection: $shortcut) {
                    Text("⌘ ⇧ V").tag(0)
                    Text("⌘ ⇧ C").tag(1)
                    Text("⌘ ⇧ Space").tag(2)
                }
                .onChange(of: shortcut) { _ in delegate.registerShortcut() }
            } header: {
                Text("Запуск")
            }

            Section {
                Toggle("По наведению", isOn: $hoverEnabled)
                LabeledContent("Чувствительность") {
                    Picker("Чувствительность", selection: sensitivityBinding) {
                        Text("Сразу").tag(Optional(HoverSensitivity.immediate))
                        Text("Обычно").tag(Optional(HoverSensitivity.normal))
                        Text("Медленно").tag(Optional(HoverSensitivity.slow))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                DisclosureGroup("Свои значения", isExpanded: $state.showCustomDelays) {
                    delayStepper("Задержка открытия", value: $openDelay, range: 0...0.8)
                    delayStepper("Задержка закрытия", value: $closeDelay, range: 0...1.5)
                }
            } header: {
                Text("Открытие")
            }

            Section {
                HStack {
                    Button("Сбросить настройки", role: .destructive) { state.confirmReset = true }
                    Spacer()
                    Button("Выйти из NotchClip") { NSApp.terminate(nil) }
                }
            } footer: {
                Text(Self.versionText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { state.loginStatus = SMAppService.mainApp.status }
        .confirmationDialog("Сбросить настройки?", isPresented: $state.confirmReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) { resetSettings() }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Параметры вернутся к значениям по умолчанию. История буфера и статистика фокуса не изменятся.")
        }
    }

    private var sensitivityBinding: Binding<HoverSensitivity?> {
        Binding(
            get: { HoverSensitivity.matching(open: openDelay, close: closeDelay) },
            set: { value in
                guard let value else { return }
                openDelay = value.openDelay
                closeDelay = value.closeDelay
            }
        )
    }

    private func delayStepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 0.05) {
            LabeledContent(title) {
                Text(String(format: "%.2f с", value.wrappedValue)).monospacedDigit()
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            state.loginError = nil
        } catch {
            state.loginError = "Не удалось изменить: \(error.localizedDescription)"
        }
        state.loginStatus = SMAppService.mainApp.status
    }

    /// Удаляет только ключи настроек (список в SettingsMapping), историю не трогает.
    private func resetSettings() {
        for key in SettingsMapping.resettableKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        delegate.registerShortcut()
        delegate.updatePanelSize()
        delegate.focusTimer.reloadDurations()
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["NotchClipCommit"] as? String ?? "unknown"
        return "Версия \(version) (\(build)) · \(commit)"
    }
}

// MARK: - Панель

private struct PanelSettingsTab: View {
    @ObservedObject var delegate: AppDelegate
    @AppStorage("panelWidth") private var panelWidth = 620.0
    @AppStorage("panelHeight") private var panelHeight = 500.0
    @AppStorage("animationDuration") private var animationDuration = 0.30
    @AppStorage("animationBounce") private var animationBounce = 0.12
    @AppStorage(IslandSettings.focusKey) private var liveFocus = true
    @AppStorage(IslandSettings.agentsKey) private var liveAgents = true
    @StateObject private var state = PanelTabState()

    var body: some View {
        Form {
            Section {
                LabeledContent("Пресет") {
                    Picker("Пресет", selection: presetBinding) {
                        Text("Компактный").tag(Optional(PanelSizePreset.compact))
                        Text("Средний").tag(Optional(PanelSizePreset.medium))
                        Text("Большой").tag(Optional(PanelSizePreset.large))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                DisclosureGroup("Свой размер", isExpanded: $state.showCustomSize) {
                    Stepper(value: widthBinding, in: PanelSizeRange.width, step: PanelSizeRange.step) {
                        LabeledContent("Ширина") { Text("\(Int(panelWidth)) пт").monospacedDigit() }
                    }
                    Stepper(value: heightBinding, in: PanelSizeRange.height, step: PanelSizeRange.step) {
                        LabeledContent("Высота") { Text("\(Int(panelHeight)) пт").monospacedDigit() }
                    }
                }
            } header: {
                Text("Размер")
            } footer: {
                Text("Ширина 420–800 пт, высота 360–650 пт.")
            }

            Section {
                LabeledContent("Плавность") {
                    Picker("Плавность", selection: smoothnessBinding) {
                        Text("Без отскока").tag(PanelSmoothness.noBounce)
                        Text("Мягко").tag(PanelSmoothness.soft)
                        Text("Упруго").tag(PanelSmoothness.elastic)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                LabeledContent("Длительность") {
                    HStack(spacing: 8) {
                        Slider(value: $animationDuration, in: 0.2...0.8, step: 0.05).frame(width: 170)
                        Text(String(format: "%.2f с", animationDuration))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            } header: {
                Text("Анимация")
            }

            Section {
                Toggle("Таймер в чёлке", isOn: $liveFocus)
                Toggle("Агенты в чёлке", isOn: $liveAgents)
            } header: {
                Text("Живая активность")
            }
        }
        .formStyle(.grouped)
    }

    private var presetBinding: Binding<PanelSizePreset?> {
        Binding(
            get: { PanelSizePreset.matching(width: panelWidth, height: panelHeight) },
            set: { preset in
                guard let preset else { return }
                panelWidth = preset.width
                panelHeight = preset.height
                delegate.updatePanelSize()
            }
        )
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { panelWidth }, set: { panelWidth = PanelSizeRange.clamped(width: $0, height: panelHeight).width; delegate.updatePanelSize() })
    }

    private var heightBinding: Binding<Double> {
        Binding(get: { panelHeight }, set: { panelHeight = PanelSizeRange.clamped(width: panelWidth, height: $0).height; delegate.updatePanelSize() })
    }

    private var smoothnessBinding: Binding<PanelSmoothness> {
        Binding(
            get: { PanelSmoothness.from(bounce: animationBounce) },
            set: { animationBounce = $0.bounce }
        )
    }
}

// MARK: - Буфер

private struct BufferSettingsTab: View {
    @ObservedObject var store: ClipboardStore
    @AppStorage(ClipboardStore.downloadsKey) private var saveToDownloads = true
    @StateObject private var state = BufferTabState()

    var body: some View {
        Form {
            Section {
                Toggle("Сохранять фото и файлы в Загрузки", isOn: $saveToDownloads)
            }
            Section {
                Button("Очистить историю…", role: .destructive) { state.confirmClear = true }
            } footer: {
                Text("История хранится локально на этом Mac, без шифрования.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Очистить историю?", isPresented: $state.confirmClear, titleVisibility: .visible) {
            Button("Очистить незакреплённые", role: .destructive) { store.clear() }
            Button("Очистить всё, включая закреплённые", role: .destructive) { store.clearAll() }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Сохранённые копии файлов из удалённых записей тоже будут удалены. Текущий системный буфер не изменится.")
        }
    }
}

// MARK: - Фокус

private struct FocusSettingsTab: View {
    @ObservedObject var timer: FocusTimer
    @AppStorage(FocusTimer.soundEnabledKey) private var sound = true

    var body: some View {
        Form {
            Section {
                minuteStepper("Фокус", phase: .focus)
                minuteStepper("Короткий перерыв", phase: .shortBreak)
                minuteStepper("Длинный перерыв", phase: .longBreak)
            } header: {
                Text("Длительность")
            } footer: {
                Text(timer.state == .idle ? "Минуты от 1 до 180." : "Изменить можно, когда таймер остановлен.")
            }

            Section {
                Toggle("Звук в конце фазы", isOn: $sound)
            }
        }
        .formStyle(.grouped)
    }

    private func minuteStepper(_ title: String, phase: FocusPhase) -> some View {
        Stepper(
            value: Binding(get: { timer.minutes(for: phase) }, set: { timer.setMinutes($0, for: phase) }),
            in: 1...180
        ) {
            LabeledContent(title) { Text("\(timer.minutes(for: phase)) мин").monospacedDigit() }
        }
        .disabled(timer.state != .idle)
    }
}

// MARK: - Агенты

/// Текст вывода скрипта установки для листа.
struct ScriptOutput: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

private struct AgentsSettingsTab: View {
    @ObservedObject var usage: UsageMonitor
    @StateObject private var state = AgentsTabState()

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude Code") {
                    Text(state.claudeHooks ? "Установлены" : "Не установлены").foregroundStyle(state.claudeHooks ? .green : .secondary)
                }
                LabeledContent("Codex") {
                    Text(state.codexHooks ? "Установлены" : "Не установлены").foregroundStyle(state.codexHooks ? .green : .secondary)
                }
                HStack {
                    Spacer()
                    Button(state.claudeHooks && state.codexHooks ? "Удалить" : "Установить") {
                        runSetup(uninstall: state.claudeHooks && state.codexHooks)
                    }
                    .disabled(state.running)
                }
            } header: {
                Text("Хуки агентов")
            } footer: {
                Text("Хуки передают статус задач и лимиты в NotchClip. Файлы настроек сохраняются с резервной копией.")
            }

            Section {
                LabeledContent("Статус") {
                    Text(claudeStatusText).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                HStack {
                    Spacer()
                    Button("Обновить сейчас") { usage.refreshNow() }
                }
            } header: {
                Text("Лимиты Claude")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshStatus() }
        .sheet(item: $state.output) { item in
            HookOutputSheet(item: item)
        }
    }

    private var claudeStatusText: String {
        if case .ok = usage.claudeStatus, usage.snapshot.claude != nil { return "Данные получены" }
        return usage.claudeStatus.hint
    }

    private func refreshStatus() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude = try? String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8)
        let codex = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        state.claudeHooks = AgentHookStatus.claudeInstalled(settingsText: claude)
        state.codexHooks = AgentHookStatus.codexInstalled(configText: codex)
    }

    private func runSetup(uninstall: Bool) {
        state.running = true
        Task {
            let text = await Task.detached { HookScript.run(uninstall ? ["--uninstall"] : []) }.value
            state.running = false
            refreshStatus()
            state.output = ScriptOutput(title: uninstall ? "Удаление хуков" : "Установка хуков", text: text)
        }
    }
}

/// Запуск скрипта установки, который лежит в Resources приложения. Вызывается вне главного потока.
enum HookScript {
    static let timeout: TimeInterval = 60
    /// Скрипт вызывает jq, codex и другие утилиты из Homebrew, а GUI-приложению PATH не передаётся.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func run(_ arguments: [String]) -> String {
        guard let script = Bundle.main.url(forResource: "setup-agent-hooks", withExtension: "sh", subdirectory: "agent-hooks") else {
            return "Скрипт установки не найден в приложении."
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return "Не удалось запустить скрипт: \(error.localizedDescription)"
        }

        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            process.waitUntilExit()
            return "Скрипт не ответил за \(Int(timeout)) с и был остановлен."
        }
        let finished = readDone.wait(timeout: .now() + 5) == .success
        let text = finished
            ? String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return text.isEmpty ? "Готово, изменений нет." : text
    }
}

private struct HookOutputSheet: View {
    let item: ScriptOutput
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.headline)
            ScrollView {
                Text(item.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Состояние вкладок (без @State: макрос не доступен в CLT)

@MainActor final class GeneralTabState: ObservableObject {
    @Published var showCustomDelays = false
    @Published var loginStatus: SMAppService.Status = .notRegistered
    @Published var loginError: String?
    @Published var confirmReset = false
}

@MainActor final class PanelTabState: ObservableObject {
    @Published var showCustomSize = false
}

@MainActor final class BufferTabState: ObservableObject {
    @Published var confirmClear = false
}

@MainActor final class AgentsTabState: ObservableObject {
    @Published var claudeHooks = false
    @Published var codexHooks = false
    @Published var output: ScriptOutput?
    @Published var running = false
}
