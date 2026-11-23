import SwiftUI
import UIKit

/// One action behind a sidebar row, shown when the row is swiped.
struct SwipeAction: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void
}

/// Which sidebar row has its actions showing. One for the list, so opening a row closes the others.
@MainActor
@Observable
final class SwipeState {
    var open: String?
}

/// Where a swiped row comes to rest, from how far it moved and how fast. Pure, so it is tested.
enum SwipeSnap {
    enum Rest: Equatable { case closed, leading, trailing, fullLeading }

    /// `offset` is the row's position (positive shows the leading actions), `velocity` in points per
    /// second. A fling opens or closes whatever the distance; a full swipe runs the first leading
    /// action when the row allows it.
    static func rest(offset: CGFloat, velocity: CGFloat, leading: CGFloat, trailing: CGFloat,
                     width: CGFloat, fullLeading: Bool) -> Rest {
        if fullLeading, leading > 0, offset > max(leading * 1.6, width * 0.55) { return .fullLeading }
        let fling: CGFloat = 600
        if offset > 0, leading > 0 {
            if velocity > fling { return .leading }
            if velocity < -fling { return .closed }
            return offset > leading / 2 ? .leading : .closed
        }
        if offset < 0, trailing > 0 {
            if velocity < -fling { return .trailing }
            if velocity > fling { return .closed }
            return -offset > trailing / 2 ? .trailing : .closed
        }
        return .closed
    }

    /// The row's position while a finger drags it: free up to the actions' width, then resisting.
    static func dragged(_ raw: CGFloat, leading: CGFloat, trailing: CGFloat, fullLeading: Bool) -> CGFloat {
        let limit = raw > 0 ? leading : trailing
        guard limit > 0 else { return 0 }
        let a = abs(raw)
        // A row with a full swipe follows the finger; others stretch a little past their actions.
        let shown = a <= limit || (raw > 0 && fullLeading) ? a : limit + (a - limit) * 0.25
        return raw > 0 ? shown : -shown
    }
}

/// Swipe actions for a row in a `LazyVStack`, like `List`'s: drag sideways to show them, tap one to
/// run it, fling or full-swipe like Mail. A UIKit pan that begins only for a sideways drag, so
/// vertical scrolling and the row's tap and menu are untouched. VoiceOver gets the same actions.
struct SidebarSwipe: ViewModifier {
    let id: String
    var leading: [SwipeAction] = []
    var trailing: [SwipeAction] = []
    var fullLeading = false
    let state: SwipeState

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let button: CGFloat = 72
    private var leadingWidth: CGFloat { CGFloat(leading.count) * Self.button }
    private var trailingWidth: CGFloat { CGFloat(trailing.count) * Self.button }
    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.3) }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background {
                if offset != 0 { actions }
            }
            .overlay {
                // While open, a tap on the row closes it instead of opening the tab.
                if offset != 0 {
                    Color.clear.contentShape(Rectangle())
                        .padding(.leading, offset > 0 ? offset : 0)
                        .padding(.trailing, offset < 0 ? -offset : 0)
                        .onTapGesture { close() }
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(SidewaysPan(began: began, changed: changed, ended: ended))
            .onChange(of: state.open) { _, open in
                if open != id, offset != 0 { withAnimation(animation) { offset = 0 } }
            }
            .accessibilityActions {
                ForEach(leading + trailing) { a in
                    Button(a.title, action: a.action)
                }
            }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if offset > 0 {
                ForEach(leading) { button($0, width: max(Self.button, offset / CGFloat(max(leading.count, 1)))) }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                // As in `List`, the first action sits at the edge.
                ForEach(trailing.reversed()) { button($0, width: max(Self.button, -offset / CGFloat(max(trailing.count, 1)))) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .transition(.opacity)
    }

    private func button(_ a: SwipeAction, width: CGFloat) -> some View {
        Button {
            run(a)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: a.symbol).font(.system(size: 15, weight: .semibold))
                Text(a.title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(a.tint)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private func run(_ a: SwipeAction) {
        Haptic.selection()
        close()
        a.action()
    }

    private func close() {
        withAnimation(animation) { offset = 0 }
        if state.open == id { state.open = nil }
    }

    // MARK: Drag

    @State private var start: CGFloat = 0

    private func began() {
        start = offset
        if state.open != id { state.open = id }
    }

    private func changed(_ dx: CGFloat) {
        offset = SwipeSnap.dragged(start + dx, leading: leadingWidth, trailing: trailingWidth, fullLeading: fullLeading)
    }

    private func ended(_ velocity: CGFloat) {
        let rest = SwipeSnap.rest(offset: offset, velocity: velocity, leading: leadingWidth, trailing: trailingWidth,
                                  width: width, fullLeading: fullLeading)
        switch rest {
        case .closed: close()
        case .leading: withAnimation(animation) { offset = leadingWidth }
        case .trailing: withAnimation(animation) { offset = -trailingWidth }
        case .fullLeading: if let a = leading.first { run(a) }
        }
    }
}

/// A pan that begins only when the finger moves more sideways than up or down, so the scroll view
/// keeps every vertical drag.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let began: () -> Void
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began: began()
        case .changed: changed(pan.translation(in: pan.view).x)
        case .ended, .cancelled, .failed: ended(pan.velocity(in: pan.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.5
        }

        /// The scroll view's pan waits for this one, which fails at once for a vertical drag.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView && other is UIPanGestureRecognizer
        }
    }
}
