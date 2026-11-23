import SwiftUI
import WidgetKit

/// The watch app's extension: the agents complication, for watch faces and the Smart Stack.
@main
struct PteronWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WatchGlanceWidget()
    }
}
