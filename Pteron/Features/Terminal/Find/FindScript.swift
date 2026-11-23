#if DEBUG
import UIKit

/// `-findScript '<step>;<step>…'` (Debug builds, testing; spike S1): drives find over the active pane
/// once it is live, where a script can't tap or press keys, and logs every keyboard frame change
/// with each step (`FIND_SCRIPT` in the log, and on stdout so `devicectl … --console` prints it on a
/// phone). Steps run `-findScriptEvery` seconds apart (default 1.5):
///
/// - `up`: show the software keyboard, as a tap on the pane does, even with a hardware keyboard.
/// - `hw`: the pane believes a hardware keyboard is attached (`hardwareKeyboard`), as by default.
/// - `down`: the key bar's hide key. `resign`: the terminal gives the keyboard up (down entirely).
/// - `open`: ⌘F (`client.find.open`). `menu`: "Find…" from the pane menu (no menu shows).
/// - `type:<text>`: typed into the find field that holds the keyboard.
/// - `esc`: Escape in the field. `focus`: a tap on the floating bar's field. `done`: Done.
/// - `next`, `prev`: the chevrons. `tap`: a tap on the terminal.
/// - `gate`: logs whether an app-menu shortcut (⌘T) would run now (`AppShortcutCommands`' check).
/// - `wait:<seconds>`.
///
/// Each line says who is first responder (`first=term|acc|ovl|none`), the terminal's accessory,
/// the keyboard notifications since the step before (`frames=` end frames, `hides=`), the grid and
/// whether the fit hold is on. Pass for S1: no `hides` and one unchanged end frame (or none) on the
/// hand-overs of paths A and B. Use only with a throwaway `zz-` session.
@MainActor
enum FindScript {
    private static var ran = false
    private static var frames: [CGRect] = []
    private static var hides = 0
    private static var observers: [NSObjectProtocol] = []

    static func run(on host: TerminalHost) {
        guard !ran, let script = UserDefaults.standard.string(forKey: "findScript") else { return }
        ran = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { n in
            let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            let b = (n.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect) ?? .zero
            let d = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? -1
            let local = (n.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) ?? false
            MainActor.assumeIsolated {
                frames.append(f)
                emit("FIND_SCRIPT note begin=\(Int(b.minY))+\(Int(b.height)) end=\(Int(f.minY))+\(Int(f.height)) dur=\(d) local=\(local)")
            }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hides += 1 }
        })
        let every = UserDefaults.standard.double(forKey: "findScriptEvery")
        let steps = script.split(separator: ";").map(String.init)
        Task { @MainActor [weak host] in
            try? await Task.sleep(for: .seconds(2))
            log("start", host)
            for step in steps {
                guard let host else { return }
                frames = []
                hides = 0
                await perform(step, on: host)
                try? await Task.sleep(for: .seconds(every > 0 ? every : 1.5))
                log(step, host)
            }
            log("end", host)
        }
    }

    private static func perform(_ step: String, on host: TerminalHost) async {
        let (verb, arg) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
        let holding = host.findFieldHoldingKeyboard
        let field: FindField? = holding.flatMap { place in
            place == .accessory ? host.finder?.accessory.content.field : host.finder?.overlay.content.field
        }
        switch verb {
        case "up":
            host.hardwareKeyboard = { false }
            host.focusKeyboard()
        case "hw":
            host.hardwareKeyboard = { true }
        case "down":
            host.hideKeyboard()
        case "resign":
            _ = host.term.resignFirstResponder()
        case "open":
            host.performFind(.open)
        case "menu":
            host.findFromMenu()
        case "type":
            field?.insertText(arg)
        case "esc":
            if let field { host.findFieldEscape(field) }
        case "focus":
            if let bar = host.finder?.overlay.content { _ = host.findBarShouldEdit(bar) }
        case "done":
            if let bar = host.finder?.overlay.content { host.findBarDone(bar) }
        case "next":
            host.performFind(.next)
        case "prev":
            host.performFind(.previous)
        case "tap":
            _ = host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: host.term.isFirstResponder && !host.keyboardQuiet,
                         hadSelection: false)
        case "gate":
            let holder = KeyboardFocusPolicy.holder(UIResponder.rexCurrentFirstResponder(), own: nil)
            let runs = KeyboardFocusPolicy.runsAppShortcut(holder: holder, sheetUp: KeyboardFocusPolicy.sheetUp(in: host.window))
            emit("FIND_SCRIPT gate holder=\(holder) runs=\(runs ? 1 : 0)")
        case "wait":
            try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
        default:
            break
        }
    }

    private static func log(_ step: String, _ host: TerminalHost?) {
        guard let host else { return }
        chain(host)
        let first: String
        switch host.findFieldHoldingKeyboard {
        case .accessory: first = "acc"
        case .overlay: first = "ovl"
        case nil: first = host.term.isFirstResponder ? (host.keyboardQuiet ? "term-quiet" : "term") : "none"
        }
        let accessory: String
        switch host.term.inputAccessoryView {
        case is KeyBar: accessory = "keybar"
        case is FindAccessoryBar: accessory = "findbar"
        case nil: accessory = "nil"
        default: accessory = "other"
        }
        let list = frames.map { "\(Int($0.minY))+\(Int($0.height))" }.joined(separator: ",")
        let r = host.term.findResult
        emit("FIND_SCRIPT \(step) first=\(first) termAccessory=\(accessory) frames=[\(list)] hides=\(hides) grid=\(host.term.cols)x\(host.term.rows) "
             + "pane=\(Int(host.bounds.height)) hold=\(host.findHold.map { "\($0.cols)x\($0.rows)" } ?? "-") "
             + "open=\(host.findOpen ? 1 : 0) count=\(FindQuery.count(r) ?? "-") overlay=\(host.finder.map { $0.overlay.isHidden ? 0 : 1 } ?? 0) "
             + "handover=\(FindHandover.fieldAccessoryNil ? "nil" : FindHandover.current.description) "
             + "hostY=\(Int(host.convert(CGPoint.zero, to: nil).y)) safe=\(host.window.map { "\(Int($0.safeAreaInsets.top)),\(Int($0.safeAreaInsets.bottom)),\(Int($0.safeAreaInsets.right))" } ?? "-") key=\(host.window?.isKeyWindow == true ? 1 : 0) "
             + "keybar=\(barGeometry(host.keyBar)) findbar=\(host.finder.map { barGeometry($0.accessory) } ?? "-")")
    }

    /// A bar's top and height in screen points, or "off" when it isn't in a window.
    private static func barGeometry(_ v: UIView) -> String {
        guard let w = v.window else { return "off" }
        let r = v.convert(v.bounds, to: w.screen.coordinateSpace)
        return "\(Int(r.minY))+\(Int(r.height))"
    }

    /// The host's ancestors whose frame in the window changed since the last call.
    private static var lastChain: [String] = []
    static func chain(_ host: TerminalHost) {
        var out: [String] = []
        var v: UIView? = host
        while let cur = v, let w = cur.window {
            let r = cur.convert(cur.bounds, to: w)
            out.append("\(type(of: cur)):\(Int(r.minY))+\(Int(r.height)) sa=\(Int(cur.safeAreaInsets.top)),\(Int(cur.safeAreaInsets.bottom))")
            v = cur.superview
        }
        if out != lastChain {
            for (i, line) in out.enumerated() where i >= lastChain.count || lastChain[i] != line { emit("FIND_SCRIPT chain \(i) \(line)") }
            lastChain = out
        }
    }

    private static func emit(_ line: String) {
        NSLog("%@", line)
        print(line)
        fflush(stdout)
    }
}
#endif
