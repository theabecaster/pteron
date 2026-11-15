import SwiftUI

/// One Rex tab (window): a header bar and its panes.
struct WindowScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let server: ServerConnection
    let sessionID: String
    let windowID: String
    let wide: Bool
    @Binding var sidebarVisible: Bool

    @State private var renaming = false
    @State private var renameText = ""

    private var view: SessionView? { server.views[sessionID] }
    private var window: WindowInfo? { view?.window(windowID) }

    var body: some View {
        let theme = ThemeStore.current(scheme)
        VStack(spacing: 0) {
            header(theme)
            if let w = window {
                if !wide || showSingle(w) {
                    if w.orderedBlockIDs.count > 1 { paneStrip(w, theme) }
                }
                canvas(w, theme)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 34, weight: .light))
                    Text("This tab closed.").font(.system(size: 14))
                }
                .foregroundStyle(theme.chrome.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.bg)
            }
        }
        .background(theme.chrome.canvas.ignoresSafeArea(edges: .bottom))
        .alert("Rename Tab", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await server.renameWindow(sessionID, windowID, renameText) } }
        }
    }

    private func showSingle(_ w: WindowInfo) -> Bool {
        switch Prefs.shared.wideLayout {
        case .single: return true
        case .splits: return false
        case .auto: return w.zoomedBlockID != nil
        }
    }

    private func activeBlock(_ w: WindowInfo) -> String? {
        if let z = w.zoomedBlockID { return z }
        if let f = model.focusedPane[w.id], w.allBlocks.contains(where: { $0.id == f }) { return f }
        return w.focusedBlockID ?? w.orderedBlockIDs.first
    }

    // MARK: Header

    private func header(_ theme: TermTheme) -> some View {
        HStack(spacing: 14) {
            if wide {
                Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
            } else {
                Button { dismiss() } label: { Image(systemName: "chevron.left").fontWeight(.semibold) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(window.map { WindowTitle.of($0, server: server) } ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text([server.config.name, view?.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.chrome.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let w = window, let b = activeBlock(w) {
                StatusBadge(status: server.meta[b]?.topStatus, theme: theme)
                paneMenu(w, block: b)
            }
        }
        .font(.system(size: 17))
        .foregroundStyle(theme.fg)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(theme.chrome.canvas)
    }

    private func paneMenu(_ w: WindowInfo, block: String) -> some View {
        Menu {
            Section {
                Button { Task { await server.split(sessionID, anchor: block, vertical: false) } } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
                Button { Task { await server.split(sessionID, anchor: block, vertical: true) } } label: { Label("Split Down", systemImage: "rectangle.split.1x2") }
                Button { Task { await server.newWindow(sessionID) } } label: { Label("New Tab", systemImage: "plus.square") }
            }
            Section {
                if w.allBlocks.count > 1 {
                    Button { Task { await server.zoom(sessionID, block: block, on: nil) } } label: {
                        Label(w.zoomedBlockID == nil ? "Zoom Pane" : "Unzoom", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                Button { Task { await server.clear(sessionID, block) } } label: { Label("Clear", systemImage: "eraser") }
                Button {
                    let p = Prefs.shared
                    p.sizing = p.sizing == .fit ? .mirror : .fit
                } label: {
                    Label(Prefs.shared.sizing == .fit ? "Mirror Mac Size" : "Fit to Phone", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                Button { renameText = w.label; renaming = true } label: { Label("Rename Tab", systemImage: "pencil") }
            }
            Section {
                Button(role: .destructive) { Task { await server.closeBlock(sessionID, block) } } label: { Label("Close Pane", systemImage: "xmark.square") }
                Button(role: .destructive) { Task { await server.closeWindow(sessionID, windowID) } } label: { Label("Close Tab", systemImage: "xmark") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: Pane strip (one pane at a time)

    private func paneStrip(_ w: WindowInfo, _ theme: TermTheme) -> some View {
        let active = activeBlock(w)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(w.orderedBlockIDs.enumerated()), id: \.element) { idx, bid in
                    let m = server.meta[bid]
                    Button {
                        model.focusedPane[w.id] = bid
                        Task { await server.focus(sessionID, block: bid) }
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(idx + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.chrome.tertiary)
                            Text(m?.title ?? w.block(bid)?.label ?? "pane").font(.system(size: 12)).lineLimit(1)
                            StatusBadge(status: m?.topStatus, theme: theme)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(maxWidth: 200)
                        .background(Capsule().fill(bid == active ? theme.chrome.rowSelected : theme.fg.opacity(0.04)))
                        .overlay(Capsule().stroke(bid == active ? theme.accent.opacity(0.6) : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 7)
        }
        .foregroundStyle(theme.fg)
    }

    // MARK: Canvas

    @ViewBuilder
    private func canvas(_ w: WindowInfo, _ theme: TermTheme) -> some View {
        let single = !wide || showSingle(w) || w.layout == nil
        if single {
            if let b = activeBlock(w) {
                PaneView(server: server, sessionID: sessionID, blockID: b, active: true) {}
                    .id(b)
                    .clipShape(RoundedRectangle(cornerRadius: wide ? 10 : 0))
                    .padding(wide ? 6 : 0)
            }
        } else if let layout = w.layout {
            let active = activeBlock(w)
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    ForEach(layout.leaves, id: \.id) { leaf in
                        let r = leaf.rect
                        let frame = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                                           width: r.width * size.width, height: r.height * size.height)
                            .insetBy(dx: 3, dy: 3)
                        PaneView(server: server, sessionID: sessionID, blockID: leaf.id, active: leaf.id == active) {
                            model.focusedPane[w.id] = leaf.id
                            Task { await server.focus(sessionID, block: leaf.id) }
                        }
                        .id(leaf.id)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(leaf.id == active ? theme.chrome.activeBorder : theme.chrome.divider, lineWidth: leaf.id == active ? 1.5 : 1))
                        .frame(width: max(frame.width, 10), height: max(frame.height, 10))
                        .offset(x: frame.minX, y: frame.minY)
                    }
                    ForEach(layout.splits, id: \.id) { sp in
                        SplitHandle(split: sp, canvas: size, theme: theme) { ratio in
                            Task { await server.resizePane(sessionID, direction: sp.direction, before: sp.beforeFirst, after: sp.afterFirst, ratio: ratio) }
                        }
                    }
                }
            }
            .padding(3)
        }
    }
}

/// The draggable border between two sides of a split.
struct SplitHandle: View {
    let split: (id: String, direction: String, ratio: Double, rect: CGRect, beforeFirst: String, afterFirst: String)
    let canvas: CGSize
    let theme: TermTheme
    let onCommit: (Double) -> Void
    @State private var drag: CGFloat = 0

    var body: some View {
        let r = split.rect
        let horizontal = split.direction != "vertical"  // side by side
        let x = (r.minX + (horizontal ? r.width * split.ratio : 0)) * canvas.width
        let y = (r.minY + (horizontal ? 0 : r.height * split.ratio)) * canvas.height
        let len = (horizontal ? r.height * canvas.height : r.width * canvas.width)
        Capsule()
            .fill(drag != 0 ? theme.accent : Color.clear)
            .frame(width: horizontal ? 4 : len * 0.9, height: horizontal ? len * 0.9 : 4)
            .contentShape(Rectangle().inset(by: -10))
            .position(x: x + (horizontal ? drag : len / 2), y: y + (horizontal ? len / 2 : drag))
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { v in drag = horizontal ? v.translation.width : v.translation.height }
                .onEnded { v in
                    let total = horizontal ? r.width * canvas.width : r.height * canvas.height
                    let delta = (horizontal ? v.translation.width : v.translation.height) / max(total, 1)
                    drag = 0
                    onCommit(split.ratio + delta)
                })
    }
}
