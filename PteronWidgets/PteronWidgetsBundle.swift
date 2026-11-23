import SwiftUI
import WidgetKit

/// The app's extension for the system's glance surfaces: the agents widget for the Home Screen
/// and the Lock Screen, and the two controls for Control Center, the Lock Screen and the Action
/// button.
@main
struct PteronWidgetsBundle: WidgetBundle {
    var body: some Widget {
        GlanceWidget()
        OpenControl()
        WaitingControl()
    }
}
