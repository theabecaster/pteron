import SwiftUI

/// What each scene phase asks of the app, in order. `PteronApp` carries the steps out.
///
/// The phase is the only launch state the app reads. A normal launch goes
/// `background → inactive → active`; a launch iOS makes in the background (prewarming) has no
/// scene and gets no phase at all, so it takes none of these steps: no server is started and no
/// helper hears that the phone is in front.
///
/// The app doesn't count on a change of phase ever arriving: it also asks for the steps of the
/// phase its scene starts in (`initial`), and the root view starts the servers when it appears,
/// unless the app is in the background then (`appearedCounts`).
enum ScenePhases {
    enum Step: Equatable {
        /// A scene is on its way to the screen: servers may connect (`AppModel.sceneVisible`,
        /// which acts once).
        case sceneVisible
        /// The app is in front: resync, and tell the helpers.
        case foreground
        case background
    }

    /// `initial`: the phase the scene starts in, with no change before it. Starting in the
    /// background is no move to the background, so it asks for nothing.
    static func steps(for phase: ScenePhase, initial: Bool = false) -> [Step] {
        switch phase {
        case .inactive: [.sceneVisible]
        // Before the rest, in case a scene ever turns active without passing through inactive.
        case .active: [.sceneVisible, .foreground]
        case .background: initial ? [] : [.background]
        @unknown default: []
        }
    }

    /// Whether the root view appearing means a scene is on its way to the screen. Not while the
    /// app is in the background: the system also builds the scene of an app it launched there to
    /// hand it a message (an action from the watch), and that launch must start no server.
    static func appearedCounts(inBackground: Bool) -> Bool {
        !inBackground
    }
}
