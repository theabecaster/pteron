import GlanceModel
import GlanceUI
import SwiftUI

/// One waiting agent: what it asks, where it is, and for how long it has waited. The watch
/// only shows, so the last line says where to answer.
///
/// What the agent asks is hidden while the wrist is down and the screen dimmed, where anyone
/// nearby could read it; its name and place are marked private for the system to hide.
struct WatchDetailView: View {
    /// Nil when the agent stopped waiting while this screen was open.
    let row: WatchScreen.Row?
    let style: WatchStyle
    @Environment(\.isLuminanceReduced) private var wristDown

    var body: some View {
        ScrollView {
            if let row {
                WatchDetailBody(row: row, style: style, wristDown: wristDown)
            } else {
                WatchGoneView(style: style)
            }
        }
    }
}

/// The agent stopped waiting while its screen was open: one quiet line.
struct WatchGoneView: View {
    let style: WatchStyle

    var body: some View {
        Text("No longer waiting")
            .font(.headline)
            .foregroundStyle(style.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }
}

struct WatchDetailBody: View {
    let row: WatchScreen.Row
    let style: WatchStyle
    let wristDown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                WatchRing(row: row, style: style, diameter: 44)
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
            }
            VStack(alignment: .leading, spacing: 1) {
                if !row.place.isEmpty { Text(row.place).privacySensitive() }
                if !row.machine.isEmpty { Text(row.machine).privacySensitive() }
            }
            .font(WatchStyle.place)
            .foregroundStyle(style.secondary)
            Text(WatchText.answer)
                .font(.footnote)
                .foregroundStyle(style.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }
}
