import SwiftUI
import UIKit

/// A small Rexie beside the tab's title while its server is waking up (`ServerConnection.waking`):
/// back from the background, the connection is being made again and the screen shows what it had.
/// It appears only after `delay`, so the usual quick reconnect shows nothing, then breathes until
/// the connection is back. It is the launch screen's Rexie, small: the app is waking, not broken.
///
/// Core Animation runs it in the render server, so it costs the main thread nothing per frame, and
/// it exists only while waking. With Reduce Motion it holds still.
struct WakingMark: View {
    var size: CGFloat = 13
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Most reconnects finish within this; only a longer one shows the mark.
    static let delay: CFTimeInterval = 1

    var body: some View {
        WakingMarkView(still: reduceMotion)
            .frame(width: size, height: size)
            .accessibilityLabel("Reconnecting")
    }
}

private struct WakingMarkView: UIViewRepresentable {
    let still: Bool

    func makeUIView(context: Context) -> MarkView { MarkView(still: still) }
    func updateUIView(_ uiView: MarkView, context: Context) {}

    final class MarkView: UIView {
        private let art = UIImageView(image: UIImage(named: "LaunchRexie"))

        init(still: Bool) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            art.contentMode = .scaleAspectFit
            addSubview(art)
            layer.opacity = 0
            let now = CACurrentMediaTime()
            // Appears after the delay; the model value stays 0 so a removed view leaves nothing.
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 0
            show.toValue = 1
            show.beginTime = now + WakingMark.delay
            show.duration = 0.25
            show.fillMode = .forwards
            show.isRemovedOnCompletion = false
            layer.add(show, forKey: "show")
            guard !still else { return }
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.35
            breathe.beginTime = now + WakingMark.delay
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            art.layer.add(breathe, forKey: "breathe")
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            art.frame = bounds
        }
    }
}
