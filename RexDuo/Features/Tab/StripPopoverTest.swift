#if DEBUG
import SwiftUI

/// `-stripPopover chip` (testing, tab mode): open the session popover from the session chip,
/// once, `-stripPopoverAfter` seconds (default 3) after the chip shows. `-stripRow <name>` then
/// taps a row of it, `-stripRowAfter` seconds (default 2) after the popover shows, exactly as a
/// finger does: through the popover's own handler, so the row closes the popover and what it
/// presents waits for the dismissal.
///
/// Rows: `settings`, `agents`, `goTo` (the footer), `renameSession` and
/// `closeSession` (the menu of the session on screen), `add` (the first computer that isn't
/// added), `ports` (the first heading with a ports globe). A row the popover doesn't have does
/// nothing.
enum StripPopoverTest {
    enum Row: String, CaseIterable {
        case settings, agents, goTo, renameSession, closeSession, add, ports
    }

    @MainActor private static var opened = false
    @MainActor private static var tapped = false

    private static func seconds(_ key: String, default value: Double) -> Duration {
        let v = UserDefaults.standard.double(forKey: key)
        return .milliseconds(Int((v > 0 ? v : value) * 1000))
    }

    static var openDelay: Duration { seconds("stripPopoverAfter", default: 3) }
    static var rowDelay: Duration { seconds("stripRowAfter", default: 2) }

    /// Whether the chip's popover was asked for, before the wait.
    static var asks: Bool {
        UserDefaults.standard.string(forKey: "stripPopover") == "chip"
    }

    /// Whether the chip opens its popover now: true once per launch, when asked for.
    @MainActor
    static func takeOpen() -> Bool {
        guard !opened, asks else { return false }
        opened = true
        return true
    }

    /// The row to tap, once per launch.
    @MainActor
    static func takeRow() -> Row? {
        guard !tapped, let row = UserDefaults.standard.string(forKey: "stripRow").flatMap(Row.init(rawValue:)) else { return nil }
        tapped = true
        return row
    }

    /// What a tap on `row` reports in `popover` as it is now. Nil when the popover has no such
    /// row.
    static func action(_ row: Row, in popover: SessionPopover) -> SessionPopover.Action? {
        func footer(_ action: SessionPopover.Action) -> SessionPopover.Action? {
            popover.rows.contains { if case .footer(let f) = $0 { f.action == action } else { false } } ? action : nil
        }
        // The session on screen, else the first with a menu.
        let sessions = popover.rows.compactMap { if case .session(let s) = $0 { s } else { nil } }
        let menu = (sessions.first { $0.current && !$0.menu.isEmpty } ?? sessions.first { !$0.menu.isEmpty })?.menu ?? []
        switch row {
        case .settings: return footer(.settings)
        case .agents: return footer(.agents)
        case .goTo: return footer(.goTo)
        case .renameSession: return menu.first { if case .renameSession = $0 { true } else { false } }
        case .closeSession: return menu.first { if case .closeSession = $0 { true } else { false } }
        case .add: return popover.rows.lazy.compactMap { if case .host(let h) = $0 { SessionPopover.Action.add(h) } else { nil } }.first
        case .ports: return popover.rows.lazy.compactMap { if case .machine(let m) = $0 { m.ports } else { nil } }.first
        }
    }
}

/// Opens the session chip's popover binding for `-stripPopover`.
struct StripPopoverOpens: ViewModifier {
    @Binding var open: Bool

    func body(content: Content) -> some View {
        content.task {
            guard StripPopoverTest.asks else { return }
            try? await Task.sleep(for: StripPopoverTest.openDelay)
            // Taken after the wait: a control replaced meanwhile leaves the turn to its successor.
            if !Task.isCancelled, StripPopoverTest.takeOpen() { open = true }
        }
    }
}

/// `-showPorts YES` in tab mode, where no sidebar header has a ports button: the first computer
/// that connects has its ports sheet opened, once (`AppModel.showPorts`).
struct PortsSheetAtLaunch: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs

    func body(content: Content) -> some View {
        // Nothing is read without the argument.
        let asked = UserDefaults.standard.bool(forKey: "showPorts") && prefs.navigation == .tabs
        let online = asked ? model.servers.first { $0.phase.problem == nil && $0.synced }?.id : nil
        content.onChange(of: online, initial: true) { _, id in
            guard let id, PortsList.openAtLaunch() else { return }
            model.showPorts(id)
        }
    }
}
#endif
