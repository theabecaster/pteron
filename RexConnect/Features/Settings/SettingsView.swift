import SwiftUI
import RexKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        @Bindable var p = prefs
        let theme = prefs.theme(for: scheme)
        NavigationStack {
            Form {
                Section {
                    ForEach(model.servers) { s in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(s.config.name).font(.system(size: 15, weight: .medium))
                                Spacer()
                                Text(phaseText(s.phase)).font(.system(size: 12)).foregroundStyle(theme.chrome.secondary)
                            }
                            Text(s.config.url).font(.system(size: 11)).foregroundStyle(theme.chrome.tertiary).lineLimit(1)
                        }
                        .swipeActions {
                            if p.servers.contains(where: { $0.id == s.config.id }) && p.servers.count > 1 {
                                Button(role: .destructive) {
                                    p.servers.removeAll { $0.id == s.config.id }
                                    model.rebuildServers()
                                } label: { Label("Remove", systemImage: "trash") }
                            }
                            if p.hostURLs[s.config.name] != nil {
                                Button(role: .destructive) {
                                    p.hostURLs[s.config.name] = nil
                                    model.rebuildServers()
                                } label: { Label("Remove", systemImage: "trash") }
                            }
                        }
                    }
                    TextField("Name (e.g. workdesk)", text: $newName)
                        .textInputAutocapitalization(.never)
                    TextField("https://name.your-tailnet.ts.net", text: $newURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Button("Add Server") {
                        var u = newURL.trimmingCharacters(in: .whitespaces)
                        if !u.hasPrefix("http") { u = "https://" + u }
                        p.servers.append(ServerConfig(name: newName.isEmpty ? "Rex" : newName, url: u))
                        newName = ""; newURL = ""
                        model.rebuildServers()
                    }
                    .disabled(newURL.isEmpty)
                } header: {
                    Text("Servers")
                } footer: {
                    Text("Rex Connect talks to each Rex server over its built-in Tailscale address. Turn it on for a machine with `rex server tailscale enable` there; the phone must be on the same tailnet and signed in as the same Tailscale user.")
                }

                Section("Appearance") {
                    NavigationLink {
                        ThemePicker(selection: $p.themeID)
                    } label: {
                        LabeledContent("Theme", value: ThemeStore.theme(p.themeID).name)
                    }
                    Toggle("Use a light theme in Light Mode", isOn: $p.followSystemAppearance)
                    if p.followSystemAppearance {
                        NavigationLink {
                            ThemePicker(selection: $p.lightThemeID)
                        } label: {
                            LabeledContent("Light Theme", value: ThemeStore.theme(p.lightThemeID).name)
                        }
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text(String(format: "%.1f pt", p.fontSize)).foregroundStyle(theme.chrome.secondary)
                        }
                        Slider(value: $p.fontSize, in: 6...20, step: 0.5)
                        Text("~/agents $ claude --resume")
                            .font(Font(RexFont.ui(p.fontSize)))
                            .foregroundStyle(theme.fg)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.bg))
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Sidebar Text")
                            Spacer()
                            Text("\(Int(p.sidebarTextSize)) pt").foregroundStyle(theme.chrome.secondary)
                        }
                        Slider(value: $p.sidebarTextSize, in: 11...18, step: 1)
                    }
                }

                Section {
                    Picker("Pane Size", selection: $p.sizing) {
                        ForEach(SizingMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Splits When Unfolded", selection: $p.wideLayout) {
                        ForEach(WideLayout.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Panes")
                } footer: {
                    Text(p.sizing.detail + " Unfolded, Rex Connect draws a tab's splits the way Rex lays them out.")
                }

                Section {
                    Picker("Layout", selection: Binding(
                        get: { KeyBarPreset.matching(p.keyBar)?.rawValue ?? "custom" },
                        set: { if let preset = KeyBarPreset(rawValue: $0) { p.keyBar = preset.keys } }
                    )) {
                        ForEach(KeyBarPreset.allCases) { Text($0.title).tag($0.rawValue) }
                        if KeyBarPreset.matching(p.keyBar) == nil { Text("Custom").tag("custom") }
                    }
                    NavigationLink("Edit Keys") { KeyBarEditor() }
                    Toggle("Haptics", isOn: $p.haptics)
                } header: {
                    Text("Key Bar")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.keyBar.map(KeyBarEditor.label).joined(separator: "  "))
                            .font(Font(RexFont.ui(12)))
                        Text("Hold an arrow to repeat it. Drag the ✥ key to move through menus and history. Tap ctrl or alt for the next key; double-tap to lock it.")
                    }
                }

                Section {
                    GestureRow(symbol: "hand.tap", title: "Tap", detail: "Show the keyboard")
                    GestureRow(symbol: "arrow.up.and.down", title: "Swipe up or down", detail: "Scroll")
                    GestureRow(symbol: "arrow.left.and.right", title: "Swipe left or right", detail: "Switch pane")
                    GestureRow(symbol: "arrow.up.left.and.arrow.down.right", title: "Pinch", detail: "Font size")
                    GestureRow(symbol: "text.cursor", title: "Long-press", detail: "Select and copy")
                } header: {
                    Text("Gestures")
                }

                Section("Agents") {
                    Toggle("Show agent status", isOn: $p.showAgentStatus)
                }

                NotificationSettingsSection(theme: theme)

                Section("About") {
                    LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")")
                    LabeledContent("Protocol", value: "rex.control.v1, API \(RexControl.apiRevision)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func phaseText(_ p: ServerConnection.Phase) -> String {
        switch p {
        case .online: return "Connected"
        case .connecting: return "Connecting…"
        case .idle: return "Idle"
        case .offline(let p): return OfflineCopy.short(p.kind)
        }
    }
}

struct ThemePicker: View {
    @Binding var selection: String

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(ThemeStore.all) { t in
                    Button { selection = t.id } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 0) {
                                    Text("~ ").foregroundStyle(t.ansiColor(2))
                                    Text("git ").foregroundStyle(t.fg)
                                    Text("status").foregroundStyle(t.ansiColor(4))
                                }
                                HStack(spacing: 3) {
                                    ForEach(1..<7) { i in RoundedRectangle(cornerRadius: 2).fill(t.ansiColor(i)).frame(width: 12, height: 8) }
                                }
                            }
                            .font(Font(RexFont.ui(11)))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(t.bg))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection == t.id ? t.accent : Color.gray.opacity(0.25), lineWidth: selection == t.id ? 2 : 1))
                            Text(t.name).font(.system(size: 12)).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("Theme")
    }
}

private struct GestureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 28)
                .foregroundStyle(.tint)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }
}

struct KeyBarEditor: View {
    @Environment(Prefs.self) private var prefs
    @State private var keys: [String] = []

    var body: some View {
        List {
            Section("In the bar (drag to reorder)") {
                ForEach(keys, id: \.self) { k in
                    Text(Self.label(k)).font(Font(RexFont.ui(15)))
                }
                .onMove { keys.move(fromOffsets: $0, toOffset: $1); save() }
                .onDelete { keys.remove(atOffsets: $0); save() }
            }
            Section {
                ForEach(KeyBarPreset.allCases) { preset in
                    Button { keys = preset.keys; save() } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(preset.title).foregroundStyle(.primary)
                                Spacer()
                                if keys == preset.keys { Image(systemName: "checkmark") }
                            }
                            Text(preset.keys.map(Self.label).joined(separator: "  "))
                                .font(Font(RexFont.ui(11)))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("Picking a preset replaces the keys above.")
            }
            Section("Add") {
                ForEach(Prefs.allKeys.filter { !keys.contains($0) }, id: \.self) { k in
                    Button { keys.append(k); save() } label: {
                        HStack { Text(Self.label(k)).font(Font(RexFont.ui(15))); Spacer(); Image(systemName: "plus.circle") }
                            .frame(minHeight: 32)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Key Bar")
        .onAppear { keys = prefs.keyBar }
    }

    static func label(_ k: String) -> String {
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "paste": "Paste", "enter": "⏎ Return",
                     "tab": "⇥ Tab", "shift-tab": "⇤ Shift-Tab", "arrows": "✥ Arrow Trackpad"]
        return names[k] ?? KeyBar.titles[k] ?? k
    }

    private func save() {
        prefs.keyBar = keys
    }
}
