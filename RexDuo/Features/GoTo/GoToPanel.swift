import RexKit
import SwiftUI
import UIKit

/// Where the palette's panel goes in the root. Pure, so every posture is tested.
enum GoToPanelLayout {
    static let maxWidth: CGFloat = 520
    static let margin: CGFloat = 8
    /// Space kept clear of a crease (as `OfflineLayout.gutter`).
    static let gutter: CGFloat = 12
    static let minHeight: CGFloat = 120

    struct Frame: Equatable {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var maxHeight: CGFloat
    }

    /// - Parameters:
    ///   - size: the root's size; `safe` its safe area.
    ///   - top: where the panel's top goes (8 pt below the title bar at open), nil for below the
    ///     status bar.
    ///   - narrow: the folded Duo and iPhones, full width.
    ///   - division: the fold, in the root's coordinates.
    ///   - keyboardTop: the keyboard's top where it crosses the panel's column, if it does.
    ///   - keyboardPad: the docked keyboard's room at the root's bottom.
    static func frame(size: CGSize, safe: EdgeInsets, top: CGFloat?, narrow: Bool, division: Division?,
                      keyboardTop: (CGFloat, ClosedRange<CGFloat>) -> CGFloat?, keyboardPad: CGFloat) -> Frame {
        let y = top.map { $0 + margin } ?? (safe.top + margin)
        let lo = safe.leading, hi = size.width - safe.trailing
        var x: CGFloat
        var width: CGFloat
        if narrow {
            x = lo + margin
            width = max(hi - lo - 2 * margin, 0)
        } else {
            var page = lo...max(hi, lo)
            if let d = division, d.isVertical, d.frame.minX > lo, d.frame.maxX < hi {
                // The tab's page: the one right of the crease, unless that one is too small.
                let right = (d.frame.maxX + gutter)...hi
                let left = lo...(d.frame.minX - gutter)
                page = right.upperBound - right.lowerBound >= 300 ? right : left
            }
            width = min(maxWidth, page.upperBound - page.lowerBound - 2 * gutter)
            x = (page.lowerBound + page.upperBound) / 2 - width / 2
            width = max(width, 0)
        }
        var bottom = size.height - max(safe.bottom, keyboardPad) - margin
        if let d = division, !d.isVertical, d.isActive, d.frame.minY > y { bottom = min(bottom, d.frame.minY - gutter) }
        if let k = keyboardTop(x, x...(x + width)) { bottom = min(bottom, k - margin) }
        return Frame(x: x, y: y, width: width, maxHeight: max(bottom - y, minHeight))
    }
}

/// The palette over the root: the tab and the sidebar behind it dim, and a tap there closes it.
/// Nothing of it is in the tree while it is closed. While it is open the root is hidden from
/// VoiceOver.
struct GoToOverlay: ViewModifier {
    @Environment(AppModel.self) private var model
    let theme: TermTheme
    let narrow: Bool
    let division: Division?
    let keyboardPad: CGFloat

    func body(content: Content) -> some View {
        let session = model.goTo
        content
            .accessibilityHidden(session != nil)
            .overlay {
                if let session {
                    GoToPanel(session: session, theme: theme, narrow: narrow, division: division, keyboardPad: keyboardPad)
                }
            }
            .onChange(of: model.boardShown) { _, shown in if shown { model.palette.boardShown() } }
    }
}

struct GoToPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @AccessibilityFocusState private var fieldFocused: Bool
    let session: GoToModel
    let theme: TermTheme
    let narrow: Bool
    let division: Division?
    let keyboardPad: CGFloat
    @State private var shown = false
    @State private var contentHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 44
    @State private var bottomHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var rowEstimate: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 44
    @State private var announce: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let f = GoToPanelLayout.frame(
                // The reader's frame is inside the safe area already.
                size: geo.size, safe: EdgeInsets(), top: session.anchor.map { $0 - origin.y },
                narrow: narrow, division: division,
                keyboardTop: { _, column in keyboardTop(column, origin: origin) }, keyboardPad: keyboardPad)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(shown ? 0.2 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { session.dismiss() }
                    .accessibilityHidden(true)
                panel(maxHeight: f.maxHeight)
                    .frame(width: f.width)
                    .offset(x: f.x, y: f.y + (shown || reduceMotion ? 0 : -8))
                    .opacity(shown ? 1 : 0)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            withAnimation(.snappy(duration: 0.2)) { shown = true }
            fieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .null
            if session.keyboardFrame != f { session.keyboardFrame = f }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if session.keyboardFrame != .null { session.keyboardFrame = .null }
        }
        .onChange(of: session.rows.count) { _, n in announceCount(n) }
        .transition(.opacity.animation(.easeOut(duration: 0.12)))
    }

    /// The keyboard's top, in the root's coordinates, where it crosses the panel's column.
    private func keyboardTop(_ column: ClosedRange<CGFloat>, origin: CGPoint) -> CGFloat? {
        let k = session.keyboardFrame
        guard !k.isNull, !k.isEmpty else { return nil }
        let minX = k.minX - origin.x, maxX = k.maxX - origin.x
        guard minX < column.upperBound, maxX > column.lowerBound else { return nil }
        return k.minY - origin.y
    }

    private func panel(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let p = session.prompt { promptHeading(p) }
                searchRow
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            if !session.rows.isEmpty {
                Divider().overlay(theme.chrome.divider)
                list(maxHeight: max(maxHeight - topHeight - bottomHeight - 1, 44))
            }
            VStack(spacing: 0) {
                if let note = session.note, session.prompt == nil {
                    Divider().overlay(theme.chrome.divider)
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(theme.chrome.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                if let p = session.prompt { promptButtons(p) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.chrome.sidebar))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.chrome.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12)
        .foregroundStyle(theme.fg)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { session.dismiss() }
    }

    // MARK: Search row

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.chrome.secondary)
                .accessibilityHidden(true)
            if session.scope == .commands, session.prompt == nil {
                Text(">")
                    .font(.body.monospaced().weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .accessibilityLabel("Commands")
            }
            PaletteFieldView(model: session, placeholder: placeholder, font: .preferredFont(forTextStyle: .body),
                             color: UIColor(theme.fg), placeholderColor: UIColor(theme.chrome.tertiary),
                             paletteKey: paletteKey, onScope: { model.palette.keyPressed($0) })
                .accessibilityFocused($fieldFocused)
                .frame(height: fieldHeight)
            if !session.query.isEmpty {
                Button { session.clear() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.chrome.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 14)
    }

    private var placeholder: String {
        guard let p = session.prompt else { return session.scope.placeholder }
        switch p.kind {
        case .input(let placeholder, _): return placeholder ?? ""
        case .pick: return "Filter"
        }
    }

    /// An ⌥ or function key bound to a palette action, in the keymap of the palette's server.
    private var paletteKey: (KeyInput.Press) -> GoToScope? {
        let keymap = (session.target.flatMap { model.server($0.serverID) } ?? model.servers.first)?.keymap
        return { [weak keymap] press in
            guard let keymap, let (_, a) = keymap.resolve(press: press), case .command(.goTo(let s)) = a else { return nil }
            return s
        }
    }

    // MARK: Rows

    private func list(maxHeight: CGFloat) -> some View {
        let rows = session.rows
        // Until the rows are measured, about one row's height each.
        let content = contentHeight > 0 ? contentHeight : CGFloat(rows.count) * rowEstimate + 8
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { i in
                        let r = rows[i]
                        VStack(spacing: 0) {
                            if let h = r.header {
                                Text(h)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.chrome.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.top, i == 0 ? 8 : 12)
                                    .padding(.bottom, 2)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            GoToRowView(row: r, selected: r.id == session.selected, theme: theme)
                                .equatable()
                                .contentShape(Rectangle())
                                .onTapGesture { session.run(r.id) }
                        }
                        .id(i)
                    }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(content, maxHeight))
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: session.selected) { _, id in
                guard let id, let i = session.rows.firstIndex(where: { $0.id == id }) else { return }
                proxy.scrollTo(i)
            }
        }
    }

    // MARK: A question

    private func promptHeading(_ p: PalettePrompt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(p.actionTitle)
                .font(.caption)
                .foregroundStyle(theme.chrome.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func promptButtons(_ p: PalettePrompt) -> some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Cancel") { session.dismiss() }
                .buttonStyle(.bordered)
            if showsConfirm(p) {
                Button(p.confirm ?? "OK") { session.confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .tint(theme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Input and a multiple pick confirm with a button; a single pick answers on a tap.
    private func showsConfirm(_ p: PalettePrompt) -> Bool {
        switch p.kind {
        case .input: true
        case .pick(_, let multiple, _, _): multiple
        }
    }

    // MARK: VoiceOver

    private func announceCount(_ n: Int) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        announce?.cancel()
        announce = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            UIAccessibility.post(notification: .announcement, argument: n == 1 ? "1 result" : "\(n) results")
        }
    }
}

/// One row, drawn from its snapshot: equal snapshots skip the redraw, so a keystroke updates
/// the visible rows in place. Only the status badge reads live state.
struct GoToRowView: View, Equatable {
    let row: GoToModel.Row
    let selected: Bool
    let theme: TermTheme
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 44
    @Environment(\.dynamicTypeSize) private var typeSize

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.row == b.row && a.selected == b.selected && a.theme == b.theme }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .font(.system(size: 15))
                .foregroundStyle(row.dimmed ? theme.chrome.tertiary : theme.chrome.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                title
                    .lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.chrome.tertiary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: minHeight)
        .background(selected ? theme.chrome.rowSelected : .clear)
        .opacity(row.dimmed ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var title: Text {
        var s = AttributedString(row.title)
        let chars = Array(row.title)
        var index = s.startIndex
        var offset = 0
        for range in row.ranges {
            guard range.lowerBound < chars.count else { break }
            while offset < range.lowerBound, index < s.endIndex {
                index = s.characters.index(after: index)
                offset += 1
            }
            var end = index
            var o = offset
            while o < min(range.upperBound, chars.count), end < s.endIndex {
                end = s.characters.index(after: end)
                o += 1
            }
            s[index..<end].font = .body.weight(.semibold)
            index = end
            offset = o
        }
        return Text(s).font(.body)
    }

    @ViewBuilder
    private var trailing: some View {
        if let checked = row.checked {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checked ? theme.accent : theme.chrome.tertiary)
        } else if let detail = row.detail {
            Text(detail).font(.caption).foregroundStyle(theme.chrome.tertiary)
        } else if let badge = row.badge {
            GoToBadge(badge: badge, theme: theme)
        } else if let key = row.keyLabel {
            Text(key)
                .font(.callout.monospaced())
                .foregroundStyle(theme.chrome.tertiary)
        }
    }

    private var spoken: String {
        var parts = [row.kind, row.title]
        if !row.subtitle.isEmpty { parts.append(row.subtitle) }
        if row.checked == true { parts.append("checked") }
        return parts.joined(separator: ", ")
    }
}

/// A tab's or pane's live status: the only part of a row that reads live metadata.
private struct GoToBadge: View {
    @Environment(AppModel.self) private var model
    let badge: GoToModel.Row.Badge
    let theme: TermTheme

    var body: some View {
        switch badge {
        case .window(let s, let sid, let wid):
            if let server = model.server(s), let w = server.views[sid]?.window(wid) {
                WindowBadge(server: server, window: w, theme: theme)
            }
        case .block(let s, let bid):
            if let server = model.server(s) {
                BlockBadge(server: server, block: bid, theme: theme)
            }
        }
    }
}
