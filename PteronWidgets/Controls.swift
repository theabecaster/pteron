import AppIntents
import GlanceModel
import SwiftUI
import WidgetKit

/// Every word and symbol the controls show. Changing a glyph is one line here; the name is
/// `Brand.appName`.
enum ControlText {
    /// The app's name, as the Open control's label and inside the other strings.
    static let appName = Brand.appName
    static let jump = "Jump to Waiting"

    /// The symbols, custom ones in this extension's asset catalog: the mascot, and the mascot
    /// with a mark for an agent that waits.
    static let openSymbol = "mark.open"
    static let jumpSymbol = "mark.waiting"

    // Shown in the controls gallery.
    static var openName: LocalizedStringResource { "Open \(appName)" }
    static var openDescription: LocalizedStringResource { "Opens \(appName)." }
    static var jumpName: LocalizedStringResource { "\(jump)" }
    static var jumpDescription: LocalizedStringResource { "Opens \(appName) at the agent that has waited longest for you." }
}

/// Brings the app forward. Nothing else changes.
struct OpenControl: ControlWidget {
    static let kind = "dev.abrahamgonzalez.rexduo.control.open"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenLinkIntent(link: .open)) {
                Label(ControlText.appName, image: ControlText.openSymbol)
            }
        }
        .displayName(ControlText.openName)
        .description(ControlText.openDescription)
    }
}

/// Opens the app at the agent that has waited longest (`AppModel.openWaiting`).
struct WaitingControl: ControlWidget {
    static let kind = "dev.abrahamgonzalez.rexduo.control.waiting"
    /// The default theme's "blocked" color, #c69026. The system adapts it to light and dark.
    static let tint = Color(red: 0xc6 / 255.0, green: 0x90 / 255.0, blue: 0x26 / 255.0)

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenLinkIntent(link: .waiting)) {
                Label(ControlText.jump, image: ControlText.jumpSymbol)
            }
            .tint(Self.tint)
        }
        .displayName(ControlText.jumpName)
        .description(ControlText.jumpDescription)
    }
}

// MARK: - What a control runs

extension OpenLinkIntent {
    /// Nothing: the system runs the intent in the app, never here (`openAppWhenRun`). The app's
    /// own `open(_:)` does the work.
    @MainActor
    func open(_ link: DeepLink) async {}
}
