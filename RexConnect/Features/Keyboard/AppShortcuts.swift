import SwiftUI
import UIKit

/// One app-wide shortcut from the keymap: a key and the `RexCommand` it runs.
struct AppShortcut: Identifiable {
    /// The chord's spelling (`cmd+/`).
    let id: String
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let command: RexCommand
}

/// The keymap's app commands as menu shortcuts.
///
/// A pane's terminal sees its keys first (`TerminalHost.handleKey`), so these run only when no
/// terminal has the keyboard: with no tab open, after the keyboard was put away, or while something
/// else is first responder. Without them every shortcut would stop working whenever the terminal
/// isn't first responder, since the terminal's host is the only responder that knows the keymap.
enum AppShortcuts {
    /// The shortcuts for a keymap: for each key with ⌘ or ⌃, the first binding Rex Connect can
    /// perform, when that is an app command. Keys bound to something a pane does (send a key, copy,
    /// scroll) need a pane and stay with the terminal.
    static func list(_ bindings: [KeyBinding]) -> [AppShortcut] {
        var decided = Set<KeyChord>()
        var taken = Set<String>()
        var out: [AppShortcut] = []
        for b in bindings where !decided.contains(b.chord) {
            guard !b.chord.mods.isDisjoint(with: [.cmd, .ctrl]) else { continue }
            guard let action = AppAction.resolve(b.action, b.args) else { continue }
            decided.insert(b.chord)
            guard case .command(let command) = action, let key = keyEquivalent(b.chord) else { continue }
            // Two spellings of one key (`cmd+1` and `cmd+[Digit1]`): the first one wins.
            let id = "\(key.character)|\(b.chord.mods.rawValue)"
            guard taken.insert(id).inserted else { continue }
            out.append(AppShortcut(id: b.chord.spelling, title: KeyActions.title(b), key: key,
                                   modifiers: modifiers(b.chord.mods), command: command))
        }
        return out
    }

    static func keyEquivalent(_ c: KeyChord) -> KeyEquivalent? {
        var k = c.key
        if c.isPhysical {
            guard let name = KeyInput.name(forCode: String(k.dropFirst().dropLast())) else { return nil }
            k = name
        }
        switch k {
        case "enter": return .return
        case "tab": return .tab
        case "escape": return .escape
        case "space": return .space
        case "backspace": return .delete
        case "delete": return .deleteForward
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default: return k.count == 1 ? KeyEquivalent(Character(k)) : nil
        }
    }

    static func modifiers(_ m: KeyMods) -> EventModifiers {
        var e: EventModifiers = []
        if m.contains(.shift) { e.insert(.shift) }
        if m.contains(.ctrl) { e.insert(.control) }
        if m.contains(.alt) { e.insert(.option) }
        if m.contains(.cmd) { e.insert(.command) }
        return e
    }
}

/// The app's menu: the keymap's app commands, and no system Settings item.
struct AppShortcutCommands: Commands {
    let model: AppModel

    var body: some Commands {
        let all = AppShortcuts.list(bindings)
        // The system's own Settings item takes ⌘, before any responder sees the key, and opens the
        // Settings app. Ours replaces it: the item must not be empty, or the system's stays and a
        // second ⌘, in the menu conflicts with it.
        CommandGroup(replacing: .appSettings) {
            let settings = all.filter { $0.command == .settings }
            if settings.isEmpty {
                Button("Settings…") { run(.settings) }
            } else {
                items(settings)
            }
        }
        CommandMenu("Rex") {
            items(all.filter { $0.command != .settings })
        }
    }

    private func items(_ list: [AppShortcut]) -> some View {
        ForEach(list) { s in
            Button(s.title) { run(s.command) }
                .keyboardShortcut(s.key, modifiers: s.modifiers)
        }
    }

    /// The keymap of the server on screen, else the first server's, else the built-in defaults.
    private var bindings: [KeyBinding] {
        (model.current?.server ?? model.servers.first)?.keymap.bindings ?? KeyDefaults.resolved
    }

    private func run(_ command: RexCommand) {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let holder = KeyboardFocusPolicy.holder(UIResponder.rexCurrentFirstResponder(), own: nil)
        guard KeyboardFocusPolicy.runsAppShortcut(holder: holder, sheetUp: KeyboardFocusPolicy.sheetUp(in: window)) else { return }
        model.perform(command)
    }
}
