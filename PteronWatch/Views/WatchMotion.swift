import SwiftUI

/// How the watch app moves (docs/glance.md, The watch, Motion): short and soft, in the app only.
/// The complications never move. Nothing repeats but one breath, on the waiting agent that has
/// waited longest and on a waiting agent's own screen.
///
/// Every animation of the watch app is in this file, and each modifier here works its motion
/// out from Reduce Motion and the wrist (`CalmRuleTests` holds the file to that):
/// - **Reduce Motion:** every movement becomes a short cross-fade, and nothing breathes.
/// - **The wrist down** (Always On dims the screen, `isLuminanceReduced`): nothing moves at all.
enum WatchMotion: Equatable {
    /// Springs, rises and the breath.
    case full
    /// Reduce Motion: cross-fades only.
    case fade
    /// The wrist down: nothing moves.
    case still

    init(reduceMotion: Bool, wristDown: Bool) {
        self = wristDown ? .still : reduceMotion ? .fade : .full
    }

    /// A delivery that changes the headline's count, its color or the rows.
    var change: Animation? {
        switch self {
        case .full: .snappy(duration: 0.4)
        case .fade: .easeInOut(duration: 0.2)
        case .still: nil
        }
    }

    /// How a changed count reads: its digits roll, or it cross-fades.
    var count: ContentTransition {
        switch self {
        case .full: .numericText()
        case .fade: .opacity
        case .still: .identity
        }
    }

    /// The list's lines the first time it shows: one after another, 45 ms apart, the first
    /// seven; the ones below come in with the seventh.
    func entrance(_ index: Int) -> Animation? {
        switch self {
        case .full: .spring(duration: 0.5, bounce: 0.12).delay(Double(min(index, 6)) * 0.045)
        case .fade: .easeOut(duration: 0.25)
        case .still: nil
        }
    }

    /// How far a line rises as it comes in. A cross-fade doesn't move.
    var rise: CGFloat { self == .full ? 10 : 0 }

    /// A part that comes in once, as its screen appears. On a screen with nothing to list,
    /// Glide glides in from the lower left, tilted, and lands, and the line under it follows.
    /// On an agent's screen, as the system slides it in, the ring springs up to size and the
    /// words rise after it.
    func arrival(_ part: WatchArrival.Part) -> Animation? {
        switch (self, part) {
        case (.full, .glide): .spring(duration: 0.9, bounce: 0.22)
        case (.full, .line): .easeOut(duration: 0.4).delay(0.3)
        case (.full, .ring): .spring(duration: 0.55, bounce: 0.3).delay(0.1)
        case (.full, .words): .spring(duration: 0.5, bounce: 0.1).delay(0.18)
        case (.fade, _): .easeOut(duration: 0.3)
        case (.still, _): nil
        }
    }

    /// Where a part starts from, as an offset, a tilt in degrees and a scale. A cross-fade
    /// doesn't move.
    func start(_ part: WatchArrival.Part) -> (x: CGFloat, y: CGFloat, tilt: Double, scale: CGFloat) {
        guard self == .full else { return (0, 0, 0, 1) }
        return switch part {
        case .glide: (-40, 18, -14, 0.82)
        case .line: (0, rise / 2, 0, 1)
        case .ring: (0, 0, 0, 0.6)
        case .words: (0, rise, 0, 1)
        }
    }

    /// The waiting agent's glow breathes. With Reduce Motion it glows still; with the wrist down
    /// it doesn't glow.
    var breathes: Bool { self == .full }
    var glows: Bool { self != .still }

    /// One breath, in or out: 1.8 s each way.
    static let breath = Animation.easeInOut(duration: 1.8)

    /// Waits out the system's own opening of the app before a screen's first entrance, which
    /// would otherwise end before anything is on the glass.
    static func settle() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
}

extension EnvironmentValues {
    /// A picture drawn outside a running app (`WatchRenderTests`), where no task runs: every
    /// part is drawn where it lands.
    @Entry var watchLanded = false
}

/// A delivery's change, animated: the list's rows, the switch between the list and a message.
struct WatchChange<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var wristDown

    func body(content: Content) -> some View {
        content.animation(WatchMotion(reduceMotion: reduceMotion, wristDown: wristDown).change, value: value)
    }
}

/// The headline's count: the digits roll to the new count.
struct WatchCount<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var wristDown

    func body(content: Content) -> some View {
        let motion = WatchMotion(reduceMotion: reduceMotion, wristDown: wristDown)
        content
            .contentTransition(motion.count)
            .animation(motion.change, value: value)
    }
}

/// A line of the list, the first time the list shows: it fades in and rises into place.
/// `entered` turns true once, when the list appears, so a line made later as the list scrolls
/// is simply there.
struct WatchEntrance: ViewModifier {
    let index: Int
    let entered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var wristDown

    func body(content: Content) -> some View {
        let motion = WatchMotion(reduceMotion: reduceMotion, wristDown: wristDown)
        let shown = entered || motion == .still
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : motion.rise)
            .animation(motion.entrance(index), value: entered)
    }
}

/// A part that comes in once, as its screen appears: Glide and its line on a screen with
/// nothing to list, the ring and the words on an agent's screen.
struct WatchArrival: ViewModifier {
    enum Part { case glide, line, ring, words }

    let part: Part
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var wristDown
    @Environment(\.watchLanded) private var drawnLanded
    @State private var landed = false

    func body(content: Content) -> some View {
        let motion = WatchMotion(reduceMotion: reduceMotion, wristDown: wristDown)
        let shown = landed || drawnLanded || motion == .still
        let from = motion.start(part)
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : from.scale)
            .rotationEffect(.degrees(shown ? 0 : from.tilt))
            .offset(x: shown ? 0 : from.x, y: shown ? 0 : from.y)
            .animation(motion.arrival(part), value: landed)
            .task {
                // Glide shows at launch, behind the system's own opening of the app; an agent's
                // screen comes in with the system's slide.
                if part == .glide || part == .line { await WatchMotion.settle() }
                landed = true
            }
    }
}

/// The soft glow around a waiting agent's ring, breathing: 1.8 s in, 1.8 s out, for as long
/// as the agent waits on screen. With Reduce Motion it is still; with the wrist down it is gone.
struct WatchBreath: ViewModifier {
    let on: Bool
    let color: Color
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var wristDown

    func body(content: Content) -> some View {
        let motion = WatchMotion(reduceMotion: reduceMotion, wristDown: wristDown)
        content.background {
            if on && motion.glows {
                if motion.breathes {
                    PhaseAnimator([false, true]) { inhale in
                        glow(inhale ? 0.7 : 0.2, scale: inhale ? 1.1 : 0.96)
                    } animation: { _ in WatchMotion.breath }
                } else {
                    glow(0.4, scale: 1)
                }
            }
        }
    }

    private func glow(_ opacity: Double, scale: CGFloat) -> some View {
        Circle()
            .stroke(color, lineWidth: max(3, diameter * 0.12))
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.14)
            .scaleEffect(scale)
            .opacity(opacity)
            .accessibilityHidden(true)
    }
}
