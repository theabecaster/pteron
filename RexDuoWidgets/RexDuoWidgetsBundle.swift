import SwiftUI
import WidgetKit

/// The app's extension for the system's glance surfaces. For now: the two controls for Control
/// Center, the Lock Screen and the Action button.
@main
struct RexDuoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        OpenControl()
        WaitingControl()
    }
}
