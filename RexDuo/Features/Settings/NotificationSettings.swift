import SwiftUI

/// Settings → Notifications: the master switch in a group of its own, with its line and the
/// section's footer, and, while it is on, the computers in a group under it, one cell each.
/// What each shows and what each control does come from `PushRegistrar` (`master`, `computers`,
/// and its actions); the words are in `State/NotificationStatus.swift`. This file only lays them
/// out and holds what is on screen over them: a confirm, the details of a helper, the manual
/// steps. The matrix of states is in docs/notifications.md. In-app banners for waiting agents
/// are always on and have no setting.
struct NotificationSettingsSection: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme

    @State private var confirm: Pending?
    @State private var sheet: Shown?
    /// Counts the taps on the master switch that the model did not take, so the switch is drawn
    /// again as the model has it.
    @State private var refused = 0

    /// A confirm that is up, and what its button does.
    private struct Pending: Identifiable {
        let id = UUID()
        var copy: NotificationCopy.Confirm
        var destructive: Bool
        var action: () -> Void
    }

    /// A sheet that is up.
    private enum Shown: Identifiable {
        /// What a computer's helper says about itself; no rows when none answers.
        case details(name: String, rows: [HelperDetails.Row])
        case how

        var id: String {
            switch self {
            case .details(let name, _): "details " + name
            case .how: "how"
            }
        }
    }

    var body: some View {
        let push = model.push
        let master = push.master
        let computers = master.showsComputers ? push.computers : []
        Section {
            masterRow(master)
        } header: {
            SettingsHeader(MasterStatus.title, theme)
        } footer: {
            SettingsFooter(MasterStatus.footer, theme)
        }
        .settingsRows(theme)

        if !computers.isEmpty {
            Section {
                ForEach(Array(computers.enumerated()), id: \.element.id) { index, row in
                    ComputerNotificationRow(row: row, theme: theme,
                                            setOn: { push.setComputer(row.id, on: $0) },
                                            fix: { perform($0, row) },
                                            choose: { choose($0, row) })
                        .id(SettingsAnchor.computer(index))
                }
            } header: {
                SettingsHeader(MasterStatus.computersHeader, theme)
            }
            .settingsRows(theme)
        }
    }

    /// The master switch, with its line under it. The confirms and sheets hang off this row
    /// because it is always there; a computer's row comes and goes.
    private func masterRow(_ master: MasterStatus) -> some View {
        let push = model.push
        return VStack(alignment: .leading, spacing: 0) {
            Toggle(MasterStatus.title, isOn: Binding(get: { master.switchOn }, set: { on in
                push.setMaster(on: on)
                // While iOS has notifications turned off the tap opens iOS Settings and the
                // choice stays. The switch itself has already moved under the finger, and
                // nothing in the model changed to move it back, so it is made again.
                if master.tapOpensSettings { refused += 1 }
            }))
            .id(refused)
            .disabled(!master.switchEnabled)
            if let line = master.line {
                NotificationStatusLine(line: line, fix: master.fix, theme: theme) { _ in push.openSettings() }
            }
        }
        .id(SettingsAnchor.notifications)
        .alert(confirm?.copy.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
               presenting: confirm) { pending in
            Button(pending.copy.confirm, role: pending.destructive ? .destructive : nil) { pending.action() }
            Button(pending.copy.cancel, role: .cancel) {}
        } message: { pending in
            Text(pending.copy.message)
        }
        .sheet(item: $sheet) { shown in
            switch shown {
            case .details(let name, let rows): HelperDetailsSheet(name: name, rows: rows, theme: theme)
            case .how: ManualStepsSheet(theme: theme)
            }
        }
        #if DEBUG
        .task { await presentSimulated() }
        #endif
    }

    private func perform(_ fix: NotificationFix, _ row: ComputerRow) {
        switch fix {
        case .how:
            sheet = .how
        case .trust:
            // The confirm is for the key offered now, and its button trusts that key and no other.
            let key = model.push.offeredKey(for: row.id)
            confirm = Pending(copy: NotificationCopy.trustConfirm(name: row.name), destructive: false) {
                if let key { model.push.trust(row.id, key: key) }
            }
        default:
            model.push.fix(fix, for: row.id)
        }
    }

    private func choose(_ item: NotificationMenuItem, _ row: ComputerRow) {
        let push = model.push
        switch item {
        case .sendTest: push.sendTest(for: row.id)
        case .reinstall: push.reinstall(row.id)
        case .cancel: push.cancel(for: row.id)
        case .showDetails:
            // An install's details are its own sheet, with the installer's output.
            guard !push.showSetupDetails(for: row.id) else { return }
            Task { sheet = .details(name: row.name, rows: await push.details(for: row.id)?.rows() ?? []) }
        case .remove:
            Task {
                let copy = await push.removeConfirm(for: row.id)
                confirm = Pending(copy: copy, destructive: true) { push.removeHelper(from: row.id) }
            }
        }
    }

    #if DEBUG
    /// `-simulateNotifications confirm-remove|confirm-trust|details|how`: the screen opens with
    /// that confirm or sheet up over its first computer, as the menu or the button would put it.
    private func presentSimulated() async {
        let push = model.push
        guard let shown = push.simulatedPresentation, let row = push.computers.first else { return }
        // The Settings sheet finishes arriving first; a second presentation during it is dropped.
        try? await Task.sleep(nanoseconds: 800_000_000)
        switch shown {
        case .confirmRemove: choose(.remove, row)
        case .confirmTrust: perform(.trust, row)
        case .details: choose(.showDetails, row)
        case .how: perform(.how, row)
        }
    }
    #endif
}

extension NotificationTint {
    /// The design system's colour for a status line: the "needs you" colour of a waiting agent
    /// for a problem, the secondary text colour for information, and the row's own text colour
    /// for something the app is doing by itself.
    func color(in theme: TermTheme) -> Color {
        switch self {
        case .warning: theme.chrome.blocked
        case .secondary: theme.chrome.secondary
        case .none: theme.fg
        }
    }
}

/// One computer's cell: its name as the cell's title, the `…` button for its menu when it has
/// one, and its switch; directly under the name the one status line, with its one button, when
/// the computer has one. A cell with no line is as tall as any single-line cell of Settings. The
/// name and the switch are one line of fixed height at the top of the cell, at the same distance
/// from its top edge with a line under them or without, so neither moves when the line comes
/// and goes.
private struct ComputerNotificationRow: View {
    let row: ComputerRow
    let theme: TermTheme
    let setOn: (Bool) -> Void
    let fix: (NotificationFix) -> Void
    let choose: (NotificationMenuItem) -> Void

    var body: some View {
        let status = row.status
        VStack(alignment: .leading, spacing: 0) {
            // The switch with the name as its label, as the master switch above it, so both
            // have the same height and the same place for the switch.
            Toggle(isOn: Binding(get: { status.switchOn }, set: { setOn($0) })) {
                HStack(spacing: 2) {
                    Text(row.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !status.menu.isEmpty {
                        Menu { items(status.menu) } label: {
                            Image(systemName: "ellipsis")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(theme.chrome.secondary)
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .menuOrder(.fixed)
                        // A full-height touch target that leaves the row as tall as one without a menu.
                        .padding(.vertical, -12)
                        .accessibilityLabel("More for \(row.name)")
                    }
                }
            }
            .disabled(!status.switchEnabled)
            if let line = status.line {
                NotificationStatusLine(line: line, fix: status.fix, theme: theme, action: fix)
            }
        }
        .contextMenu { items(status.menu) }
    }

    /// The model's items, in its order. The long press and the `…` button open the same menu.
    private func items(_ menu: [NotificationMenuItem]) -> some View {
        ForEach(Array(menu.enumerated()), id: \.offset) { _, item in
            Button(item.title, role: item.isDestructive ? .destructive : nil) { choose(item) }
        }
    }
}

/// The line under a switch: a spinner while the app is working on it, the words in the line's
/// tint, and the one button, in the look of the section's inline buttons (semibold footnote in
/// the accent colour, no border). Long words wrap to a second line and no further; the button
/// keeps its size.
private struct NotificationStatusLine: View {
    let line: NotificationLine
    let fix: NotificationFix?
    let theme: TermTheme
    let action: (NotificationFix) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if line.spinner { ProgressView().controlSize(.mini) }
            Text(line.text)
                .font(.footnote)
                .foregroundStyle(line.tint.color(in: theme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // Without a button the words still end where the switch above them begins.
            Spacer(minLength: fix == nil ? 64 : 8)
            if let fix {
                Button(fix.title) { action(fix) }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.accent)
                    .fixedSize()
                    // The touch target of the section's inline buttons, without its height: the
                    // line stays directly under the name whether or not it has a button.
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                    .padding(.vertical, -8)
            }
        }
        .padding(.top, 5)
    }
}

/// "Show Details": what a computer's helper says about itself. Read-only.
private struct HelperDetailsSheet: View {
    let name: String
    let rows: [HelperDetails.Row]
    let theme: TermTheme

    var body: some View {
        SmallSettingsSheet(title: name, theme: theme) {
            if rows.isEmpty {
                Text(NotificationCopy.noDetails(name: name))
                    .foregroundStyle(theme.chrome.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    LabeledContent(row.label, value: row.value)
                }
            }
        }
    }
}

/// "How": installing the helper on the computer by hand.
private struct ManualStepsSheet: View {
    let theme: TermTheme

    var body: some View {
        SmallSettingsSheet(title: NotificationCopy.manualTitle, theme: theme) {
            ForEach(NotificationCopy.manualSteps, id: \.self) { step in
                Text(step).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A short list in the look of Settings, as a sheet that takes the lower half of the screen.
private struct SmallSettingsSheet<Rows: View>: View {
    let title: String
    let theme: TermTheme
    @ViewBuilder var rows: Rows
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsList(theme: theme) {
                Section { rows }
                    .settingsRows(theme)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The sheet opens from a list row and would take the row's text colour.
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(theme.accent) }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .presentationDetents([.medium])
    }
}
