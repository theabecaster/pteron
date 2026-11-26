import SwiftUI

/// The window controls (close, minimize, full screen) that iPadOS draws in the top leading corner
/// of a window that doesn't fill the screen. The app's bars keep clear of them as the system's own
/// bars do: a bar that reaches them moves its content right by as much, and its background still
/// runs to the window's edge. Where there are none (a full-screen app, an iPhone, the Duo) nothing
/// moves.
enum WindowControls {
    /// The controls' region, from the root's container corner insets (iOS 26). The system reports
    /// the controls in the same insets as the rounded corners of the window and the screen. Those
    /// corners are the same at the top leading and top trailing corner, so only a top leading
    /// region that differs from the top trailing one is the controls. The Duo's vertical bar makes
    /// the corners differ too, and the Duo has no controls: with a vertical bar there are none.
    static func region(topLeading: CGSize, topTrailing: CGSize, verticalBar: Bool) -> CGSize {
        guard !verticalBar, topLeading != topTrailing, topLeading.width > topTrailing.width else { return .zero }
        return topLeading
    }

    /// How far a bar whose leading edge is `barMinX` from the root's leading edge moves its
    /// content: what of the controls' width it reaches. Nothing for a bar past them (the title
    /// bar beside the inline sidebar).
    static func clearance(controls: CGSize, barMinX: CGFloat) -> CGFloat {
        guard controls.width > 0 else { return 0 }
        return max(controls.width - max(barMinX, 0), 0)
    }
}

extension EnvironmentValues {
    /// The window controls' region in the root's top leading corner; zero without controls
    /// (`WindowControls.region`).
    @Entry var windowControls: CGSize = .zero
}

extension GeometryProxy {
    /// The window controls' region in this view's top leading corner (`WindowControls.region`).
    func windowControls(verticalBar: Bool) -> CGSize {
        guard #available(iOS 26.0, *) else { return .zero }
        let corners = containerCornerInsets
        return WindowControls.region(topLeading: corners.topLeading, topTrailing: corners.topTrailing,
                                     verticalBar: verticalBar)
    }
}

extension View {
    /// Keeps a bar at the window's top clear of the window controls (`WindowControls`): its
    /// content moves right by what of them it reaches. For the title bar and tab mode's strip,
    /// which reach them only while no sidebar is beside them. Apply it inside the bar's
    /// background. Not for the sidebar, which slides away with `offset` and always starts at the
    /// window's edge when it shows: it pads by the controls' width itself.
    func clearsWindowControls() -> some View {
        modifier(ClearsWindowControls())
    }
}

private struct ClearsWindowControls: ViewModifier {
    @Environment(\.windowControls) private var controls
    @Environment(\.rootOrigin) private var rootOrigin
    /// The bar's leading edge in global coordinates.
    @State private var minX: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, WindowControls.clearance(controls: controls, barMinX: minX - rootOrigin.x))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { minX = $0 }
    }
}
