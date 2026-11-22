import SwiftUI

/// Tab mode's close confirmations, shown from the control that was tapped: a confirmation
/// rises from the view it is attached to, so one shown from the root rises from the bottom of
/// the screen. The questions are the sidebar's (`SidebarDialogs`), with the same words; their
/// state is the root's (`StripRoutes.dialogs`) and holds the ids asked about, so a chip drawn
/// again or a tab moved meanwhile changes neither the question nor what its answer closes.
/// Close Tab's answer runs `StripRoutes.confirmCloseTab`.
struct StripDialogs: ViewModifier {
    let routes: StripRoutes?
    let shows: Set<SidebarDialogs.Question>

    func body(content: Content) -> some View {
        if let routes {
            content.modifier(SidebarDialogs(actions: routes.dialogs, shows: shows, closeTab: { _ in _ = routes.confirmCloseTab() }))
        } else {
            content
        }
    }
}

/// Where each tab chip is in the chips' row, in the row's own coordinates. Written as the chips
/// are laid out and read when a question goes up: not observed, so a chip's frame draws
/// nothing again.
@MainActor
final class ChipFrames {
    nonisolated static let space = "strip.chips"
    var byID: [String: CGRect] = [:]
}

/// The chips' close questions, Close Tab and Close Other Tabs, shown by the chip asked about:
/// at its close button when it shows one, else at the chip. One view for the row's life, laid
/// over the chips rather than in one, so the question stays up while the lazy chips are drawn
/// again or scrolled out of view, and a tab that moves leaves it where it was.
struct ChipsAnchor: View {
    let routes: StripRoutes?
    let frames: ChipFrames
    /// The tab on screen: its chip has the close button.
    let active: String?
    let showsClose: Bool
    /// Where the anchor stands, in the row's coordinates.
    @State private var rect: CGRect = .zero
    /// The tab the anchor stands at. The question shows only then: one shown in the update that
    /// moves the anchor would rise from where the anchor was.
    @State private var placed: String?

    var body: some View {
        let asked = askedID
        Color.clear
            .frame(width: rect.width, height: rect.height)
            .modifier(StripDialogs(routes: routes, shows: asked != nil && placed == asked ? [.closeTab, .closeOthers] : []))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: asked, initial: true) { _, id in
                placed = nil
                guard let id else { return }
                Task { @MainActor in await place(at: id) }
            }
    }

    /// Moves the anchor to tab `id`'s chip, then lets the question show there.
    private func place(at id: String) async {
        // A chip laid out a moment ago reports its frame a turn later.
        for _ in 0..<10 where frames.byID[id] == nil {
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard askedID == id else { return }
        rect = Self.anchor(for: id, frames: frames.byID, active: active, showsClose: showsClose)
        // The next turn of the main queue, once the anchor stands there.
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        if askedID == id { placed = id }
    }

    /// The tab a question is up about.
    private var askedID: String? {
        let d = routes?.dialogs
        return d?.closingTab?.windowID ?? d?.closingOthers?.target.windowID
    }

    /// Where the question about tab `id` shows, in the row's coordinates: the close button, the
    /// end of the chip a hit target wide, where the chip has one; else the chip; the tab on
    /// screen's chip when the asked one has no frame.
    static func anchor(for id: String, frames: [String: CGRect], active: String?, showsClose: Bool) -> CGRect {
        if let f = frames[id] {
            guard id == active, showsClose else { return f }
            // The close button is the chip's end, a hit target wide (`TabChipView`).
            let w = min(StripLayout.hit, f.width)
            return CGRect(x: f.maxX - w, y: f.minY, width: w, height: f.height)
        }
        return active.flatMap { frames[$0] } ?? .zero
    }
}
