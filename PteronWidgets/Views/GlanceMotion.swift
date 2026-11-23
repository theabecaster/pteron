import SwiftUI
import WidgetKit

/// The widget's only motion, and the one file of the widget path that may hold any
/// (`CalmRuleTests`). Each moves once, when a timeline entry changes a value, and stops:
///
/// - a count's digits roll (`numericText`) when the count changes;
/// - a tile, or the top row, is pushed up from below when its agent's state, or the agent
///   waiting longest, changes.
///
/// Nothing repeats, pulses or counts by itself. No motion with the screen dimmed (Always On)
/// or where the system draws the widget vibrant (StandBy at night, the Lock Screen), and a
/// cross-fade with Reduce Motion.
enum GlanceMotion: Equatable {
    case full
    case fade
    case still

    init(reduceMotion: Bool, luminanceReduced: Bool, mode: WidgetRenderingMode) {
        if luminanceReduced || mode == .vibrant {
            self = .still
        } else {
            self = reduceMotion ? .fade : .full
        }
    }

    /// The longest any of it runs.
    static let longest = 0.4

    var animation: Animation? {
        switch self {
        case .full: .smooth(duration: 0.4)
        case .fade: .easeInOut(duration: 0.25)
        case .still: nil
        }
    }

    var transition: AnyTransition {
        switch self {
        case .full: .push(from: .bottom)
        case .fade: .opacity
        case .still: .identity
        }
    }

    var numbers: ContentTransition {
        switch self {
        case .full: .numericText()
        case .fade: .opacity
        case .still: .identity
        }
    }
}

/// A count whose digits roll when it changes: the headline, a count of a state.
struct GlanceCountMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.widgetRenderingMode) private var mode

    func body(content: Content) -> some View {
        let motion = GlanceMotion(reduceMotion: reduceMotion, luminanceReduced: luminanceReduced, mode: mode)
        content.contentTransition(motion.numbers)
    }
}

/// A view that is replaced, pushed up from below, when `key` changes: a tile keyed by its
/// state, the top row keyed by its agent. The animation is tied to `key`, so nothing else
/// moves it.
struct GlanceSwap<Key: Hashable>: ViewModifier {
    let key: Key
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.widgetRenderingMode) private var mode

    func body(content: Content) -> some View {
        let motion = GlanceMotion(reduceMotion: reduceMotion, luminanceReduced: luminanceReduced, mode: mode)
        ZStack {
            content.id(key).transition(motion.transition)
        }
        .animation(motion.animation, value: key)
    }
}

extension View {
    func glanceCount() -> some View { modifier(GlanceCountMotion()) }
    func glanceSwap(_ key: some Hashable) -> some View { modifier(GlanceSwap(key: key)) }
}
