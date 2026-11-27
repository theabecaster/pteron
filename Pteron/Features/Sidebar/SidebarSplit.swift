import SwiftUI

/// The sidebar and the tab, like the Rex Mac app's window. One component for every posture:
/// - Wide (`Arrangement.inline`): the sidebar sits beside the tab. Drag its edge to resize it; let go
///   narrow and it collapses. The tab gets the full width while it is collapsed.
/// - Narrow (folded Duo, iPhone portrait, half the inner screen): the same sidebar is a drawer over the
///   tab. Drag its edge to resize it or shut it; tap outside to close it.
///
/// The width is remembered per posture (`SidebarWidth.key`). A drag moves only the sidebar: the tab's
/// frame changes once, on release, so the terminals refit and claim their size once. Opening slides
/// the sidebar in over the tab, then the tab makes room; closing gives the tab its width at once while
/// the sidebar slides away. Either way the terminals resize once, never per frame.
///
/// In tab mode (`NavigationStyle.tabs`) there is no sidebar in any posture: the tab has the whole
/// width, and nothing of the sidebar is built. The tab stays the same view either way, so a
/// change of mode keeps its panes and its state.
struct SidebarSplit<Sidebar: View, Tab: View>: View {
    @Environment(Prefs.self) private var prefs
    let arrangement: Arrangement
    let theme: TermTheme
    var navigation = NavigationStyle.sidebar
    @Binding var open: Bool
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var tab: Tab

    /// The width shown while a drag is under way.
    @State private var live: CGFloat?
    @State private var dragStart: CGFloat = 0
    @State private var snapped: CGFloat?
    @State private var willCollapse = false
    /// Inline: the tab leaves room for the sidebar. Follows `open`, after the slide when opening.
    @State private var makesRoom = false

    private static var slide: Animation { .snappy(duration: 0.25) }

    var body: some View {
        GeometryReader { geo in
            let cw = geo.size.width
            let inline = arrangement.inline
            let stored = width(container: cw)
            let w = live ?? stored
            let shown = navigation == .sidebar
            #if DEBUG
            let _ = shown && open && !inline ? RenderCount.bump(.openDrawers) : false
            #endif
            ZStack(alignment: .topLeading) {
                tab
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, shown && inline && makesRoom ? stored + 1 : 0)
                if shown {
                    sidebarLayers(geo, container: cw, stored: stored, width: w)
                }
            }
            .onChange(of: open, initial: true) { was, isOpen in
                if was == isOpen {
                    // First layout: no slide to wait for.
                    still { makesRoom = isOpen }
                } else if !isOpen {
                    still { makesRoom = false }
                } else if !makesRoom {
                    // Let the sidebar slide in over the tab first, then resize the tab once.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 260_000_000)
                        if open { still { makesRoom = true } }
                    }
                }
            }
            // The window turned wide with the sidebar showing (an unfold after a launch that held
            // the drawer shut): nothing slides, so the tab makes room in the unfold's own layout
            // and its panes are resized once, not to the full width first.
            .onChange(of: inline) { _, wide in
                if wide, open, !makesRoom { still { makesRoom = true } }
            }
        }
    }

    /// The scrim under a drawer, the sidebar and its resize handle, over the tab.
    @ViewBuilder
    private func sidebarLayers(_ geo: GeometryProxy, container cw: CGFloat, stored: CGFloat, width w: CGFloat) -> some View {
        let inline = arrangement.inline
        if !inline {
            Color.black.opacity(open ? 0.3 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(open)
                .onTapGesture { open = false }
                .accessibilityLabel("Hide Sidebar")
                .accessibilityAddTraits(.isButton)
                .accessibilityHidden(!open)
                .animation(Self.slide, value: open)
        }
        sidebar
            .frame(width: w)
            // No floor of its own: the stack around it places the tab at the stack's size, so a
            // sidebar that can't be shorter (its picker and first rows) would hold the tab taller
            // than the window's room, and the panes would run under Compose's card. Its rows clip
            // to the room instead.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            // The drawer's shadow comes from its background alone. On the whole sidebar it
            // would shadow every row and glyph on its own, and show through rows that fade.
            .background(theme.chrome.sidebar.shadow(color: .black.opacity(inline ? 0 : 0.25), radius: 12)
                .ignoresSafeArea())
            .overlay(alignment: .trailing) {
                Rectangle().fill(theme.chrome.divider).frame(width: 1).ignoresSafeArea()
            }
            // Dragged past the collapse point: letting go now hides it.
            .opacity(willCollapse ? 0.55 : 1)
            .offset(x: open ? 0 : SidebarWidth.hiddenOffset(width: w, leadingInset: geo.safeAreaInsets.leading))
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
            .animation(Self.slide, value: open)
        if open {
            handle(height: geo.size.height, inline: inline)
                .offset(x: w - Self.handleReach)
                .transition(.opacity)
                .gesture(resize(container: cw, stored: stored))
                .accessibilityElement()
                .accessibilityLabel("Sidebar Width")
                .accessibilityValue("\(Int(w)) points")
                .accessibilityAdjustableAction { d in
                    let next = SidebarWidth.clamp(stored + (d == .increment ? 20 : -20), container: cw, inline: inline)
                    store(next, container: cw)
                }
                .accessibilityAction(named: "Hide Sidebar") { open = false }
        }
    }

    // MARK: Width

    private func width(container: CGFloat) -> CGFloat {
        let key = SidebarWidth.key(container: container, inline: arrangement.inline)
        let w = prefs.sidebarWidths[key].map { CGFloat($0) } ?? SidebarWidth.standard
        return SidebarWidth.clamp(w, container: container, inline: arrangement.inline)
    }

    private func store(_ w: CGFloat, container: CGFloat) {
        let key = SidebarWidth.key(container: container, inline: arrangement.inline)
        still { prefs.sidebarWidths[key] = Double(w.rounded()) }
    }

    /// Runs a change that must not animate (anything that resizes the tab).
    private func still(_ change: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, change)
    }

    // MARK: Handle

    /// How far the handle's grip reaches either side of the edge.
    private static var handleReach: CGFloat { 22 }
    /// The grip's length along the edge.
    private static var gripLength: CGFloat { 88 }

    /// The sidebar's edge: a hairline the full height, with a grip in the middle. Its hit area is a
    /// thin strip along the edge plus the 44 pt wide grip, so it doesn't cover the sidebar's row
    /// buttons or the tab's title bar.
    private func handle(height: CGFloat, inline: Bool) -> some View {
        let r = Self.handleReach
        let dragging = live != nil
        return ZStack {
            Rectangle()
                .fill(dragging ? theme.accent : Color.clear)
                .frame(width: 2)
            Capsule()
                .fill(dragging ? theme.accent : theme.chrome.tertiary)
                .frame(width: 4, height: 36)
                .opacity(dragging ? 1 : 0.8)
        }
        .frame(width: r * 2, height: height)
        // Where it reaches over the tab's panes, a drag across it is the handle's alone.
        .background(HandleStrip(sideways: true, shape: AnyShape(HandleShape(reach: r, grip: Self.gripLength)))
            .allowsHitTesting(false))
        .contentShape(HandleShape(reach: r, grip: Self.gripLength))
        .animation(.snappy(duration: 0.15), value: dragging)
    }

    private func resize(container: CGFloat, stored: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                if live == nil { dragStart = stored; snapped = nil; Haptic.selection() }
                let raw = dragStart + v.translation.width
                let l = SidebarWidth.live(raw, container: container, inline: arrangement.inline, crease: arrangement.crease)
                let collapsing = raw < SidebarWidth.collapse
                if collapsing != willCollapse {
                    if collapsing { Haptic.threshold() }
                    withAnimation(.snappy(duration: 0.15)) { willCollapse = collapsing }
                }
                if l.snapped != snapped {
                    snapped = l.snapped
                    if l.snapped != nil { Haptic.selection() }
                }
                live = l.width
            }
            .onEnded { v in
                let raw = dragStart + v.translation.width
                // A quick flick toward the edge shuts it too.
                let flung = dragStart + v.predictedEndTranslation.width < SidebarWidth.collapse - 60
                let end = SidebarWidth.release(raw, container: container, inline: arrangement.inline,
                                               crease: arrangement.crease)
                if let end, !flung {
                    store(end, container: container)
                    withAnimation(.snappy(duration: 0.15)) { live = nil }
                } else {
                    if !willCollapse { Haptic.threshold() }
                    open = false
                    live = nil
                }
                snapped = nil
                willCollapse = false
            }
    }
}

/// The sidebar handle's hit area: a strip along the edge, wider at the grip in the middle.
struct HandleShape: Shape {
    let reach: CGFloat
    let grip: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // 6 pt over the sidebar, 10 pt over the tab.
        p.addRect(CGRect(x: rect.midX - 6, y: rect.minY, width: 16, height: rect.height))
        p.addRect(CGRect(x: rect.minX, y: rect.midY - grip / 2, width: reach * 2, height: grip))
        return p
    }
}
