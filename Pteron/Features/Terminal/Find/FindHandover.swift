import Foundation

/// How the find field takes the keyboard while it shows (paths A, B and E). One switch, so a bad
/// report from a device can flip it in one line (docs/terminal.md, Find).
///
/// - `accessory` (shipped, spike S1): the find bar replaces the key bar in the keyboard's
///   accessory slot, at its height, and its field takes the keyboard there.
/// - `spacer` (the fallback): the field in the pane's floating bar takes the keyboard on every
///   path, with an empty accessory of the key bar's height (`FindSpacer`) where the key bar was,
///   so no key bar key can act on the shell and the keyboard keeps its frame.
enum FindHandover: Equatable, CustomStringConvertible {
    case accessory, spacer

    /// The switch.
    static let shipped = FindHandover.accessory

    /// The menu-route fallback: the accessory field carries the keymap's app commands itself, in
    /// case the app menu's shortcuts don't reach a field in the keyboard's window. Off: they run
    /// through `AppShortcutCommands` like any app shortcut.
    static let fieldCarriesCommandsShipped = false

    #if DEBUG
    /// `-findHandover spacer` and `-findCarriesCommands YES` (Debug builds) try the fallbacks.
    /// `-findHandover nil` is spike S1's other variant: the accessory field's own accessory is nil
    /// (Messages-style); it lost the keyboard in the simulator.
    static let current: FindHandover = UserDefaults.standard.string(forKey: "findHandover") == "spacer" ? .spacer : shipped
    static let fieldAccessoryNil = UserDefaults.standard.string(forKey: "findHandover") == "nil"
    static let fieldCarriesCommands = UserDefaults.standard.object(forKey: "findCarriesCommands") != nil
        ? UserDefaults.standard.bool(forKey: "findCarriesCommands") : fieldCarriesCommandsShipped
    #else
    static let current = shipped
    static let fieldAccessoryNil = false
    static let fieldCarriesCommands = fieldCarriesCommandsShipped
    #endif

    var description: String { self == .accessory ? "accessory" : "spacer" }
}
