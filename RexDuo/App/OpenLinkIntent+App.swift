import GlanceModel
import UIKit

extension OpenLinkIntent {
    /// The app's half of a control's intent (RexDuoWidgets/OpenLinkIntent.swift): the system has
    /// brought the app forward and runs the intent here. Opening the link's own URL sends it
    /// through `onOpenURL` like any other link, so there is one way in and nothing to inject.
    @MainActor
    func open(_ link: DeepLink) async {
        let opened = await UIApplication.shared.open(link.url)
        #if DEBUG
        // Beside `OPEN_LINK <link> run`: the system didn't hand the URL back to the app.
        if !opened { NSLog("OPEN_LINK %@ refused", link.rawValue) }
        #else
        _ = opened
        #endif
    }
}
