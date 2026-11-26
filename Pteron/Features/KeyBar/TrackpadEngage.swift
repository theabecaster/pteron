import CoreGraphics
import Foundation

/// When the key bar's trackpad key (✥) takes a drag, as the space bar's trackpad does on the iOS
/// keyboard. In the bar's own capsule, where nothing scrolls, it takes a drag in any direction at
/// once (`anyDirection`). Among scrolling keys a swipe that starts on it scrolls the bar like a
/// swipe that starts on any other key: it takes the drag after a still hold, or at once when the
/// drag starts up or down, which the bar never scrolls.
///
/// Points and times in, a decision out: `KeyCap` feeds it the touch.
struct TrackpadEngage: Equatable {
    /// A still hold this long engages.
    static let holdDelay: TimeInterval = 0.3
    /// Travel within this of the touch-down point is still; the first travel past it decides.
    /// UIKit's own slop.
    static let slop: CGFloat = 10
    /// Travel this many times as far up or down as sideways is vertical.
    static let verticalBias: CGFloat = 1.5

    enum State: Equatable {
        /// Neither held long enough nor moved past the slop yet.
        case waiting
        /// The key has the drag; arrow steps count from `anchor`.
        case engaged(anchor: CGPoint)
        /// The first travel was sideways: the bar's scroll takes the touch and the key sends nothing.
        case passed
    }

    let start: CGPoint
    let startTime: TimeInterval
    /// Nothing scrolls under the key: the first travel past the slop engages, whatever its direction.
    let anyDirection: Bool
    private(set) var state: State = .waiting
    /// Where the finger was last seen.
    private(set) var last: CGPoint

    init(start: CGPoint, at time: TimeInterval, anyDirection: Bool = false) {
        self.start = start
        startTime = time
        self.anyDirection = anyDirection
        last = start
    }

    var engaged: Bool {
        if case .engaged = state { return true }
        return false
    }

    /// The finger moved. True when this move engaged the key.
    mutating func move(to p: CGPoint, at time: TimeInterval) -> Bool {
        last = p
        guard state == .waiting else { return false }
        let dx = p.x - start.x, dy = p.y - start.y
        if hypot(dx, dy) <= Self.slop {
            // A hold whose timer hasn't run yet.
            return hold(at: time)
        }
        if anyDirection || abs(dy) > Self.verticalBias * abs(dx) {
            // Up or down from the start: steps count from where the finger went down, so the
            // first arrow comes after the same travel as it always did.
            state = .engaged(anchor: start)
            return true
        }
        state = .passed
        return false
    }

    /// The hold's time came, with the finger where it was last seen. True when it engaged the key.
    mutating func hold(at time: TimeInterval) -> Bool {
        // A millisecond early still counts: the timer and the clock round differently.
        guard state == .waiting, time - startTime >= Self.holdDelay - 0.001,
              hypot(last.x - start.x, last.y - start.y) <= Self.slop else { return false }
        // From where the finger rests, so engaging sends nothing by itself.
        state = .engaged(anchor: last)
        return true
    }
}

/// When a held repeating key (an arrow, PgUp, PgDn) stops repeating: once the finger moves more
/// than UIKit's slop from where it went down, or off the key's highlight. A thumb that rolls a
/// little keeps the repeat; one that starts to swipe stops it.
enum RepeatSlop {
    static let slop: CGFloat = 10

    static func keepsRepeating(from anchor: CGPoint, to p: CGPoint, highlighted: Bool) -> Bool {
        highlighted && hypot(p.x - anchor.x, p.y - anchor.y) <= slop
    }
}
