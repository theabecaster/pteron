import UIKit

/// The glass the app's own floating controls are made of: the key bar's capsule and hide key,
/// and a pane's jump-to-bottom button.
@MainActor
enum Glass {
    /// The keyboard's own color under its glass (iOS 27.2 simulator, sampled over plain white and
    /// over a dark terminal). Glass tinted with it reads as the same material as the keyboard.
    static let keyboardTint = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.137, blue: 0.15, alpha: 1)
            : UIColor(red: 0.89, green: 0.894, blue: 0.914, alpha: 1)
    }

    /// Liquid Glass, as the keyboard and the system's bars use. Before iOS 26 the keyboard is
    /// opaque and square, and a material stands in.
    static func makeGlass(_ view: UIVisualEffectView, keyboardTinted: Bool = true) {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            if keyboardTinted { glass.tintColor = keyboardTint }
            view.effect = glass
            view.cornerConfiguration = .capsule()
        } else {
            view.effect = UIBlurEffect(style: .systemChromeMaterial)
            view.clipsToBounds = true
        }
    }

    /// Rounds the fallback material; the glass is a capsule on its own.
    static func round(_ view: UIVisualEffectView, radius: CGFloat) {
        if view.clipsToBounds { view.layer.cornerRadius = radius }
    }
}
