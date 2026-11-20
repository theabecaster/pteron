import SwiftUI

/// "Attach ▸" in the pane menu: the attach key's rows (`PaneFiles.sections`), for a pane whose
/// keyboard is down and so has no key bar. It shows exactly where the key does
/// (`PaneFiles.showsAttachKey`), and its subtitle names the key, as Zoom Pane's names its gesture.
/// Its own view, so only it reads the server's capabilities and the pane's host: a change there
/// redraws this row, not the tab screen.
struct AttachMenuItem: View {
    let pool: TerminalHostPool?
    let key: TerminalHostPool.Key

    var body: some View {
        // The host can be made after the tab screen drew this row: its arrival draws it again.
        let _ = pool?.hostsChanged
        let files = pool?.host(for: key)?.files
        if let files, Self.shows(files) {
            Menu {
                ForEach(Array(files.sections().enumerated()), id: \.offset) { _, section in
                    if let title = section.title {
                        Section(title) { rows(section) }
                    } else {
                        Section { rows(section) }
                    }
                }
            } label: {
                Label("Attach", systemImage: "paperclip")
                // A menu's subtitle draws no symbol image: the emoji stands for the key.
                Text("or 📎 on the key bar")
            }
        }
    }

    /// Where the row shows: where the attach key does.
    static func shows(_ files: PaneFiles?) -> Bool { files?.showsAttachKey == true }

    @ViewBuilder
    private func rows(_ section: PaneFiles.Section) -> some View {
        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
            if let on = row.on {
                Toggle(isOn: Binding(get: { on }, set: { _ in row.run() })) { label(row) }
            } else {
                Button { row.run() } label: { label(row) }
            }
        }
    }

    @ViewBuilder
    private func label(_ row: PaneFiles.Row) -> some View {
        Label(row.title, systemImage: row.symbol)
        if let subtitle = row.subtitle { Text(subtitle) }
    }
}
