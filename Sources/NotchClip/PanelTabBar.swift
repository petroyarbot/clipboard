import SwiftUI

/// Сегментированный переключатель вкладок в шапке панели. Бейдж на "Агенты" — число задач, ждущих ответа.
struct PanelTabBar: View {
    @Binding var selection: PanelTab
    @ObservedObject var agents: AgentMonitor

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(showLabels: true)
            bar(showLabels: false)
        }
    }

    private func bar(showLabels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                segment(tab, showLabels: showLabels)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: Capsule())
        .fixedSize()
    }

    private func segment(_ tab: PanelTab, showLabels: Bool) -> some View {
        let selected = selection == tab
        let badge = tab == .agents ? agents.needsActionCount : 0
        return Button { selection = tab } label: {
            HStack(spacing: 4) {
                Image(systemName: tab.symbol)
                if showLabels { Text(tab.title) }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.6))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Color.clear))
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 4, y: -5)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(tab.title), ждут тебя: \(badge)" : tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(tab.title)
    }
}
