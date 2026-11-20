import UIKit
import UniformTypeIdentifiers

/// Whether a pane takes a drag. Only a drag from another app (Photos, Files, Safari beside it in
/// Split View) is taken; the app's own drags, such as a text selection, are left to their gestures.
enum DropRule {
    static func accepts(fromThisApp: Bool, canSend: Bool, hasFiles: Bool) -> Bool {
        !fromThisApp && canSend && hasFiles
    }

    /// The types a drop can bring as files: images, movies, and items backed by a file. Text and
    /// web addresses are not files: a drag of them is refused rather than sent as a `.txt`.
    static let types: [UTType] = [.image, .movie, .fileURL]
}

/// Drops onto one pane: files dragged in from another app go to the pane's computer, as the
/// attach key sends them, and only to the pane under the finger. The pane shows a frame while a
/// drag is over it.
@MainActor
final class PaneDrop: NSObject, UIDropInteractionDelegate {
    private weak var files: PaneFiles?
    private weak var view: UIView?
    private let frame = CAShapeLayer()

    init(files: PaneFiles, view: UIView) {
        self.files = files
        self.view = view
        super.init()
        frame.fillColor = UIColor.clear.cgColor
        frame.lineWidth = 3
        frame.isHidden = true
        frame.zPosition = 1000
        view.layer.addSublayer(frame)
        view.addInteraction(UIDropInteraction(delegate: self))
    }

    private func accepts(_ session: UIDropSession) -> Bool {
        DropRule.accepts(fromThisApp: session.localDragSession != nil, canSend: files?.support.upload == true,
                         hasFiles: session.hasItemsConforming(toTypeIdentifiers: DropRule.types.map(\.identifier)))
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        accepts(session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: accepts(session) ? .copy : .forbidden)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        highlight(accepts(session))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { highlight(false) }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { highlight(false) }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        highlight(false)
        guard accepts(session) else { return }
        files?.send(providers: session.items.map(\.itemProvider), unnamed: "Dropped Image",
                    empty: "Couldn't read what was dropped.")
    }

    private func highlight(_ on: Bool) {
        guard let view else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame.strokeColor = view.tintColor.cgColor
        frame.path = UIBezierPath(roundedRect: view.bounds.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 6).cgPath
        frame.frame = view.bounds
        frame.isHidden = !on
        CATransaction.commit()
        if on { UIAccessibility.post(notification: .announcement, argument: "Drop to send to \(files?.target ?? "this pane")") }
    }
}
