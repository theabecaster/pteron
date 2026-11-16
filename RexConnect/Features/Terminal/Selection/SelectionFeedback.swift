import UIKit

/// Where selection haptics go. Tests put a recorder here.
@MainActor
protocol SelectionFeedback: AnyObject {
    /// Feedback is likely soon: wake the Taptic Engine so it plays without a lag.
    func prepare()
    func play(_ haptic: SelectionHaptic)
}

/// System haptics for selection, behind the Haptics setting like `Haptic`.
///
/// | Event | Generator |
/// | --- | --- |
/// | `.start`: the long press became a selection | `UIImpactFeedbackGenerator(.medium)` |
/// | `.grab`: a handle grabbed, or a press on blank space | `UIImpactFeedbackGenerator(.light)` |
/// | `.tick`: the moving end entered another row | `UISelectionFeedbackGenerator` |
/// | `.copy`: copied to the clipboard, with the shimmer | `UINotificationFeedbackGenerator` `.success` |
///
/// The copy confirmation is the only two-beat pattern, so it can't be mistaken for the start.
@MainActor
final class SystemSelectionFeedback: SelectionFeedback {
    private let start = UIImpactFeedbackGenerator(style: .medium)
    private let grab = UIImpactFeedbackGenerator(style: .light)
    private let tick = UISelectionFeedbackGenerator()
    private let copy = UINotificationFeedbackGenerator()
    private let enabled: () -> Bool

    init(enabled: @escaping () -> Bool = { Prefs.shared.haptics }) {
        self.enabled = enabled
    }

    /// The prepared state lasts a few seconds and ends when a generator fires, so the session
    /// asks again at each step of a gesture (touch down, selection start, each tick, a grab).
    func prepare() {
        guard enabled() else { return }
        start.prepare()
        grab.prepare()
        tick.prepare()
        copy.prepare()
    }

    func play(_ haptic: SelectionHaptic) {
        guard enabled() else { return }
        switch haptic {
        case .start: start.impactOccurred()
        case .grab: grab.impactOccurred()
        case .tick: tick.selectionChanged()
        case .copy: copy.notificationOccurred(.success)
        }
    }
}
