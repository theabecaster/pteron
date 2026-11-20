import GlanceModel
import GlanceUI
import SwiftUI

/// One waiting agent: what it asks, where it is, and for how long it has waited, and under it
/// the two answers the wrist can give, Enter and Interrupt, each behind a question
/// (`WatchActionButtons`). Where no action is offered, the last line says where to answer.
///
/// What the agent asks is hidden while the wrist is down and the screen dimmed, where anyone
/// nearby could read it; its name and place are marked private for the system to hide.
struct WatchDetailView: View {
    /// The row's id, which outlives the row.
    var id = ""
    /// Nil when the agent stopped waiting while this screen was open.
    let row: WatchScreen.Row?
    let style: WatchStyle
    @Environment(\.isLuminanceReduced) private var wristDown
    /// Nil in a picture drawn without the app.
    @Environment(WatchActions.self) private var actions: WatchActions?

    var body: some View {
        let state = actions?.state(row?.id ?? id) ?? WatchActionState()
        ScrollView {
            if let row {
                WatchDetailBody(row: row, style: style, wristDown: wristDown, state: state) { kind in
                    Task { await actions?.confirmed(kind, row: row) }
                }
            } else {
                WatchGoneView(style: style, line: state.line(for: nil))
            }
        }
        .defaultScrollAnchor(Self.anchor)
    }

    /// `-glanceScroll YES` (Debug builds): the screen opens at its end, where the actions are.
    /// A simulator's watch can't be scrolled from the command line.
    private static var anchor: UnitPoint? {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "glanceScroll") ? .bottom : nil
        #else
        return nil
        #endif
    }
}

/// The agent stopped waiting while its screen was open: one quiet line, and how the action
/// from here ended, when there was one.
struct WatchGoneView: View {
    let style: WatchStyle
    var line: String?

    var body: some View {
        VStack(spacing: 6) {
            Text("No longer waiting")
                .font(.headline)
            if let line { Text(line).font(.footnote).multilineTextAlignment(.center) }
        }
        .foregroundStyle(style.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}

/// Enter and Interrupt for a waiting agent. A tap only asks; the question's own button sends.
/// They are plain and still: no sound, no haptic, no motion of their own.
struct WatchActionButtons: View {
    let name: String
    let style: WatchStyle
    /// `-glanceAsk <kind>` (Debug builds) starts with that question up.
    @State var asking: WatchAction.Kind?
    let confirmed: (WatchAction.Kind) -> Void

    private var buttons: some View {
        ForEach(WatchAction.Kind.allCases, id: \.self) { kind in
            Button(role: kind == .interrupt ? .destructive : nil) {
                asking = kind
            } label: {
                Text(WatchText.title(kind)).lineLimit(1).fixedSize().frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    var body: some View {
        // Side by side where both fit, else under each other (a large text size).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { buttons }
            VStack(spacing: 6) { buttons }
        }
        .controlSize(.small)
        .padding(.top, 4)
        .confirmationDialog(asking.map { WatchText.confirm($0, name: name) } ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { kind in
            Button(WatchText.confirmButton(kind), role: kind == .interrupt ? .destructive : nil) { confirmed(kind) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct WatchDetailBody: View {
    let row: WatchScreen.Row
    let style: WatchStyle
    let wristDown: Bool
    var state = WatchActionState()
    var confirmed: (WatchAction.Kind) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                WatchRing(row: row, style: style, diameter: 44, breathes: true)
                    .modifier(WatchArrival(part: .ring))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(WatchStyle.name).foregroundStyle(style.fg).privacySensitive()
                    Text(row.words).font(WatchStyle.words).foregroundStyle(style.waiting)
                    if !row.lastKnown {
                        WatchWaited(since: row.since)
                            .font(WatchStyle.words)
                            .foregroundStyle(style.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .modifier(WatchArrival(part: .words))
            }
            .opacity(row.lastKnown ? WatchStyle.dim : 1)
            if let message = row.message(wristDown: wristDown) {
                Text(message)
                    .font(.body)
                    .foregroundStyle(style.fg)
                    .privacySensitive()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(style.platter))
                    .opacity(row.lastKnown ? WatchStyle.dim : 1)
                    .modifier(WatchArrival(part: .words))
            }
            VStack(alignment: .leading, spacing: 1) {
                if !row.place.isEmpty { Text(row.place).privacySensitive() }
                if !row.machine.isEmpty { Text(row.machine).privacySensitive() }
            }
            .font(WatchStyle.place)
            .foregroundStyle(style.secondary)
            // How the last action ended, or where to answer when the wrist can't.
            if let line = state.line(for: row.target) ?? (row.target == nil ? WatchText.answer : nil) {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(style.secondary)
                    .padding(.top, 4)
            }
            // With the wrist down nothing can be tapped, and nothing is offered.
            if let target = row.target, !wristDown, state.canAct(on: target) {
                WatchActionButtons(name: row.name, style: style, asking: Self.asked, confirmed: confirmed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private static var asked: WatchAction.Kind? {
        #if DEBUG
        return WatchDemo.asked
        #else
        return nil
        #endif
    }
}
