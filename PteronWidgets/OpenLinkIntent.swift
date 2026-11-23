import AppIntents
import GlanceModel

/// What a control runs: it opens the app and hands it a link. This file is compiled into the
/// app and into the extension, because the system finds the intent in the extension, which
/// declares the controls, and runs it in the app, which `openAppWhenRun` brings forward first
/// (after the unlock, on a locked phone).
///
/// Each target supplies `open(_:)`. The app's opens the link's URL, so a control takes the same
/// one path into the app as any other `rexduo:` link, `onOpenURL`. The extension's does nothing
/// and never runs.
///
/// The system's `OpenURLIntent` can't do this by itself: as a control's action it fails
/// ("action intent without linkAction"), and returned from an intent (`opensIntent:`) it never
/// reaches the app. Both checked on the iOS 27.2 simulator; docs/glance.md, Controls.
struct OpenLinkIntent: AppIntent {
    // Never shown: the intent stays out of Shortcuts and Spotlight.
    static let title: LocalizedStringResource = "Open Link"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    /// A `DeepLink` raw value. Anything else is `open`: the app comes forward, nothing more.
    @Parameter(title: "Link") var link: String

    init() { link = DeepLink.open.rawValue }
    init(link: DeepLink) { self.link = link.rawValue }

    /// The link the intent carries.
    var target: DeepLink { DeepLink(rawValue: link) ?? .open }

    @MainActor
    func perform() async throws -> some IntentResult {
        await open(target)
        return .result()
    }
}
