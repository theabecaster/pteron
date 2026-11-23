import SwiftUI

/// Every agent, in a sheet, for a layout without the sidebar: the sidebar's own `AgentsList`, so
/// the rows, their order, their swipe actions and the empty state are the Agents mode's. A tap on
/// an agent opens its pane and closes the sheet. Shown by `AppModel.showAgents()`.
struct AgentsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs

    var body: some View {
        let theme = prefs.theme
        NavigationStack {
            AgentsList(theme: theme, onSelect: { _ in Self.picked(model) })
                .foregroundStyle(theme.fg)
                .navigationTitle("Agents")
                .navigationBarTitleDisplayMode(.inline)
                .settingsBar(theme)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { model.agentsShown = false } }
                }
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    /// An agent was opened: the sheet goes, so its pane shows.
    static func picked(_ model: AppModel) {
        model.agentsShown = false
    }
}
