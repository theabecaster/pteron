import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import os

/// What the hinge reports (`UIHinge`, iOS 27.1+).
struct HingeReading: Equatable {
    /// The angle in degrees. Nil with no hinge: an iPhone that doesn't fold, an older iOS, or a
    /// view outside a hierarchy that gets hinge updates.
    var degrees: Double?
    /// `UIHinge.Status` in words, for the log only. Nothing decides on it.
    var status = "none"
}

/// Asks the window the probe sits in. Held by the view that owns the observer.
@MainActor
final class HingeProbeRef {
    fileprivate(set) weak var view: UIView?

    /// The window covers its whole screen, within a point: full screen, not Split View and not a
    /// resized window. False with no window.
    var fillsScreen: Bool {
        guard let window = view?.window, let screen = window.windowScene?.screen else { return false }
        return Self.fills(window: window.bounds.size, screen: screen.bounds.size)
    }

    nonisolated static func fills(window: CGSize, screen: CGSize) -> Bool {
        abs(window.width - screen.width) <= 1 && abs(window.height - screen.height) <= 1
    }
}

/// Reports the hinge of the window it sits in, and, while `watching`, every touch and key press
/// in that window. It draws nothing and takes no touch. The hinge is read only to tell when the
/// phone stands as a tent (`TentDetector`); layout never uses it.
struct HingeObserver: UIViewRepresentable {
    let ref: HingeProbeRef
    /// Watch the window's touches (the board is away and counts the time since the last one).
    let watching: Bool
    let onHinge: (HingeReading) -> Void
    let onTouch: () -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        ref.view = probe
        return probe
    }

    func updateUIView(_ v: Probe, context: Context) {
        v.onHinge = onHinge
        v.onTouch = onTouch
        v.watching = watching
    }

    final class Probe: UIView {
        var onHinge: (HingeReading) -> Void = { _ in }
        var onTouch: () -> Void = {}
        var watching = false { didSet { if watching != oldValue { updateWatch() } } }
        private var watch: TouchWatch?
        private var last: HingeReading?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            if #available(iOS 27.1, *) {
                // Called with the hinge as it is now, then on every change, and with no hinge
                // when the view leaves a hierarchy that has one.
                addInteraction(UIHingeInteraction { [weak self] _, update in
                    MainActor.assumeIsolated {
                        self?.report(update.hinge.map { hinge in
                            let status: String
                            switch hinge.status {
                            case .closed: status = "closed"
                            case .partiallyOpen: status = "partiallyOpen"
                            case .fullyOpen: status = "fullyOpen"
                            default: status = "unknown"
                            }
                            return HingeReading(degrees: Double(hinge.angle) * 180 / .pi, status: status)
                        } ?? HingeReading())
                    }
                })
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        private func report(_ reading: HingeReading) {
            guard reading != last else { return }
            last = reading
            let send = onHinge
            // Later: it changes SwiftUI state, and may arrive during a layout pass.
            DispatchQueue.main.async { send(reading) }
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow !== window { removeWatch() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateWatch()
        }

        private func updateWatch() {
            guard watching, let window else { return removeWatch() }
            guard watch == nil else { return }
            let w = TouchWatch()
            w.onTouch = { [weak self] in self?.onTouch() }
            window.addGestureRecognizer(w)
            watch = w
        }

        private func removeWatch() {
            guard let w = watch else { return }
            w.view?.removeGestureRecognizer(w)
            watch = nil
        }
    }
}

/// Sees every touch and key press that begins in its window and takes none: it fails at once,
/// cancels and delays nothing, and neither blocks nor is blocked by another recognizer.
final class TouchWatch: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouch: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch?()
        state = .failed
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onTouch?()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

#if DEBUG
/// `-simulateTent <degrees|off>[,<degrees|off>…]` (testing): the hinge reports these angles
/// instead of the real ones, one after the other every `-simulateTentEvery` seconds (default 10).
/// `off` is no hinge. `-simulateTent 90` goes into tent after the one-second hold.
enum TentSimulation {
    /// Nil without the argument: the real hinge is used.
    static let sequence: [Double?]? = {
        guard let raw = UserDefaults.standard.string(forKey: "simulateTent"), !raw.isEmpty else { return nil }
        return raw.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    }()

    static var interval: Double {
        let v = UserDefaults.standard.double(forKey: "simulateTentEvery")
        return v > 0 ? v : 10
    }

    /// `-boardReturnAfter <seconds>`: the board comes back that long after the last touch.
    static var returnAfter: Double? {
        let v = UserDefaults.standard.double(forKey: "boardReturnAfter")
        return v > 0 ? v : nil
    }
}

/// `-hingeLog YES` (testing): one `HINGE` line for each change of a degree or more, of the
/// hinge's status, of the fold or of tent, to check on a device what the hinge reports where.
@MainActor
enum HingeLog {
    private static let on = UserDefaults.standard.bool(forKey: "hingeLog")
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "rexduo", category: "hinge")
    private static var last = ""

    static func note(_ hinge: HingeReading, division: Division?, fills: Bool, tent: Bool) {
        guard on else { return }
        let angle = hinge.degrees.map { String(Int($0.rounded())) } ?? "none"
        let fold = division.map { $0.isActive ? "active" : "inactive" } ?? "none"
        let line = "HINGE angle=\(angle) status=\(hinge.status) division=\(fold) fills=\(fills) tent=\(tent)"
        guard line != last else { return }
        last = line
        log.notice("\(line, privacy: .public)")
    }
}
#endif
