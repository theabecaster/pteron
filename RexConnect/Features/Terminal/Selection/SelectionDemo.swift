import UIKit

// Debug builds only: a development hook driven by launch arguments. Not in a shipped app.
#if DEBUG
/// Development: plays a selection gesture by program, through the same controller calls
/// TerminalHost makes, so a screenshot can check the loupe, the handles and the menu (touches
/// can't be injected into the simulator from a script). Works on any pane; meant for the
/// offline replay (`-replay <file> -selectionDemo <steps>`).
///
/// `-selectionDemo` takes steps separated by `;`, run `-selectionDemoStep` seconds apart
/// (default 0.7) once the pane has been on screen for `-selectionDemoDelay` seconds (default
/// 2.5). Cells are viewport cells, `col,row`:
///
/// - `press:c,r` long press there (the loupe stays up until `lift`), `move:c,r` drag, `lift`.
/// - `grab:start` or `grab:end` take a handle, `drag:c,r` move its end there, `drop`.
/// - `double:c,r` and `triple:c,r` taps. `tap:c,r` one tap. `all` Select All.
///
/// Example: `press:30,20;move:44,23;lift;grab:end;drag:50,26` ends with the loupe on a handle drag.
@MainActor
enum SelectionDemo {
    private static var started = false

    static func runIfRequested(_ controller: TerminalSelectionController) {
        let defaults = UserDefaults.standard
        guard !started, controller.handles.window != nil, let script = defaults.string(forKey: "selectionDemo"), !script.isEmpty else { return }
        started = true
        let delay = defaults.object(forKey: "selectionDemoDelay") != nil ? defaults.double(forKey: "selectionDemoDelay") : 2.5
        let pace = defaults.object(forKey: "selectionDemoStep") != nil ? defaults.double(forKey: "selectionDemoStep") : 0.7
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + pace * Double(i)) { [weak controller] in
                if let controller { run(step, on: controller) }
            }
        }
    }

    private static func run(_ step: String, on controller: TerminalSelectionController) {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let term = controller.term
        var point: CGPoint? {
            let n = argument.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard n.count == 2 else { return nil }
            let cell = term.cellSize
            return CGPoint(x: (CGFloat(n[0]) + 0.5) * cell.width, y: (CGFloat(n[1]) + 0.5) * cell.height)
        }
        switch parts[0] {
        case "press": if let point { controller.touchDown(); controller.pressBegan(at: point) }
        case "move": if let point { controller.pressMoved(to: point) }
        case "lift": controller.pressEnded(at: .zero)
        case "grab":
            let layout = controller.handles.layout
            guard let handle = argument == "start" ? layout.start : layout.end else { return }
            // Where a finger would take it: the middle of the knob.
            controller.handleBegan(at: term.convert(CGPoint(x: handle.knob.midX, y: handle.knob.midY), from: controller.handles))
        case "drag":
            if let point {
                let offset = controller.grabOffset
                controller.handleMoved(to: CGPoint(x: point.x + offset.width, y: point.y + offset.height))
            }
        case "drop": controller.handleEnded(cancelled: false)
        case "tap": if let point { _ = controller.tap(at: point, focused: term.isFirstResponder) }
        case "double": if let point { for _ in 0..<2 { _ = controller.tap(at: point, focused: term.isFirstResponder) } }
        case "triple": if let point { for _ in 0..<3 { _ = controller.tap(at: point, focused: term.isFirstResponder) } }
        case "all": controller.selectAll(showsMenu: false)
        default: NSLog("selectionDemo: unknown step %@", step)
        }
    }
}
#endif
