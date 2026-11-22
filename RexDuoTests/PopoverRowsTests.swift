import RexKit
import SwiftUI
import Testing
import UIKit
@testable import RexDuo

/// Every row of the session popover, tapped in the real root in tab mode, from the session
/// chip: what the row presents comes up once the popover has gone. This is what proves the
/// wait's signal (the popover's content leaving the screen) comes at the end of the dismissal:
/// a sheet asked for any earlier doesn't present.
@MainActor
@Suite(.serialized) struct PopoverRowsTests {
    enum Row: String, CaseIterable, Sendable {
        case settings, agents, goTo, renameSession, closeSession, add
    }

    /// One computer with sessions "work" and "play", and a computer that isn't added. No tab is
    /// on screen: the strip is there with its session chip, and no pane is mounted.
    private func model() throws -> AppModel {
        let suite = "popover-rows-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(prefs: Prefs(defaults: defaults), connect: false)
        let s = ServerConnection(config: ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"),
                                 prefs: model.prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        func view(_ id: String) -> SessionView {
            SessionView(["revision": 1, "session_id": id, "label": id, "active_window_id": "w-\(id)", "windows": [
                ["window_id": "w-\(id)", "label": "tab", "layers": [["kind": "tiled", "blocks": [
                    ["block_id": "b-\(id)", "creator_name": "com.superlogical.terminal"] as JSONObject,
                ]] as JSONObject]] as JSONObject,
            ]])
        }
        s.sessions = [SessionEntry(id: "work", label: "work"), SessionEntry(id: "play", label: "play")]
        s.views = ["work": view("work"), "play": view("play")]
        s.hosts = [HostEntry(id: "h1", label: "attic", endpoints: ["unix:///tmp/rex.sock"])]
        s.phase = .online
        s.synced = true
        s.agentsWereRead()
        model.prefs.navigation = .tabs
        return model
    }

    private func elements(_ window: UIWindow) -> [NSObject] {
        Hosted.accessibilityElements(in: window)
    }

    /// The topmost thing presented over the root that is on screen and isn't on its way out.
    private func top(_ window: UIWindow) -> UIViewController? {
        var top = window.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        guard let top, top !== window.rootViewController, top.viewIfLoaded?.window != nil else { return nil }
        return top
    }

    private func run(_ action: UIAccessibilityCustomAction) -> Bool {
        if let handler = action.actionHandler { return handler(action) }
        guard let target = action.target as? NSObject else { return false }
        _ = target.perform(action.selector, with: action)
        return true
    }

    /// Opens the popover from the session chip, taps `row`, and checks that what the row
    /// presents came up.
    @Test(arguments: Row.allCases)
    func aRowPresentsOnceThePopoverHasGone(row: Row) async throws {
        try #require(Hosted.setAccessibility(on: true), "the simulator's accessibility runtime")
        defer { _ = Hosted.setAccessibility(on: false) }
        let model = try model()
        let size = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first
            ?? CGSize(width: 402, height: 874)
        let window = Hosted.window(RootView().environment(model).environment(model.prefs), size: size)
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        let note = row.rawValue

        let opener = try await Hosted.eventually {
            elements(window).first {
                $0.isAccessibilityElement && $0.accessibilityLabel == "Sessions" && $0.accessibilityHint == SessionChip.hint
            }
        }
        #expect(opener.accessibilityActivate(), "\(note): the popover's opener")
        // The session popover itself: whatever is up later and isn't this one is what the row
        // presented. (A confirmation is a popover too on some screens.)
        let popover = try await Hosted.eventually { top(window) }
        #expect(popover.modalPresentationStyle == .popover, "\(note)")

        switch row {
        case .renameSession, .closeSession:
            let title = row == .renameSession ? "Rename Session…" : "Close Session"
            let action = try await Hosted.eventually {
                elements(window).lazy.compactMap { $0.accessibilityCustomActions?.first { $0.name == title } }.first
            }
            #expect(run(action), "\(note)")
        default:
            let label = [Row.settings: "Settings", .agents: "Agents", .goTo: TabAction.goTo.title, .add: "Add attic"][row] ?? ""
            let button = try await Hosted.eventually {
                elements(window).first { $0.isAccessibilityElement && $0.accessibilityLabel == label }
            }
            #expect(button.accessibilityActivate(), "\(note)")
        }

        let appeared = await Hosted.settle {
            let up = top(window)
            guard up !== popover else { return false }
            switch row {
            case .settings: return model.showSettings && up != nil
            case .agents: return model.agentsShown && up != nil
            case .goTo: return model.goTo != nil && up == nil
            case .renameSession, .closeSession: return up != nil
            case .add: return model.showPairing && up != nil
            }
        }
        let up = top(window)
        let what = up === popover ? "the popover still" : up.map { String(describing: type(of: $0)) } ?? "nothing"
        #expect(appeared, "\(note): \(what) is presented")
    }
}
