import SwiftUI
import RexKit

/// The file browser of a pane, shown as a sheet: the folders of the pane's computer, one screen
/// per folder. In browse mode a file opens in Quick Look; in insert mode a tap writes its path
/// into the pane and closes the sheet. Styled like Settings and the sidebar, from the theme's
/// chrome.
struct PaneBrowser: View {
    @Bindable var model: BrowserModel
    let prefs: Prefs

    var body: some View {
        let theme = prefs.theme
        NavigationStack(path: $model.stack) {
            FolderScreen(model: model, folder: model.root, theme: theme, isRoot: true)
                .navigationDestination(for: String.self) { path in
                    FolderScreen(model: model, folder: model.folder(for: path), theme: theme, isRoot: false)
                }
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .task { await model.start() }
    }
}

/// What a key does in a folder's list.
enum BrowserKey: Equatable {
    case move(Int), activate, preview, parent, open, close

    /// ↑ ↓ move, Return opens or inserts, Space previews, ⌘↑ goes to the parent, ⌘↓ opens, Esc
    /// closes. Nil: not the list's key.
    static func action(_ key: KeyEquivalent, command: Bool) -> BrowserKey? {
        switch key {
        case .upArrow: return command ? .parent : .move(-1)
        case .downArrow: return command ? .open : .move(1)
        case .return: return command ? nil : .activate
        case .space: return command ? nil : .preview
        case .escape: return .close
        default: return nil
        }
    }
}

/// The lines a folder shows in place of rows, and above them.
enum BrowserCopy {
    static func problem(_ p: FolderModel.Problem, path: String, home: String, machine: String, mac: Bool) -> String {
        switch p {
        case .denied:
            let line = "Rex on \(machine) isn't allowed to read this folder."
            return mac && isProtected(path, home: home) ? line + " Give Rex access in System Settings → Privacy & Security." : line
        case .gone: return "This folder is gone."
        case .unreadable, .refused: return "Couldn't read this folder."
        case .lost: return lost(machine)
        case .unsupported: return unsupported(machine)
        }
    }

    static func unsupported(_ machine: String) -> String { Messages.updateRex(machine, to: "browse folders") }

    static func lost(_ machine: String) -> String { "The connection to \(machine) dropped. Try again when it's back." }

    /// The folders macOS keeps from programs until the user allows them.
    static func isProtected(_ path: String, home: String) -> Bool {
        guard !home.isEmpty else { return false }
        return ["Desktop", "Documents", "Downloads"].contains { name in
            let folder = DirPath.join(home, name)
            return path == folder || path.hasPrefix(folder + "/")
        }
    }

    /// The line for a pane whose program works somewhere else: where the listed files are, by
    /// the computer's display name, or "the computer" when it has none.
    static func elsewhere(_ program: String, computer: String?) -> String {
        let name = computer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "This pane is running \(program). These files are on \(name.isEmpty ? "the computer" : name)."
    }

    /// The footer of a listing that was cut short, the count with a thousands separator.
    static func truncated(_ count: Int) -> String {
        "Showing the first \(count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))). Search to find others."
    }

    static func rowLabel(_ e: DirEntry) -> String {
        var s = e.name
        if !e.isFile { s += ", folder" }
        if e.isSymlink { s += ", link" }
        return s
    }
}

private struct FolderScreen: View {
    let model: BrowserModel
    @Bindable var folder: FolderModel
    let theme: TermTheme
    let isRoot: Bool
    @FocusState private var listFocused: Bool
    @State private var slow = false

    var body: some View {
        let facts = model.facts()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines(facts), id: \.self) { line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(theme.chrome.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if showsRecents(facts) { recents }
                    // Rows are identified by their place, so a filter keystroke updates the rows
                    // on screen where they are. A row's actions use the entry it shows.
                    ForEach(0..<folder.rows.count, id: \.self) { i in
                        row(folder.rows[i], selected: folder.selection == i, facts: facts)
                    }
                    if folder.truncated, folder.phase == .listed {
                        Text(BrowserCopy.truncated(folder.received))
                            .font(.footnote)
                            .foregroundStyle(theme.chrome.secondary)
                            .padding(16)
                    }
                }
            }
            .onChange(of: folder.selection) { _, s in
                if let s { proxy.scrollTo(s) }
            }
        }
        .overlay { status(facts) }
        .background(theme.chrome.sidebar)
        .searchable(text: $folder.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter, or type a path")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { submit(facts) }
        .refreshable { if facts.canList, facts.paneOpen { await folder.load() } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { insertBar(facts) }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard let key = BrowserKey.action(press.key, command: press.modifiers.contains(.command)) else { return .ignored }
            return handle(key, facts: facts) ? .handled : .ignored
        }
        .task {
            listFocused = true
            if !isRoot, folder.loads == 0 { await folder.load() }
        }
        .task {
            // A listing that comes at once shows no spinner.
            try? await Task.sleep(for: .milliseconds(400))
            slow = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Back from the background: the folder may have changed meanwhile.
            let now = model.facts()
            if model.current === folder, now.canList, now.paneOpen, now.online { Task { await folder.load() } }
        }
        .onChange(of: facts.online) { _, online in
            if online { Task { await model.reconnected() } }
        }
        .onChange(of: facts.canList) { _, can in
            if can { Task { await model.reconnected() } }
        }
    }

    // MARK: Lines above the rows

    private func lines(_ facts: BrowserModel.Facts) -> [String] {
        var out: [String] = []
        if !facts.paneOpen {
            out.append(Messages.thisPaneClosed)
        } else if !facts.canList {
            if folder.hasListing { out.append(BrowserCopy.unsupported(model.machine)) }
        } else if folder.phase == .failed(.lost), folder.hasListing {
            out.append(BrowserCopy.lost(model.machine))
        }
        if facts.paneOpen, case .elsewhere(let program) = facts.insert {
            out.append(BrowserCopy.elsewhere(program, computer: model.computer))
        }
        return out
    }

    // MARK: Rows

    private func row(_ entry: DirEntry, selected: Bool, facts: BrowserModel.Facts) -> some View {
        let live = model.isLive(entry, facts)
        return Button { model.activate(entry, in: folder) } label: {
            FileRow(entry: entry, selected: selected, dimmed: !live, theme: theme).equatable()
        }
        .buttonStyle(.plain)
        .disabled(!live)
        .contextMenu { menu(entry, facts: facts) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BrowserCopy.rowLabel(entry))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions { menu(entry, facts: facts) }
    }

    private func path(_ entry: DirEntry) -> String { model.path(of: entry, in: folder) }

    @ViewBuilder
    private func menu(_ entry: DirEntry, facts: BrowserModel.Facts) -> some View {
        let p = path(entry)
        if entry.isFile, facts.canFetch, facts.paneOpen {
            Button { model.onPreview(p) } label: { Label("Preview", systemImage: "eye") }
        }
        if facts.insert.offered, facts.paneOpen {
            Button { model.onInsert(p) } label: { Label("Insert Path", systemImage: "text.insert") }
        }
        Button { model.onCopy(p) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        if entry.isFile, facts.canFetch, facts.paneOpen {
            Button { model.onShare(p) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            Button { model.onSave(p) } label: { Label("Save to Files…", systemImage: "folder") }
        } else if !entry.isFile, facts.canFetchFolders, facts.paneOpen {
            Button { model.onShareFolder(p) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            Button { model.onSaveFolder(p) } label: { Label("Save to Files…", systemImage: "folder") }
        }
    }

    private func showsRecents(_ facts: BrowserModel.Facts) -> Bool {
        isRoot && model.mode == .insert && folder.query.isEmpty && !model.recents.isEmpty && facts.insert.offered && facts.paneOpen
    }

    @ViewBuilder
    private var recents: some View {
        Text("Recent")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.chrome.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
        ForEach(model.recents, id: \.self) { p in
            Button { model.onInsert(p) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock").foregroundStyle(theme.chrome.secondary).frame(width: 24)
                    // As it would be written: relative to the program's folder, `~/…`, or absolute.
                    Text(PathInsert.form(p, cwd: model.cwd, home: folder.home))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
        }
        Rectangle().fill(theme.chrome.divider).frame(height: 1).padding(.top, 6)
    }

    // MARK: States

    @ViewBuilder
    private func status(_ facts: BrowserModel.Facts) -> some View {
        switch folder.phase {
        case .loading:
            if slow { ProgressView().controlSize(.regular).accessibilityLabel("Loading") }
        case .listed:
            if folder.rows.isEmpty, !showsRecents(facts) {
                if !folder.query.isEmpty, !DirPath.isPath(folder.query) {
                    StatusLine(glyph: "magnifyingglass", text: "No names match.", theme: theme)
                } else {
                    StatusLine(glyph: "folder", text: folder.received == 0 ? "This folder is empty." : "Only hidden files here.",
                               theme: theme, button: folder.received == 0 ? nil : ("Show Hidden Files", { model.showHidden = true }))
                }
            }
        case .failed(let problem):
            // A listing that is still on screen stays to read; the line above it says why.
            if !folder.hasListing {
                let text = BrowserCopy.problem(problem, path: folder.path, home: folder.home, machine: model.machine, mac: model.mac)
                switch problem {
                case .denied, .gone, .unreadable:
                    StatusLine(glyph: problem == .denied ? "lock" : "folder.badge.questionmark", text: text, theme: theme,
                               button: DirPath.parent(folder.path) == nil ? nil : ("Go Up", { model.goUp() }))
                case .lost, .refused:
                    StatusLine(glyph: "wifi.slash", text: text, theme: theme, button: ("Try Again", { Task { await folder.load() } }))
                case .unsupported:
                    StatusLine(glyph: "folder.badge.questionmark", text: text, theme: theme)
                }
            }
        }
    }

    // MARK: Bars

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(DirPath.parents(folder.path), id: \.self) { p in
                    Button(DirPath.display(p, home: folder.home)) { model.go(to: p) }
                }
                Button { model.go(to: "~") } label: { Label("Home", systemImage: "house") }
                Divider()
                Toggle(isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 })) {
                    Label("Show Hidden Files", systemImage: "eye")
                }
                Button { model.onCopy(folder.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                    .disabled(folder.path.isEmpty)
            } label: {
                VStack(spacing: 0) {
                    Text(folder.path.isEmpty ? "Files" : DirPath.name(folder.path))
                        .font(.headline)
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("on \(model.machine)")
                        .font(.caption)
                        .foregroundStyle(theme.chrome.tertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel("\(folder.path.isEmpty ? "Files" : DirPath.name(folder.path)), on \(model.machine)")
            .accessibilityHint("Parent folders and options")
            // ⇧⌘. shows hidden files, as in Finder.
            .background {
                Button("Show Hidden Files") { model.showHidden.toggle() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        ToolbarItem(placement: .confirmationAction) { Button("Done") { model.onClose() } }
    }

    @ViewBuilder
    private func insertBar(_ facts: BrowserModel.Facts) -> some View {
        if model.mode == .insert, facts.insert.offered, folder.hasListing {
            Button { model.onInsert(folder.path) } label: {
                Text("Insert ‘\(DirPath.name(folder.path))’")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!facts.paneOpen)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(theme.chrome.sidebar)
            .overlay(alignment: .top) { Rectangle().fill(theme.chrome.divider).frame(height: 1) }
        }
    }

    // MARK: Keys

    /// Return in the filter: a path goes there, anything else acts on the first row.
    private func submit(_ facts: BrowserModel.Facts) {
        let q = folder.query.trimmingCharacters(in: .whitespaces)
        if DirPath.isPath(q) {
            guard facts.canList, facts.paneOpen else { return }
            folder.query = ""
            model.go(to: q)
        } else if let first = folder.rows.first {
            model.activate(first, in: folder)
        }
    }

    private func handle(_ key: BrowserKey, facts: BrowserModel.Facts) -> Bool {
        switch key {
        case .move(let d):
            folder.move(d)
        case .activate:
            guard let e = folder.selected else { return false }
            model.activate(e, in: folder)
        case .preview:
            guard let e = folder.selected, e.isFile, facts.canFetch, facts.paneOpen else { return false }
            model.onPreview(path(e))
        case .open:
            guard let e = folder.selected, !e.isFile, facts.canList, facts.paneOpen else { return false }
            model.open(e, in: folder)
        case .parent:
            guard facts.canList, facts.paneOpen else { return false }
            model.goUp()
        case .close:
            model.onClose()
        }
        return true
    }
}

/// One entry: a symbol for its kind, its name on one line (two at accessibility sizes), a badge on
/// a link and a chevron on a folder. Equatable, so a row whose entry didn't change isn't drawn again.
private struct FileRow: View, Equatable {
    let entry: DirEntry
    let selected: Bool
    let dimmed: Bool
    let theme: TermTheme
    @Environment(\.dynamicTypeSize) private var typeSize

    nonisolated static func == (a: FileRow, b: FileRow) -> Bool {
        a.entry == b.entry && a.selected == b.selected && a.dimmed == b.dimmed && a.theme.id == b.theme.id
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: FileGlyph.symbol(for: entry))
                .foregroundStyle(entry.isFile ? theme.chrome.secondary : theme.accent)
                .frame(width: 24)
                .overlay(alignment: .bottomTrailing) {
                    if entry.isSymlink {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.fg)
                            .offset(x: 4, y: 3)
                    }
                }
            Text(entry.name)
                .font(.body)
                .foregroundStyle(theme.fg)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !entry.isFile {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.chrome.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .opacity(dimmed ? 0.45 : 1)
        .background(selected ? theme.chrome.rowSelected : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.chrome.divider).frame(height: 1).padding(.leading, 52) }
        .contentShape(Rectangle())
    }
}

/// A folder's one line when it has no rows: a glyph, a sentence, at most one button.
private struct StatusLine: View {
    let glyph: String
    let text: String
    let theme: TermTheme
    var button: (title: String, action: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: glyph).font(.title2).foregroundStyle(theme.chrome.tertiary).accessibilityHidden(true)
            Text(text).font(.callout).foregroundStyle(theme.chrome.secondary).multilineTextAlignment(.center)
            if let button {
                Button(button.title, action: button.action).buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
