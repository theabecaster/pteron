#if DEBUG
import UIKit

/// `-keyboardTest '<step>;<step>…'` (Debug builds, testing): shows and hides the software keyboard
/// over the active pane once it is live, where a script can't tap. Steps run a second apart, and
/// each logs the pane's grid, how much of it the keyboard covers, where it is scrolled, the
/// jump-to-bottom button's state and whether the terminal is first responder (`KEYBOARD_TEST` in
/// the log):
///
/// - `up`: show the software keyboard, as a tap on the pane does, even with a hardware keyboard.
/// - `down`: put it away, as the key bar's hide key does.
/// - `scroll:<points>`: scroll by that much, negative into the scrollback.
/// - `type:<text>`: type it (`\n` is Return).
/// - `jump`: tap the jump-to-bottom button, as a finger does. Nothing happens while it is hidden.
/// - `wait:<seconds>`: pause.
///
/// Use only with a throwaway `zz-` session.
@MainActor
enum KeyboardTest {
    private static var ran = false

    static func run(on host: TerminalHost) {
        guard !ran, let script = UserDefaults.standard.string(forKey: "keyboardTest") else { return }
        ran = true
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
        NSLog("KEYBOARD_TEST %@ grid=%dx%d pane=%.0f terminal=%.0f cover=%.0f offset=%d/%d shift=%d active=%d following=%d jump=%d unseen=%d first=%d",
              step, host.term.cols, host.term.rows, host.bounds.height, host.term.bounds.height, host.term.scroller.cover,
              s.offset, s.maxRow, s.fraction + s.bounce, s.active ? 1 : 0, s.following ? 1 : 0,
              host.jumpButton.shown ? 1 : 0, host.jumpButton.unseen ? 1 : 0, host.term.isFirstResponder ? 1 : 0)
    }
}
#endif
