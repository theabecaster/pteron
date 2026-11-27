import SwiftUI

// Settings → Keyboard's key bar pages: Layout (the built-in keys and the order of the sections),
// Shortcut Groups, one page per group, and the sheet that adds a shortcut. Each change is
// written to `Prefs.keyBarSetup` at once; the key bar follows it (`KeyBarSetup`).

/// A row of the Keyboard page that opens one of its pages: a symbol, a title and what it holds.
struct KeyBarPageRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let theme: TermTheme

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.chrome.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row a tap shows or hides, with a checkmark while it is shown.
struct KeyBarCheckRow: View {
    let title: String
    var detail: String?
    var font: Font?
    let on: Bool
    let theme: TermTheme
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(font).lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(theme.chrome.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if on {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(on ? "Shown" : "Hidden")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

extension Prefs {
    /// Changes the key bar's setup in one write.
    func editKeyBar(_ body: (inout KeyBarSetup) -> Void) {
        var s = keyBarSetup
        body(&s)
        keyBarSetup = s
    }
}

/// Settings → Keyboard → Layout: Primary and Editing keys, each shown or hidden with a tap and
/// moved with a drag, then the order of the bar's three sections, and Reset Layout.
struct KeyBarLayoutPage: View {
    @Environment(Prefs.self) private var prefs
    let theme: TermTheme

    /// What the page calls each built-in key.
    static let titles: [String: String] = [
        "esc": "Escape", "ctrl": "Control", "alt": "Option", "shift": "Shift", "tab": "Tab", "shift-tab": "Shift-Tab",
        "cmd": "Command", "backspace": "Backspace", "paste": "Paste", "shift-enter": "Shift-Return", "delete": "Delete",
        "home": "Home", "end": "End", "pgup": "Page Up", "pgdn": "Page Down", "up": "Up", "down": "Down", "left": "Left",
        "right": "Right",
    ]
    /// The few keys that need a word on what they do.
    static let details: [String: String] = [
        "shift-tab": "Changes mode in an agent",
        "shift-enter": "A new line in an agent",
        "cmd": "⌘ for the next key, as on a Mac keyboard",
        "delete": "Deletes forward",
    ]

    static func title(_ id: String) -> String { titles[id] ?? KeyBar.names[id] ?? id }

    var body: some View {
        let setup = prefs.keyBarSetup
        SettingsList(theme: theme) {
            keys(.primary, setup.primary, footer: nil)
            keys(.editing, setup.editing, footer: "Tap a key to show or hide it. Drag to reorder.")
            Section {
                ForEach(setup.sections) { section in
                    Text(section.title)
                }
                .onMove { from, to in prefs.editKeyBar { $0.sections.move(fromOffsets: from, toOffset: to) } }
            } header: {
                SettingsHeader("Order", theme)
            } footer: {
                SettingsFooter("Drag to change the order of the key bar's sections, left to right.", theme)
            }
            .settingsRows(theme)

            Section {
                Button("Reset Layout") { prefs.editKeyBar { $0 = $0.resetLayout() } }
            }
            .settingsRows(theme)
        }
        .navigationTitle("Layout")
        .navigationBarTitleDisplayMode(.inline)
        .settingsBar(theme)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
    }

    private func keys(_ section: KeyBarSetup.Section, _ list: [KeyBarSetup.Key], footer: String?) -> some View {
        Section {
            ForEach(list) { key in
                KeyBarCheckRow(title: Self.title(key.id), detail: Self.details[key.id], on: key.shown, theme: theme) {
                    prefs.editKeyBar { s in
                        switch section {
                        case .primary: if let i = s.primary.firstIndex(where: { $0.id == key.id }) { s.primary[i].shown.toggle() }
                        case .editing: if let i = s.editing.firstIndex(where: { $0.id == key.id }) { s.editing[i].shown.toggle() }
                        case .groups: break
                        }
                    }
                }
            }
            .onMove { from, to in
                prefs.editKeyBar { s in
                    switch section {
                    case .primary: s.primary.move(fromOffsets: from, toOffset: to)
                    case .editing: s.editing.move(fromOffsets: from, toOffset: to)
                    case .groups: break
                    }
                }
            }
        } header: {
            SettingsHeader(section.title, theme)
        } footer: {
            if let footer { SettingsFooter(footer, theme) }
        }
        .settingsRows(theme)
    }
}

/// Settings → Keyboard → Shortcut Groups: the groups in the bar's order, each opening its page,
/// and Reset Shortcut Groups.
struct ShortcutGroupsPage: View {
    @Environment(Prefs.self) private var prefs
    let theme: TermTheme
    @State private var confirmReset = false

    static func count(_ g: ShortcutGroup) -> String {
        let on = g.items.filter(\.on).count
        return "\(on) of \(g.items.count) \(g.items.count == 1 ? "Shortcut" : "Shortcuts")"
    }

    static func status(_ g: ShortcutGroup) -> String {
        g.shown ? (g.expanded ? "Expanded" : "Shown") : ""
    }

    var body: some View {
        let setup = prefs.keyBarSetup
        SettingsList(theme: theme) {
            Section {
                ForEach(setup.groups) { g in
                    NavigationLink(value: SettingsPage.group(g.id)) {
                        HStack(spacing: 8) {
                            KeyBarPageRow(title: g.title, subtitle: Self.count(g), symbol: g.id.symbol, theme: theme)
                            Spacer(minLength: 8)
                            Text(Self.status(g))
                                .font(.caption)
                                .foregroundStyle(theme.chrome.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(g.shown ? Self.status(g) : "Hidden")
                    }
                }
                .onMove { from, to in prefs.editKeyBar { $0.groups.move(fromOffsets: from, toOffset: to) } }
            } footer: {
                SettingsFooter("A shown group is one button in the key bar that opens its shortcuts. "
                               + "Expand a group to show its shortcuts as keys instead.", theme)
            }
            .settingsRows(theme)

            Section {
                Button("Reset Shortcut Groups") { confirmReset = true }
            }
            .settingsRows(theme)
        }
        .navigationTitle("Shortcut Groups")
        .navigationBarTitleDisplayMode(.inline)
        .settingsBar(theme)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .confirmationDialog("Reset Shortcut Groups?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                prefs.editKeyBar { $0.groups = ShortcutGroup.Kind.allCases.map(ShortcutGroup.standard) }
            }
        } message: {
            Text("Every group goes back to its first shortcuts, and shortcuts you added are removed.")
        }
    }
}

/// Settings → Keyboard → Shortcut Groups → a group: Show in Key Bar, Expand Group, its
/// shortcuts with Add Shortcut, and Reset.
struct ShortcutGroupPage: View {
    @Environment(Prefs.self) private var prefs
    let kind: ShortcutGroup.Kind
    let theme: TermTheme
    @State private var adding = false
    @State private var confirmReset = false

    /// What a shortcut does, under its label: a built-in one's name, or what one the user added
    /// sends.
    static func detail(_ s: Shortcut) -> String? {
        if let name = s.name { return name }
        guard s.isCustom else { return nil }
        switch s.send {
        case .text(let t): return "Types \u{201C}" + t.replacingOccurrences(of: "\n", with: "⏎") + "\u{201D}"
        case .key(let k): return k.label
        }
    }

    var body: some View {
        let group = prefs.keyBarSetup.group(kind) ?? .standard(kind)
        SettingsList(theme: theme) {
            Section {
                Toggle("Show in Key Bar", isOn: binding(\.shown))
                Toggle(isOn: binding(\.expanded)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Expand Group")
                        Text("Show each shortcut as its own key.")
                            .font(.caption)
                            .foregroundStyle(theme.chrome.secondary)
                    }
                }
                .disabled(!group.shown)
            }
            .settingsRows(theme)

            Section {
                ForEach(group.items) { item in
                    KeyBarCheckRow(title: item.label, detail: Self.detail(item), font: Font(RexFont.ui(15)),
                                   on: item.on, theme: theme) {
                        edit { g in
                            if let i = g.items.firstIndex(where: { $0.id == item.id }) { g.items[i].on.toggle() }
                        }
                    }
                    .deleteDisabled(!item.isCustom)
                }
                .onMove { from, to in edit { $0.items.move(fromOffsets: from, toOffset: to) } }
                .onDelete { offsets in
                    edit { g in
                        let gone = Set(offsets.map { g.items[$0].id })
                        g.items.removeAll { gone.contains($0.id) && $0.isCustom }
                    }
                }
                Button { adding = true } label: { Label("Add Shortcut", systemImage: "plus") }
            } header: {
                SettingsHeader("Shortcuts", theme)
            } footer: {
                SettingsFooter("Tap a shortcut to show or hide it. Drag to reorder.", theme)
            }
            .settingsRows(theme)

            Section {
                Button("Reset \(kind.title)") {
                    if group.items.contains(where: \.isCustom) { confirmReset = true } else { reset() }
                }
            }
            .settingsRows(theme)
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .settingsBar(theme)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .sheet(isPresented: $adding) {
            AddShortcutSheet(theme: theme) { shortcut in edit { $0.items.append(shortcut) } }
        }
        .confirmationDialog("Reset \(kind.title)?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { reset() }
        } message: {
            Text("The group goes back to its first shortcuts, and shortcuts you added are removed.")
        }
    }

    private func reset() { edit { $0 = $0.reset() } }

    private func edit(_ body: (inout ShortcutGroup) -> Void) {
        prefs.editKeyBar { $0.update(kind, body) }
    }

    private func binding(_ path: WritableKeyPath<ShortcutGroup, Bool>) -> Binding<Bool> {
        Binding(get: { prefs.keyBarSetup.group(kind)?[keyPath: path] ?? false },
                set: { v in edit { $0[keyPath: path] = v } })
    }
}

/// Add Shortcut: a label, and what it sends: text exactly as written, or a key with modifiers.
struct AddShortcutSheet: View {
    let theme: TermTheme
    let add: (Shortcut) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case text, key
        var id: String { rawValue }
        var title: String { self == .text ? "Text" : "Key" }
    }

    @State private var kind = Kind.text
    @State private var label = ""
    @State private var text = ""
    /// A named key (`KeyStroke.named`), or empty for one character.
    @State private var key = "escape"
    @State private var character = ""
    @State private var ctrl = false
    @State private var alt = false
    @State private var shift = false

    private var stroke: KeyStroke? {
        let k = key.isEmpty ? character : key
        guard !k.isEmpty else { return nil }
        return KeyStroke(key: k, ctrl: ctrl, alt: alt, shift: shift)
    }

    private var send: Shortcut.Send? {
        switch kind {
        case .text: return text.isEmpty ? nil : .text(text)
        case .key: return stroke.flatMap { $0.bytes == nil ? nil : .key($0) }
        }
    }

    /// The label typed, or what the shortcut sends when none was.
    private var shownLabel: String {
        let typed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        switch kind {
        case .text: return text.replacingOccurrences(of: "\n", with: "⏎")
        case .key: return stroke?.label ?? ""
        }
    }

    var body: some View {
        NavigationStack {
            SettingsList(theme: theme) {
                Section {
                    TextField("Label", text: $label, prompt: Text(shownLabel.isEmpty ? "Label" : shownLabel))
                    Picker("Sends", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .settingsRows(theme)

                Section {
                    switch kind {
                    case .text:
                        TextField("Text", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .font(Font(RexFont.ui(15)))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    case .key:
                        Picker("Key", selection: $key) {
                            Text("Character").tag("")
                            ForEach(KeyStroke.named.indices, id: \.self) { i in
                                Text(KeyStroke.named[i].title).tag(KeyStroke.named[i].key)
                            }
                        }
                        if key.isEmpty {
                            TextField("Character", text: $character)
                                .font(Font(RexFont.ui(15)))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onChange(of: character) { _, new in
                                    if new.count > 1 { character = String(new.suffix(1)) }
                                }
                        }
                        Toggle("Control", isOn: $ctrl)
                        Toggle("Option", isOn: $alt)
                        Toggle("Shift", isOn: $shift)
                    }
                } footer: {
                    SettingsFooter(kind == .text ? "Typed exactly as written, new lines included."
                                                 : "Sent as the key pressed with these modifiers.", theme)
                }
                .settingsRows(theme)
            }
            .navigationTitle("Add Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .settingsBar(theme)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let send else { return }
                        add(.custom(label: shownLabel, send: send))
                        dismiss()
                    }
                    .disabled(send == nil)
                }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}
