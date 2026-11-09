import SwiftUI
import AppKit
import ServiceManagement
import ApplicationServices

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
            FocusSettingsTab(timer: timer, shield: delegate.focusShield)
                .tabItem { Label("Фокус", systemImage: "timer") }
            AgentsSettingsTab(usage: usage)
                .tabItem { Label("Агенты", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 460)
    }
}

/// Строка-заголовок раскрывающегося блока. Кнопка на всю строку: DisclosureGroup внутри Form на macOS не реагирует на клики по заголовку.
private func disclosureRow(_ title: String, isExpanded: Binding<Bool>) -> some View {
    Button {
        isExpanded.wrappedValue.toggle()
    } label: {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: 0.15), value: isExpanded.wrappedValue)
}

// MARK: - Общие

private struct GeneralSettingsTab: View {
    @ObservedObject var delegate: AppDelegate
    @AppStorage("hoverEnabled") private var hoverEnabled = true
    @AppStorage("shortcut") private var shortcut = 0
    @AppStorage("thoughtShortcut") private var thoughtShortcut = 0
    @AppStorage(IslandSettings.hoverMusicActionKey) private var musicHoverRaw = MusicHoverAction.openBuffer.rawValue
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
                Picker("Быстрая мысль", selection: $thoughtShortcut) {
                    Text("⌥ Space").tag(0)
                    Text("⌃ ⌥ Space").tag(1)
                    Text("⌘ ⇧ T").tag(2)
                }.onChange(of: thoughtShortcut) { _ in delegate.registerThoughtShortcut() }
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
                disclosureRow("Свои значения", isExpanded: $state.showCustomDelays)
                if state.showCustomDelays {
                    delayStepper("Задержка открытия", value: $openDelay, range: 0...0.8)
                    delayStepper("Задержка закрытия", value: $closeDelay, range: 0...1.5)
                }
                Picker("При наведении во время музыки", selection: musicHoverAction) {
                    Text("Открывать буфер").tag(MusicHoverAction.openBuffer)
                    Text("Открывать мини-плеер").tag(MusicHoverAction.openMiniPlayer)
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

    private var musicHoverAction: Binding<MusicHoverAction> {
        Binding(get: { MusicHoverAction(rawValue: musicHoverRaw) ?? .openBuffer }, set: { musicHoverRaw = $0.rawValue })
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

/// Пресеты акцентного цвета (системные цвета macOS).
struct AccentPreset: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }

    static let all: [AccentPreset] = [
        AccentPreset(name: "Оранжевый", hex: "#FF9F0A"),
        AccentPreset(name: "Синий", hex: "#0A84FF"),
        AccentPreset(name: "Зелёный", hex: "#30D158"),
        AccentPreset(name: "Розовый", hex: "#FF375F"),
        AccentPreset(name: "Фиолетовый", hex: "#BF5AF2"),
    ]
}

private struct PanelSettingsTab: View {
    @ObservedObject var delegate: AppDelegate
    @AppStorage("panelWidth") private var panelWidth = 620.0
    @AppStorage("panelHeight") private var panelHeight = 500.0
    @AppStorage("animationDuration") private var animationDuration = 0.30
    @AppStorage("animationBounce") private var animationBounce = 0.12
    @AppStorage(IslandSettings.focusKey) private var liveFocus = true
    @AppStorage(IslandSettings.agentsKey) private var liveAgents = true
    @AppStorage("liveActivityMusic") private var liveMusic = true
    @AppStorage("shelfRetentionDays") private var shelfDays = 7
    @StateObject private var state = PanelTabState()
    @AppStorage(AppearanceSettings.accentKey) private var accentHex = AppearanceSettings.accentDefaultHex
    @AppStorage(AppearanceSettings.musicColorKey) private var musicMode = AppearanceSettings.musicColorDefault
    @AppStorage(AppearanceSettings.musicCustomKey) private var musicCustomHex = AppearanceSettings.accentDefaultHex

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
                disclosureRow("Свой размер", isExpanded: $state.showCustomSize)
                if state.showCustomSize {
                    LabeledContent("Ширина") {
                        HStack(spacing: 8) {
                            Text("\(Int(panelWidth)) пт").monospacedDigit()
                            Stepper("Ширина", value: widthBinding, in: PanelSizeRange.width, step: PanelSizeRange.step).labelsHidden()
                        }
                    }
                    LabeledContent("Высота") {
                        HStack(spacing: 8) {
                            Text("\(Int(panelHeight)) пт").monospacedDigit()
                            Stepper("Высота", value: heightBinding, in: PanelSizeRange.height, step: PanelSizeRange.step).labelsHidden()
                        }
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
                LabeledContent("Акцентный цвет") {
                    HStack(spacing: 8) {
                        ForEach(AccentPreset.all) { preset in
                            Button { accentHex = preset.hex } label: {
                                Circle()
                                    .fill(Color(hex: preset.hex))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(isSelectedAccent(preset.hex) ? 0.8 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(preset.name)
                        }
                        ColorPicker("Свой", selection: hexBinding($accentHex), supportsOpacity: false)
                    }
                }
                LabeledContent("Цвет музыки") {
                    HStack(spacing: 8) {
                        Picker("Цвет музыки", selection: $musicMode) {
                            Text("Как обложка").tag(MusicColorMode.artwork.rawValue)
                            Text("Акцентный").tag(MusicColorMode.accent.rawValue)
                            Text("Свой").tag(MusicColorMode.custom.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                        if musicMode == MusicColorMode.custom.rawValue {
                            ColorPicker("Свой цвет музыки", selection: hexBinding($musicCustomHex), supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }
            } header: {
                Text("Оформление")
            } footer: {
                Text("Акцент задаёт кольцо и таймер фокуса, индикаторы живой активности. Цвет музыки задаёт эквалайзер и прогресс мини-плеера.")
            }

            Section {
                Toggle("Таймер в чёлке", isOn: $liveFocus)
                Toggle("Агенты в чёлке", isOn: $liveAgents)
                Toggle("Музыка в чёлке", isOn: $liveMusic)
                Stepper("Полка: хранить \(shelfDays) дн.", value: $shelfDays, in: 1...365)
            } header: {
                Text("Живая активность")
            }
        }
        .formStyle(.grouped)
    }

    private func isSelectedAccent(_ hex: String) -> Bool {
        accentHex.caseInsensitiveCompare(hex) == .orderedSame
    }

    /// Связка ColorPicker с hex-строкой в UserDefaults.
    private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: hex.wrappedValue) },
            set: { color in
                if let rgb = RGB8(nsColor: NSColor(color)) { hex.wrappedValue = rgb.hex }
            }
        )
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
    @AppStorage("screenshotsToHistory") private var screenshotsToHistory = true
    @AppStorage("screenshotsMoveEnabled") private var screenshotsMove = true
    @AppStorage("recognizeImageText") private var recognizeText = true
    @StateObject private var state = BufferTabState()

    var body: some View {
        Form {
            Section {
                Toggle("Сохранять фото и файлы в Загрузки", isOn: $saveToDownloads)
                Toggle("Скриншоты в историю", isOn: $screenshotsToHistory)
                Toggle("Перемещать скриншоты", isOn: $screenshotsMove)
                Toggle("Распознавать текст", isOn: $recognizeText)
            }
            Section {
                HStack {
                    Text("Полный доступ к диску: \(state.hasFullDisk ? "есть" : "нет")")
                    Spacer()
                    Button("Открыть настройки") { NSWorkspace.shared.open(ClipboardStore.fullDiskAccessURL) }
                }
            } footer: {
                Text("Нужен, чтобы копировать медиа из других приложений, например Telegram.")
            }
            Section {
                Button("Очистить историю…", role: .destructive) { state.confirmClear = true }
            } footer: {
                Text("История хранится локально на этом Mac, без шифрования.")
            }
        }
        .formStyle(.grouped)
        .onAppear { state.hasFullDisk = ClipboardStore.hasFullDiskAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.hasFullDisk = ClipboardStore.hasFullDiskAccess()
        }
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
    @ObservedObject var shield: FocusShield
    @StateObject private var shieldUI = ShieldSettingsState()
    @AppStorage(FocusTimer.soundEnabledKey) private var sound = true
    @AppStorage("focusShieldDND") private var shieldDND = true
    @AppStorage("focusShieldSummary") private var shieldSummary = true

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
            Section("Щит фокуса") {
                Toggle("Не беспокоить", isOn: $shieldDND)
                Text("Создай в Быстрых командах «NotchClip Фокус вкл» и «NotchClip Фокус выкл» для включения и выключения режима «Не беспокоить».").font(.caption).foregroundStyle(.secondary)
                Button("Открыть Быстрые команды") { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Shortcuts.app"), configuration: NSWorkspace.OpenConfiguration()) }
                Text(shield.dndStatus ?? "Статус команд проверяется при запуске фокуса").font(.caption).foregroundStyle(.secondary)
                Toggle("Сводка сообщений на перерыве", isOn: $shieldSummary)
                HStack {
                    Text(AXIsProcessTrusted() ? "Универсальный доступ: разрешён" : "Универсальный доступ: не разрешён")
                    Button("Разрешить") { shield.enableSummaryAccess() }
                }
                Menu("Добавить приложение") {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier != nil && $0.activationPolicy == .regular }, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") { addBlockedApp(app.bundleIdentifier ?? "") }
                    }
                }
                ForEach(shieldUI.apps, id: \.self) { app in
                    HStack { Text(app); Spacer(); Button("Удалить") { shieldUI.apps.removeAll { $0 == app }; saveShieldLists() } }
                }
                HStack {
                    TextField("Домен сайта", text: $shieldUI.site)
                    Button("Добавить") {
                        if let domain = FocusShieldRules.normalizeDomain(shieldUI.site), !shieldUI.sites.contains(domain) { shieldUI.sites.append(domain); saveShieldLists() }
                        shieldUI.site = ""
                    }
                }
                ForEach(shieldUI.sites, id: \.self) { site in
                    HStack { Text(site); Spacer(); Button("Удалить") { shieldUI.sites.removeAll { $0 == site }; saveShieldLists() } }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            shieldUI.apps = FocusShieldSettings.apps(.standard)
            shieldUI.sites = FocusShieldSettings.sites(.standard)
        }
    }
    private func addBlockedApp(_ app: String) {
        guard !app.isEmpty, !shieldUI.apps.contains(app) else { return }
        shieldUI.apps.append(app); saveShieldLists()
    }
    private func saveShieldLists() {
        UserDefaults.standard.set(shieldUI.apps, forKey: FocusShieldSettings.appsKey)
        UserDefaults.standard.set(shieldUI.sites, forKey: FocusShieldSettings.sitesKey)
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
    @AppStorage("assistantVaultPath") private var vaultPath = ""
    @StateObject private var state = AgentsTabState()

    var body: some View {
        Form {
            Section("Ассистент") {
                LabeledContent("Хранилище") { Text(vaultPath.isEmpty ? ThoughtCapture.defaultVaultPath : vaultPath).lineLimit(1) }
                Button("Выбрать папку…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { vaultPath = url.path }
                }
                LabeledContent("Claude CLI") {
                    Text(state.claudeExecutableFound ? "Найден" : "Не найден")
                }
            }
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
        .onAppear {
            refreshStatus()
            state.claudeExecutableFound = (try? ThoughtProcessor(vault: URL(fileURLWithPath: "/"), dataDirectory: NotchClipDataLocation.directory).resolveExecutable()) != nil
        }
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
    @Published var hasFullDisk = false
}

@MainActor final class AgentsTabState: ObservableObject {
    @Published var claudeExecutableFound = false
    @Published var claudeHooks = false
    @Published var codexHooks = false
    @Published var output: ScriptOutput?
    @Published var running = false
}

@MainActor final class ShieldSettingsState: ObservableObject {
    @Published var apps: [String] = []
    @Published var sites: [String] = []
    @Published var site = ""
}
