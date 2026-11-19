import Foundation

/// The chord text a keymap binds to an action, as a menu shows it beside the item (`⌘F`).
///
/// It comes from the pane's server keymap, never from a fixed list: a key the user's init.lua
/// gave to something else shows nothing, and an action with no key shows nothing. Read it only in
/// leaf views, so a keymap change redraws the row and nothing around it.
enum KeyLabel {
    /// The first chord that runs `action` in `bindings`: bound to it, and the binding a press of
    /// that key would run. Nil when no key runs it.
    static func `for`(action: String, in bindings: [KeyBinding]) -> String? {
        var decided = Set<KeyChord>()
        for b in bindings where !decided.contains(b.chord) {
            // The first binding on a key that the app can perform is the one the key runs.
            guard AppAction.resolve(b.action, b.args) != nil else { continue }
            decided.insert(b.chord)
            if b.action == action { return text(b.chord) }
        }
        return nil
    }

    @MainActor
    static func `for`(action: String, in keymap: KeymapStore?) -> String? {
        `for`(action: action, in: keymap?.bindings ?? KeyDefaults.resolved)
    }

    /// `shift+cmd+g` as `⇧⌘G`, in Apple's order: ⌃ ⌥ ⇧ ⌘.
    static func text(_ c: KeyChord) -> String {
        var s = ""
        if c.mods.contains(.ctrl) { s += "⌃" }
        if c.mods.contains(.alt) { s += "⌥" }
        if c.mods.contains(.shift) { s += "⇧" }
        if c.mods.contains(.cmd) { s += "⌘" }
        var key = c.key
        if c.isPhysical, let name = KeyInput.name(forCode: String(key.dropFirst().dropLast())) { key = name }
        switch key {
        case "enter": s += "↩"
        case "tab": s += "⇥"
        case "escape": s += "⎋"
        case "space": s += "Space"
        case "backspace": s += "⌫"
        case "delete": s += "⌦"
        case "left": s += "←"
        case "right": s += "→"
        case "up": s += "↑"
        case "down": s += "↓"
        case "home": s += "↖"
        case "end": s += "↘"
        case "pageup": s += "⇞"
        case "pagedown": s += "⇟"
        default: s += key.uppercased()
        }
        return s
    }
}
