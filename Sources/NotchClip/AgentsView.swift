import SwiftUI

/// Вкладка "Агенты": лимиты Claude/Codex и список задач из AgentMonitor.
struct AgentsView: View {
    @ObservedObject var usage: UsageMonitor
    @ObservedObject var agents: AgentMonitor

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                limitsCard
                tasksSection
            }
            .padding(.vertical, 2)
        }
        .foregroundStyle(.white)
    }

    // MARK: - Лимиты

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Лимиты")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            limitRow(name: "Claude", limits: usage.snapshot.claude,
                     emptyHint: "Нет данных — запусти scripts/agent-hooks/setup-agent-hooks.sh")
            limitRow(name: "Codex", limits: usage.snapshot.codex, emptyHint: "Нет данных")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func limitRow(name: String, limits: Limits?, emptyHint: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.system(size: 13, weight: .medium))
            LimitBar(title: "5 ч", left: limits?.fiveHourLeft, reset: limits?.fiveHourReset)
            LimitBar(title: "Неделя", left: limits?.weekLeft, reset: limits?.weekReset)
            Text(limits.map { "данные от \(Self.timeFormatter.string(from: $0.updatedAt))" } ?? emptyHint)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Задачи

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Задачи")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 4)
            if agents.tasks.isEmpty {
                Text("Нет активных задач")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ForEach(agents.tasks) { task in taskRow(task) }
            }
        }
    }

    private func taskRow(_ task: AgentTask) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                sourceBadge(task.source)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.project.isEmpty ? "Без проекта" : task.project)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        statePill(task.state)
                    }
                    if !task.message.isEmpty {
                        Text(task.message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                Text(task.updatedAt, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Button { agents.dismiss(task.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Скрыть")
                .accessibilityLabel("Скрыть задачу")
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
        }
    }

    private func sourceBadge(_ source: String) -> some View {
        Text(Self.sourceName(source))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .fixedSize()
    }

    private func statePill(_ state: AgentState) -> some View {
        let (title, color) = Self.stateStyle(state)
        return HStack(spacing: 4) {
            if state == .running {
                ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 10, height: 10)
            }
            Text(title)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.18)))
        .fixedSize()
    }

    static func sourceName(_ source: String) -> String {
        switch source {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return source
        }
    }

    static func stateStyle(_ state: AgentState) -> (String, Color) {
        switch state {
        case .needsAction: return ("Ждёт тебя", .orange)
        case .running: return ("Работает", .blue)
        case .done: return ("Готово", .green)
        }
    }
}

/// Тонкая капсульная полоска оставшегося лимита. При отсутствии данных показывает "—" и не рисует полоску.
struct LimitBar: View {
    let title: String
    let left: Int?
    let reset: Date?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 52, alignment: .leading)
            if let left {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(Self.color(for: left))
                            .frame(width: geometry.size.width * CGFloat(left) / 100)
                    }
                }
                .frame(height: 5)
            } else {
                Spacer(minLength: 0)
            }
            Text(left.map { "\($0)%" } ?? "—")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
            Text(reset.map { Self.resetText($0) } ?? "")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
        }
    }

    static func color(for left: Int) -> Color {
        if left > 50 { return .green }
        if left >= 20 { return .yellow }
        return .red
    }

    private static let weekdays = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d.MM HH:mm"
        return f
    }()

    /// "сброс 14:20" сегодня, "сброс пт 23:42" в пределах недели, иначе "сброс 3.12 09:00".
    static func resetText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "сброс " + timeFormatter.string(from: date)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? Int.max
        if days > 0 && days < 7 {
            let name = weekdays[calendar.component(.weekday, from: date) - 1]
            return "сброс \(name) " + timeFormatter.string(from: date)
        }
        return "сброс " + dateFormatter.string(from: date)
    }
}
