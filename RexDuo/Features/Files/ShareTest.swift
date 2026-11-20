#if DEBUG
import UIKit

/// `-shareTest '<step>;<step>…'` (Debug builds, testing): drives sharing in the active pane once it
/// is live, where the simulator can't tap through the pane menu. Steps run a second apart:
///
/// - `screen`, `styledScreen`, `all`, `styledAll`: Share ▸ Plain or Styled › Screen or All Output,
///   pointing as the pane menu does (`bar:leading`, `bar:trailing` after a colon point at that edge).
/// - `selection`: select everything, then Share… from the edit menu.
/// - `cancel`: the notice's button (Cancel while a read runs).
/// - `dismiss`: put the share sheet away.
/// - `wait:<seconds>`: pause.
///
/// Each sheet logs `SHARE_ITEM <text|file> <bytes> <path or ->`. Use only with a throwaway `zz-`
/// session.
@MainActor
enum ShareTest {
    private static var ran = false

    static func run(on host: TerminalHost) {
        guard !ran, let script = UserDefaults.standard.string(forKey: "shareTest") else { return }
        ran = true
        let steps = script.split(separator: ";").map(String.init)
        Task { @MainActor [weak host] in
            try? await Task.sleep(for: .seconds(2))
            for step in steps {
                guard let host else { return }
                await perform(step, on: host)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func perform(_ step: String, on host: TerminalHost) async {
        let (verb, arg) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
        NSLog("SHARE_TEST %@", step)
        let anchor: ShareAnchor = switch arg {
        case "bar:leading": .bar(.leading)
        case "bar:trailing": .bar(.trailing)
        default: .titleBar
        }
        switch verb {
        case "screen": host.share?.share(.screen, styled: false, anchor: anchor)
        case "styledScreen": host.share?.share(.screen, styled: true, anchor: anchor)
        case "all": host.share?.share(.allOutput, styled: false, anchor: anchor)
        case "styledAll": host.share?.share(.allOutput, styled: true, anchor: anchor)
        case "selection":
            host.term.selectAllText()
            host.share?.shareSelection(at: nil) { [weak host] in host?.term.clearSelectedRange() }
        case "cancel":
            Notice.shared.runAction()
        case "dismiss":
            var top = host.window?.rootViewController
            while let next = top?.presentedViewController { top = next }
            if top is UIActivityViewController { top?.dismiss(animated: true) }
        case "wait":
            try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
        default:
            NSLog("SHARE_TEST unknown step %@", step)
        }
    }

    /// The log line for a sheet that is about to show.
    static func log(_ item: ShareItem) {
        switch item.payload {
        case .text(let s): NSLog("SHARE_ITEM text %ld -", s.utf8.count)
        case .file(let url):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
            NSLog("SHARE_ITEM file %ld %@", size, url.path)
        }
    }
}
#endif
