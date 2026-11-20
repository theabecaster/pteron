import GlanceModel
import GlanceUI
import SwiftUI

/// The watch app's first screen: the headline, then the agents that wait, the longest wait
/// first, then each machine's counts. It lays out a `WatchScreen` and decides nothing.
struct WatchRootView: View {
    let screen: WatchScreen
    /// The rows opened, by id. Starts empty; `-glanceDetail YES` (Debug builds) starts at the first row.
    @State var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch screen.kind {
                case .message(let text): WatchMessageView(text: text, style: style)
                case .agents: WatchListView(screen: screen, style: style)
                }
            }
            .navigationTitle(Brand.appName)
            // Beside the clock, where it costs no row.
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                // Looked up at each draw: a delivery that arrives while the screen is open shows.
                WatchDetailView(row: screen.rows.first { $0.id == id }, style: style)
            }
        }
        .tint(style.colors.accent)
    }

    private var style: WatchStyle { WatchStyle(screen.palette) }
}

/// Nothing to list: the mark and one line.
struct WatchMessageView: View {
    let text: String
    let style: WatchStyle

    var body: some View {
        VStack(spacing: 10) {
            Image(WatchStyle.mark)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(style.colors.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(.headline)
                .foregroundStyle(style.fg)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WatchListView: View {
    let screen: WatchScreen
    let style: WatchStyle

    var body: some View {
        List {
            WatchHeaderView(screen: screen, style: style)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 2, trailing: 4))
            ForEach(screen.rows) { row in
                NavigationLink(value: row.id) {
                    WatchRowView(row: row, style: style)
                }
                .listRowBackground(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(style.platter))
            }
            if screen.more > 0 {
                Text("+\(screen.more) more")
                    .font(WatchStyle.place)
                    .foregroundStyle(style.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(screen.machines) { machine in
                VStack(alignment: .leading, spacing: 1) {
                    Text(machine.name).font(WatchStyle.words).foregroundStyle(style.fg).privacySensitive()
                    Text(machine.words).font(WatchStyle.place).foregroundStyle(style.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(machine.dimmed ? WatchStyle.dim : 1)
                .listRowBackground(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(style.platter))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The headline, as on the agent board, with the machines and the snapshot's age under it.
struct WatchHeaderView: View {
    let screen: WatchScreen
    let style: WatchStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            headline
                .font(WatchStyle.headline)
                // "Last seen" is quiet: the secondary color and no bold, never a warning.
                .fontWeight(screen.urgency == .offline ? .regular : nil)
                .foregroundStyle(screen.urgency == .offline ? style.secondary : style.fg)
                .opacity(screen.dimmed ? WatchStyle.dim : 1)
            if let line = screen.machineLine {
                Text(line).font(WatchStyle.place).foregroundStyle(style.secondary)
            }
            switch screen.age {
            case .asOf(let date): Text("as of \(Text(date, style: .time))").font(WatchStyle.place).foregroundStyle(style.secondary)
            case .refresh: Text(WatchText.refresh).font(WatchStyle.place).foregroundStyle(style.secondary)
            case nil: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var headline: some View {
        switch screen.headline {
        case .text(let t): Text(t)
        case .lastSeen(let date): Text("Last seen \(Text(date, style: .time))")
        }
    }
}

/// A waiting agent: its ring, its name, what it waits for and for how long, and where.
struct WatchRowView: View {
    let row: WatchScreen.Row
    let style: WatchStyle

    var body: some View {
        HStack(spacing: 8) {
            WatchRing(row: row, style: style, diameter: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(WatchStyle.name).foregroundStyle(style.fg).privacySensitive()
                Text(row.words).font(WatchStyle.words).foregroundStyle(style.waiting)
                // A wait that is only last known shows no running clock.
                if !row.lastKnown {
                    WatchWaited(since: row.since)
                        .font(WatchStyle.words)
                        .foregroundStyle(style.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                let place = [row.listedMachine, row.place.isEmpty ? nil : row.place].compactMap { $0 }.joined(separator: " · ")
                if !place.isEmpty {
                    Text(place).font(WatchStyle.place).foregroundStyle(style.secondary).privacySensitive()
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(row.lastKnown ? WatchStyle.dim : 1)
        .accessibilityElement(children: .combine)
    }
}
