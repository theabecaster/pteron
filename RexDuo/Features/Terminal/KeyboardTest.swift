#if DEBUG
import UIKit

/// `-keyboardTest '<step>;<step>…'` (Debug builds, testing): shows and hides the software keyboard
/// over the active pane once it is live, where a script can't tap. Steps run a second apart, and
/// each logs the pane's grid, how much of it the keyboard covers, where it is scrolled, the
/// jump-to-bottom button's state and whether the terminal is first responder, then the keyboard's
/// last reported end frame, the key bar's frame, the pane's bottom (all on screen) and the input
/// mode's language (`KEYBOARD_TEST` in the log):
///
/// - `up`: show the software keyboard, as a tap on the pane does, even with a hardware keyboard.
/// - `down`: put it away, as the key bar's hide key does.
/// - `scroll:<points>`: scroll by that much, negative into the scrollback.
/// - `drag:<points>`: the same as a drag let go there, without momentum: it ends at the pin
///   within a row of it (`GhosttyScroller.scrollViewWillEndDragging`). A real drag a row past the
///   covered rows also puts the keyboard away; this one doesn't.
/// - `type:<text>`: type it (`\n` is Return).
/// - `jump`: tap the jump-to-bottom button, as a finger does. Nothing happens while it is hidden.
/// - `wait:<seconds>`: pause.
///
/// Use only with a throwaway `zz-` session.
@MainActor
enum KeyboardTest {
    private static var ran = false
    /// The keyboard's last reported end frame, in screen coordinates.
    private static var keyboardEnd: CGRect = .null

    static func run(on host: TerminalHost) {
        guard !ran, let script = UserDefaults.standard.string(forKey: "keyboardTest") else { return }
        ran = true
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .null
                MainActor.assumeIsolated { keyboardEnd = end }
            }
        }
        let steps = script.split(separator: ";").map(String.init)
        Task { @MainActor [weak host] in
            try? await Task.sleep(for: .seconds(2))
            for step in steps {
                guard let host else { return }
                await perform(step, on: host)
                try? await Task.sleep(for: .seconds(1))
                log(step, host)
            }
        }
    }

    private static func perform(_ step: String, on host: TerminalHost) async {
        let (verb, arg) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
        switch verb {
        case "up":
            host.hardwareKeyboard = { false }
            host.focusKeyboard()
        case "down":
            host.hideKeyboard()
        case "scroll":
            let scroller = host.term.scroller
            scroller.setOffset(scroller.surface.contentOffset.y + CGFloat(Double(arg) ?? 0), animated: false)
        case "drag":
            let scroller = host.term.scroller
            let surface = scroller.surface
            scroller.scrollViewWillBeginDragging(surface)
            scroller.setOffset(surface.contentOffset.y + CGFloat(Double(arg) ?? 0), animated: false)
            var target = surface.contentOffset
            scroller.scrollViewWillEndDragging(surface, withVelocity: .zero, targetContentOffset: &target)
            scroller.setOffset(target.y, animated: false)
        case "type":
            host.term.send(txt: arg.replacingOccurrences(of: "\\n", with: "\r"))
        case "jump":
            // A hidden button takes no touch.
            if host.jumpButton.shown { host.jumpButton.sendActions(for: .touchUpInside) }
        case "wait":
            try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
        default:
            break
        }
    }

    private static func log(_ step: String, _ host: TerminalHost) {
        let s = host.term.scrollSnapshot
        NSLog("KEYBOARD_TEST %@ grid=%dx%d pane=%.0f terminal=%.0f cover=%.0f offset=%d/%d shift=%d y=%.1f/%.1f active=%d following=%d jump=%d unseen=%d first=%d",
              step, host.term.cols, host.term.rows, host.bounds.height, host.term.bounds.height, host.term.scroller.cover,
              s.offset, s.maxRow, s.fraction + s.bounce, host.term.scroller.surface.contentOffset.y, host.term.scroller.pinnedBottom,
              s.active ? 1 : 0, s.following ? 1 : 0,
              host.jumpButton.shown ? 1 : 0, host.jumpButton.unseen ? 1 : 0, host.term.isFirstResponder ? 1 : 0)
        // Where the keyboard said it is, where the key bar is and where the pane ends: with the
        // keyboard up the pane ends at or above the bar's top.
        let bar = host.keyBar
        let barFrame = bar.window.map { w in bar.convert(bar.bounds, to: w.screen.coordinateSpace) }
        let paneBottom = host.window.map { w in host.convert(host.bounds, to: w.screen.coordinateSpace).maxY } ?? -1
        NSLog("KEYBOARD_TEST %@ kb=%@ bar=%@ paneBottom=%.0f mode=%@", step, rect(keyboardEnd),
              barFrame.map(rect) ?? "none", paneBottom, host.term.textInputMode?.primaryLanguage ?? "none")
    }

    private static func rect(_ r: CGRect) -> String {
        r.isNull ? "null" : String(format: "%.0f,%.0f,%.0fx%.0f", r.minX, r.minY, r.width, r.height)
    }
}
#endif
