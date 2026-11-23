import Foundation
import RexKit

/// The floating-window calls: raise on tap, Minimize, Minimize All, and showing a minimized one
/// again. All go through `session.set_layer_state`; a server without it hides them
/// (`noteMissing`), and a tap on a float then only focuses it.
extension ServerConnection {
    private static var layerMethod: String { FloatArrange.layerStateMethod }

    private static func layerArgs(_ sid: String, _ layer: String, minimized: Bool) -> JSONObject {
        var p: JSONObject = ["session_id": sid, "layer_id": layer, "state": minimized ? "minimized" : "normal"]
        if !minimized { p["focus"] = true }
        return p
    }

    /// Puts a floating window in front and focuses it, showing it first if it is minimized: one
    /// `set_layer_state` with `focus`, which focuses the pane last focused there, then
    /// `focus_block` for `block` when the layer holds several panes. Sent in order in one turn.
    /// A raise that fails says nothing: the next view shows the windows as they are.
    func raiseFloat(_ sid: String, _ layer: String, focus block: String?) async {
        var calls: [(method: String, payload: JSONObject)] = [(Self.layerMethod, Self.layerArgs(sid, layer, minimized: false))]
        if let block { calls.append(("session.focus_block", ["session_id": sid, "block_id": block])) }
        let results = await control.callInOrder(calls)
        if case .failure(let e)? = results.first { noteMissing(Self.layerMethod, e) }
        refreshView(sid)
    }

    /// Minimize: the floating window goes from the screen; its panes keep running.
    func minimizeFloat(_ sid: String, _ layer: String) async {
        let method = Self.layerMethod
        await act("minimize the floating window", session: sid) {
            do {
                return try await self.control.call(method, Self.layerArgs(sid, layer, minimized: true))
            } catch {
                self.noteMissing(method, error)
                throw error
            }
        }
    }

    /// Shows a minimized floating window again, in front and focused.
    func restoreFloat(_ sid: String, _ layer: String) async {
        let method = Self.layerMethod
        await act("show the floating window", session: sid) {
            do {
                return try await self.control.call(method, Self.layerArgs(sid, layer, minimized: false))
            } catch {
                self.noteMissing(method, error)
                throw error
            }
        }
    }

    /// Minimize All: every layer given, sent in order in one turn, then one re-read and at most
    /// one notice. A call that left is never resent.
    func minimizeFloats(_ sid: String, _ layers: [String]) async {
        guard !layers.isEmpty else { return }
        let results = await control.callInOrder(layers.map { (Self.layerMethod, Self.layerArgs(sid, $0, minimized: true)) })
        var failure: Error?
        for case .failure(let e) in results {
            noteMissing(Self.layerMethod, e)
            failure = failure ?? e
        }
        refreshView(sid)
        if let failure { Notice.shared.show("Couldn't minimize the floating windows. \(reason(failure))") }
    }
}
