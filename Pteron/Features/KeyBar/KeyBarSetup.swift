import Foundation

/// What the key bar's middle capsule shows, as arranged in Settings → Keyboard (docs/terminal.md,
/// Key bar). Three sections, left to right in the user's order: Primary keys, Shortcut Groups and
/// Editing keys. Each key can be shown or hidden and moved within its section. The left capsule
/// (⌘, compose, attach), the right one (the arrows, the hide key) and the pinned Return are not
/// part of it. Shift-Return is shown or hidden here, but when shown it is pinned beside Return
/// (`showsShiftReturn`), never among the scrolling keys. Stored in `Prefs` as JSON with a version. Pure, so it is tested.
struct KeyBarSetup: Codable, Equatable {
    /// 2 added Shift-Return (`addingShiftReturn`).
    static let currentVersion = 2
    var version = Self.currentVersion

    enum Section: String, Codable, CaseIterable, Identifiable {
        case primary, groups, editing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .primary: "Primary"
            case .groups: "Shortcut Groups"
            case .editing: "Editing"
            }
        }
    }

    /// A built-in key of the Primary or Editing section: its bar key (`KeyBar.bytes(for:)`).
    struct Key: Codable, Equatable, Identifiable {
        var id: String
        var shown: Bool
    }

    var sections: [Section]
    var primary: [Key]
    var editing: [Key]
    var groups: [ShortcutGroup]

    // MARK: Built in

    /// Primary's keys in their first order. Shift-Tab and Command start hidden.
    static let primaryKeys = ["esc", "ctrl", "alt", "shift", "tab", "shift-tab", "cmd"]
    /// Editing's keys in their first order. The arrow keys are here for layouts that had them.
    /// Shift-Return is listed last: shown, it is pinned beside Return, so its place in the list
    /// means nothing.
    static let editingKeys = ["backspace", "paste", "delete", "home", "end", "pgup", "pgdn", "up", "down", "left", "right",
                              shiftReturn]
    /// Shift-Return's bar key.
    static let shiftReturn = "shift-enter"

    /// The first setup: for agents, as Rex's own key bar is. esc, ctrl, option, shift and tab,
    /// the Characters ~ | / - as keys, then Backspace and Paste; Shift-Return shown, pinned
    /// beside Return.
    static let standard = KeyBarSetup(
        sections: Section.allCases,
        primary: primaryKeys.map { Key(id: $0, shown: !["shift-tab", "cmd"].contains($0)) },
        editing: editingKeys.map { Key(id: $0, shown: ["backspace", "paste", shiftReturn].contains($0)) },
        groups: ShortcutGroup.Kind.allCases.map(ShortcutGroup.standard))

    /// Layout as Reset Layout leaves it: the sections and their keys as they first were. The
    /// groups' shortcuts stay as they are; Reset Shortcut Groups restores those.
    func resetLayout() -> KeyBarSetup {
        var s = Self.standard
        s.groups = groups.map { g in
            var g = g
            let first = ShortcutGroup.standard(g.id)
            g.shown = first.shown
            g.expanded = first.expanded
            return g
        }
        return s
    }

    /// The group of `kind`.
    func group(_ kind: ShortcutGroup.Kind) -> ShortcutGroup? { groups.first { $0.id == kind } }

    /// Changes the group of `kind` in place.
    mutating func update(_ kind: ShortcutGroup.Kind, _ body: (inout ShortcutGroup) -> Void) {
        guard let i = groups.firstIndex(where: { $0.id == kind }) else { return }
        body(&groups[i])
    }

    // MARK: What the bar shows

    /// One item of the middle capsule.
    enum Item: Equatable {
        /// A built-in key, by its bar key.
        case key(String)
        /// A group's shortcut, shown as its own key (the group is expanded).
        case shortcut(Shortcut)
        /// A group's button, which opens a menu of its turned-on shortcuts.
        case group(ShortcutGroup)
    }

    /// The middle capsule's items, left to right. A shown group with no shortcut turned on shows
    /// nothing.
    var items: [Item] {
        sections.flatMap { section -> [Item] in
            switch section {
            case .primary: return primary.filter(\.shown).map { .key($0.id) }
            case .editing: return editing.filter { $0.shown && $0.id != Self.shiftReturn }.map { .key($0.id) }
            case .groups:
                return groups.filter(\.shown).flatMap { g -> [Item] in
                    let on = g.items.filter(\.on)
                    if on.isEmpty { return [] }
                    return g.expanded ? on.map { .shortcut($0) } : [.group(g)]
                }
            }
        }
    }

    /// Shift-Return is shown: the bar pins it right before Return, past the hairline, where it
    /// never scrolls away.
    var showsShiftReturn: Bool { editing.contains { $0.id == Self.shiftReturn && $0.shown } }

    /// Reorders Editing's keys as Layout lists them, Shift-Return left out: it is pinned, so it
    /// keeps no place among them and stays at the list's end.
    mutating func reorderEditing(_ body: (inout [Key]) -> Void) {
        var keys = editing.filter { $0.id != Self.shiftReturn }
        body(&keys)
        editing = keys + editing.filter { $0.id == Self.shiftReturn }
    }

    /// The setup as stored, read back: a setup from before version 2 gets Shift-Return
    /// (`addingShiftReturn`); a section, key or group a newer or older version lacks is added at
    /// its end, hidden, and one this version doesn't know is dropped, so every built-in key is
    /// always listed once.
    func normalized() -> KeyBarSetup {
        var s = version < 2 ? addingShiftReturn() : self
        s.version = Self.currentVersion
        var sections: [Section] = []
        for x in s.sections where !sections.contains(x) { sections.append(x) }
        s.sections = sections + Section.allCases.filter { !sections.contains($0) }
        func fill(_ keys: [Key], _ all: [String]) -> [Key] {
            var out: [Key] = []
            for k in keys where all.contains(k.id) && !out.contains(where: { $0.id == k.id }) { out.append(k) }
            return out + all.filter { id in !out.contains { $0.id == id } }.map { Key(id: $0, shown: false) }
        }
        s.primary = fill(s.primary, Self.primaryKeys)
        s.editing = fill(s.editing, Self.editingKeys)
        var groups: [ShortcutGroup] = []
        for g in s.groups where !groups.contains(where: { $0.id == g.id }) { groups.append(g) }
        s.groups = groups + ShortcutGroup.Kind.allCases.filter { k in !groups.contains { $0.id == k } }.map {
            var g = ShortcutGroup.standard($0)
            g.shown = false
            return g
        }
        return s
    }

    /// Version 2's step: Shift-Return shown, at Editing's end. Nothing else changes. It runs on a
    /// setup stored before version 2 and on a layout carried over from before the setup, never
    /// again, so a user who hides the key keeps it hidden.
    func addingShiftReturn() -> KeyBarSetup {
        var s = self
        s.editing.removeAll { $0.id == Self.shiftReturn }
        s.editing.append(Key(id: Self.shiftReturn, shown: true))
        return s
    }

    // MARK: Before the setup

    /// The setup a key list of the layouts before it stands for (`KeyBarLayout`, or a list the
    /// removed key bar editor saved): the same keys, each in its section. The arrows key, attach
    /// and Return have their own places now and leave the list. Keys keep their order within a
    /// section, and the sections are in the order they first appear. A character or control key
    /// no group has becomes a shortcut of its own, so nothing is lost. Shift-Return is added as for
    /// any setup from before it (`addingShiftReturn`).
    static func migrating(_ keys: [String]) -> KeyBarSetup {
        var s = standard
        for i in s.primary.indices { s.primary[i].shown = false }
        for i in s.editing.indices { s.editing[i].shown = false }
        for i in s.groups.indices {
            s.groups[i].shown = false
            s.groups[i].expanded = true
            for j in s.groups[i].items.indices { s.groups[i].items[j].on = false }
        }
        var sections: [Section] = []
        var groupOrder: [ShortcutGroup.Kind] = []
        var primaryShown: [String] = [], editingShown: [String] = []
        var groupOn: [ShortcutGroup.Kind: [String]] = [:]
        for key in keys where !["arrows", "attach", "enter", "hide"].contains(key) {
            let section: Section
            if primaryKeys.contains(key) {
                section = .primary
                if !primaryShown.contains(key) { primaryShown.append(key) }
            } else if editingKeys.contains(key) {
                section = .editing
                if !editingShown.contains(key) { editingShown.append(key) }
            } else {
                section = .groups
                let shortcut = ShortcutGroup.builtIn(barKey: key) ?? Shortcut.custom(barKey: key)
                let kind = ShortcutGroup.kind(of: shortcut)
                if !groupOrder.contains(kind) { groupOrder.append(kind) }
                s.update(kind) { g in
                    if !g.items.contains(where: { $0.id == shortcut.id }) { g.items.append(shortcut) }
                }
                if !(groupOn[kind] ?? []).contains(shortcut.id) { groupOn[kind, default: []].append(shortcut.id) }
            }
            if !sections.contains(section) { sections.append(section) }
        }
        s.sections = sections + Section.allCases.filter { !sections.contains($0) }
        func order(_ list: [Key], shown: [String]) -> [Key] {
            shown.map { Key(id: $0, shown: true) } + list.filter { !shown.contains($0.id) }
        }
        s.primary = order(s.primary, shown: primaryShown)
        s.editing = order(s.editing, shown: editingShown)
        for (kind, on) in groupOn {
            s.update(kind) { g in
                g.shown = true
                let first = on.compactMap { id in g.items.first { $0.id == id } }.map { item in
                    var item = item
                    item.on = true
                    return item
                }
                g.items = first + g.items.filter { !on.contains($0.id) }
            }
        }
        s.groups = groupOrder.compactMap { s.group($0) } + s.groups.filter { !groupOrder.contains($0.id) }
        return s.addingShiftReturn()
    }
}

/// A group of shortcuts: Characters, Shortcuts (control keys) or Function Keys. Shown in the key
/// bar it is one button with a menu of its turned-on shortcuts; expanded, each of those is a key.
struct ShortcutGroup: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case characters, shortcuts, functionKeys
        var id: String { rawValue }
        var title: String {
            switch self {
            case .characters: "Characters"
            case .shortcuts: "Shortcuts"
            case .functionKeys: "Function Keys"
            }
        }
        /// The group's button in the key bar and its row in Settings.
        var symbol: String {
            switch self {
            case .characters: "character.textbox"
            case .shortcuts: "control"
            case .functionKeys: "fn"
            }
        }
    }

    var id: Kind
    /// Show in Key Bar.
    var shown: Bool
    /// Expand Group: each turned-on shortcut is its own key.
    var expanded: Bool
    var items: [Shortcut]

    var title: String { id.title }

    /// The group as it first is. Characters is shown and expanded with ~ | / -; Shortcuts and
    /// Function Keys are not shown, with all their shortcuts on.
    static func standard(_ kind: Kind) -> ShortcutGroup {
        switch kind {
        case .characters:
            let on: Set<String> = ["~", "|", "/", "-"]
            return ShortcutGroup(id: kind, shown: true, expanded: true,
                                 items: characters.map { c in Shortcut(id: c, label: c, send: .text(c), on: on.contains(c)) })
        case .shortcuts:
            return ShortcutGroup(id: kind, shown: false, expanded: false, items: controls.map { letter, name in
                Shortcut(id: "ctrl-" + letter, label: "^" + letter.uppercased(), name: name,
                         send: .key(KeyStroke(key: letter, ctrl: true)), on: true)
            })
        case .functionKeys:
            return ShortcutGroup(id: kind, shown: false, expanded: false, items: (1...12).map { n in
                Shortcut(id: "f\(n)", label: "F\(n)", send: .key(KeyStroke(key: "f\(n)")), on: true)
            })
        }
    }

    /// Characters, in their first order. 1, 2 and 3 answer an agent's numbered menus.
    static let characters = ["~", "|", "/", "-", "\\", "_", "$", "*", ".", "..", "?", "&", ":", "1", "2", "3"]
    /// Shortcuts: the control keys a shell, an editor or an agent uses most, with what they do.
    static let controls: [(String, String)] = [
        ("c", "Interrupt"), ("d", "End of Input"), ("z", "Suspend"), ("l", "Clear Screen"), ("r", "Search History"),
        ("a", "Start of Line"), ("e", "End of Line"), ("u", "Delete Line"), ("w", "Delete Word"), ("k", "Delete to End"),
    ]

    /// Restores the group's shortcuts as they first were; whether it shows and is expanded stays.
    func reset() -> ShortcutGroup {
        var g = Self.standard(id)
        g.shown = shown
        g.expanded = expanded
        return g
    }

    /// The built-in shortcut a key of the layouts before groups stands for.
    static func builtIn(barKey: String) -> Shortcut? {
        Kind.allCases.lazy.compactMap { standard($0).items.first { $0.id == barKey } }.first
    }

    /// The group a shortcut belongs in: control keys in Shortcuts, function keys in Function
    /// Keys, the rest in Characters.
    static func kind(of s: Shortcut) -> Kind {
        if case .key(let k) = s.send {
            if k.key.count > 1, k.key.hasPrefix("f"), Int(k.key.dropFirst()) != nil, !k.ctrl, !k.alt, !k.shift {
                return .functionKeys
            }
            return .shortcuts
        }
        return .characters
    }
}

/// One shortcut of a group: what its key shows and what it sends.
struct Shortcut: Codable, Equatable, Identifiable {
    /// A built-in shortcut's bar key ("~", "ctrl-c", "f1"); "custom:" and a UUID for one the user
    /// added.
    var id: String
    /// What the key shows.
    var label: String
    /// What it does, for Settings and VoiceOver; nil: the label says it.
    var name: String?
    var send: Send
    var on: Bool

    enum Send: Codable, Equatable {
        /// Text typed as it is, newlines included.
        case text(String)
        /// A key with modifiers.
        case key(KeyStroke)
    }

    init(id: String, label: String, name: String? = nil, send: Send, on: Bool) {
        self.id = id
        self.label = label
        self.name = name
        self.send = send
        self.on = on
    }

    var isCustom: Bool { id.hasPrefix("custom:") }

    /// A shortcut the user adds.
    static func custom(label: String, send: Send) -> Shortcut {
        Shortcut(id: "custom:" + UUID().uuidString, label: label, send: send, on: true)
    }

    /// A key of the layouts before groups that no built-in shortcut stands for: a control key
    /// ("ctrl-o") or text. Its id is the key, so migrating the same list twice gives the same.
    static func custom(barKey key: String) -> Shortcut {
        if key.hasPrefix("ctrl-"), key.count == 6 {
            let letter = String(key.suffix(1))
            return Shortcut(id: "custom:" + key, label: "^" + letter.uppercased(),
                            send: .key(KeyStroke(key: letter, ctrl: true)), on: true)
        }
        if key.count > 1, key.hasPrefix("f"), let n = Int(key.dropFirst()) {
            return Shortcut(id: "custom:" + key, label: "F\(n)", send: .key(KeyStroke(key: key)), on: true)
        }
        return Shortcut(id: "custom:" + key, label: key, send: .text(key), on: true)
    }

    /// The bar key that sends the same as this shortcut, so it goes through the bar's own path
    /// with its modifiers and cmd (`KeyBar.fire`): a character, a control letter or a function
    /// key. Nil for longer text and other keys, which send their bytes.
    var barKey: String? {
        switch send {
        case .text(let t):
            return t.count == 1 && t != "\n" && t != "\r" && t != "\t" ? t : nil
        case .key(let k):
            if k.ctrl, !k.alt, !k.shift, k.key.count == 1, let c = k.key.first, c.isASCII, c.isLetter {
                return "ctrl-" + k.key.lowercased()
            }
            guard !k.ctrl, !k.alt else { return nil }
            if k.shift { return k.key == "tab" ? "shift-tab" : nil }
            return KeyStroke.barKeys[k.key]
        }
    }
}

/// A key with modifiers, spelled as a key binding spells it (`KeyChord`): a named key (`escape`,
/// `tab`, `enter`, `backspace`, `delete`, `space`, the arrows, `home`, `end`, `pageup`,
/// `pagedown`, `f1`…`f12`) or one character.
struct KeyStroke: Codable, Equatable {
    var key: String
    var ctrl = false
    var alt = false
    var shift = false

    /// The named keys the shortcut editor offers, with what it calls them.
    static let named: [(key: String, title: String)] = [
        ("escape", "Escape"), ("tab", "Tab"), ("enter", "Return"), ("backspace", "Backspace"), ("delete", "Delete"),
        ("space", "Space"), ("up", "Up"), ("down", "Down"), ("left", "Left"), ("right", "Right"), ("home", "Home"),
        ("end", "End"), ("pageup", "Page Up"), ("pagedown", "Page Down"),
    ] + (1...12).map { ("f\($0)", "F\($0)") }

    /// Named keys that are bar keys too.
    static let barKeys: [String: String] = {
        var m = ["escape": "esc", "tab": "tab", "enter": "enter", "backspace": "backspace", "delete": "delete",
                 "up": "up", "down": "down", "left": "left", "right": "right", "home": "home", "end": "end",
                 "pageup": "pgup", "pagedown": "pgdn"]
        for n in 1...12 { m["f\(n)"] = "f\(n)" }
        return m
    }()

    var chord: KeyChord {
        var mods: KeyMods = []
        if ctrl { mods.insert(.ctrl) }
        if alt { mods.insert(.alt) }
        if shift { mods.insert(.shift) }
        return KeyChord(mods: mods, key: key.count == 1 ? key.lowercased() : key)
    }

    /// The bytes it sends, as a key binding's `pane.send_key` sends the same chord. Nil for a key
    /// that has none.
    var bytes: [UInt8]? {
        guard !key.isEmpty else { return nil }
        // An uppercase letter is the letter with shift.
        if key.count == 1, let c = key.first, c.isUppercase, !shift {
            var s = self
            s.shift = true
            s.key = key.lowercased()
            return s.bytes
        }
        return KeyInput.bytes(chord)
    }

    /// How a key shows it: ⌃⌥⇧ and the key, as a Mac menu spells a shortcut.
    var label: String {
        let mods = (ctrl ? "⌃" : "") + (alt ? "⌥" : "") + (shift ? "⇧" : "")
        let name = Self.named.first { $0.key == key }?.title ?? key.uppercased()
        return mods + name
    }
}

/// The key bar's layouts before `KeyBarSetup`. Kept to carry a stored layout over to the setup
/// with the same keys (`Prefs.migrate`).
enum KeyBarLayout: String, CaseIterable {
    case agents, shell, vim

    /// The keys each layout showed, scrolling ones first, then the pinned attach and Return.
    var keys: [String] {
        switch self {
        case .agents:
            return ["esc", "shift-tab", "tab", "/", "arrows", "up", "down", "ctrl-c", "1", "2", "3", "ctrl", "cmd",
                    "paste", "attach", "enter"]
        case .shell:
            return ["esc", "tab", "shift-tab", "ctrl", "alt", "cmd", "arrows", "up", "down", "left", "right", "ctrl-r",
                    "ctrl-c", "|", "~", "/", "-", "paste", "attach", "enter"]
        case .vim:
            return ["esc", ":", "ctrl", "cmd", "arrows", "/", "ctrl-d", "ctrl-u", "ctrl-r", "ctrl-w", "pgup", "pgdn",
                    "$", "~", "paste", "attach", "enter"]
        }
    }

    /// The keys the removed key bar editor saved for this layout (before the attach and cmd keys).
    var storedKeys: [String] {
        switch self {
        case .agents:
            return ["esc", "shift-tab", "tab", "arrows", "up", "down", "enter", "ctrl-c", "1", "2", "3", "ctrl", "paste"]
        case .shell:
            return ["esc", "tab", "ctrl", "alt", "arrows", "up", "down", "left", "right", "ctrl-r", "ctrl-c",
                    "|", "~", "/", "-", "paste"]
        case .vim:
            return ["esc", ":", "ctrl", "arrows", "/", "ctrl-d", "ctrl-u", "ctrl-r", "ctrl-w", "pgup", "pgdn",
                    "$", "~", "paste"]
        }
    }

    /// The layout a key list saved by the removed editor stands for, nil for an edited one: its
    /// `storedKeys`, or its keys with or without the attach key and Return anywhere among them.
    static func matching(stored keys: [String]) -> KeyBarLayout? {
        let pinned = ["attach", "enter"]
        let scrolling = keys.filter { !pinned.contains($0) }
        return allCases.first { $0.storedKeys == keys || $0.keys.filter { !pinned.contains($0) } == scrolling }
    }
}
