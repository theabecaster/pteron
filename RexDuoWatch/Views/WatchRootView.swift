import GlanceModel
import GlanceUI
import SwiftUI

/// The watch app's first screen: the headline, then the agents that wait, the longest wait
/// first, then each machine's counts. It lays out a `WatchScreen` and decides nothing.
struct WatchRootView: View {
    let screen: WatchScreen
    /// The rows opened, by id. Starts empty; `-glanceDetail YES` (Debug builds) starts at the first row.
    @State var path: [String] = []
    /// `-glanceDim YES` (Debug builds): as with the wrist down. Set inside the stack, which
    /// passes the system's own value to its screens.
    var dimmed = false
    /// `-glanceDetail later` (Debug builds): open the first row 2 s after launch, as a tap would.
    var openLater = false
    @Environment(\.isLuminanceReduced) private var systemWristDown

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch screen.kind {
                case .message(let text): WatchMessageView(text: text, style: style)
                case .agents: WatchListView(screen: screen, style: style)
                }
            }
            .modifier(WatchChange(value: screen.kind))
            .transformEnvironment(\.isLuminanceReduced) { if dimmed { $0 = true } }
            .containerBackground(style.ground(wristDown: wristDown), for: .navigation)
            .navigationTitle(Brand.appName)
            // Beside the clock, where it costs no row.
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                // Looked up at each draw: a delivery that arrives while the screen is open shows.
                WatchDetailView(row: screen.rows.first { $0.id == id }, style: style)
                    .containerBackground(style.ground(wristDown: wristDown), for: .navigation)
                    .transformEnvironment(\.isLuminanceReduced) { if dimmed { $0 = true } }
            }
        }
        .tint(style.colors.accent)
        .task {
            guard openLater, let first = screen.rows.first else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            path = [first.id]
        }
    }

    private var wristDown: Bool { dimmed || systemWristDown }
    private var style: WatchStyle { WatchStyle(screen.palette) }
}

/// Nothing to list: Glide, in its own colors, and one line.
struct WatchMessageView: View {
    let text: String
    let style: WatchStyle
    @Environment(\.isLuminanceReduced) private var wristDown

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                // A soft halo of the icon's indigo, gone with the wrist down.
                if !wristDown {
                    Circle()
                        .fill(RadialGradient(colors: [WatchGlide.indigo.opacity(0.4), .clear], center: .center,
                                             startRadius: 0, endRadius: 48))
                        .frame(width: 96, height: 96)
                }
                Image(WatchStyle.mark)
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(WatchGlide.gradient)
            }
            .frame(height: 72)
            .modifier(WatchArrival(part: .glide))
            .accessibilityHidden(true)
            Text(text)
                .font(.headline)
                .foregroundStyle(style.fg)
                .multilineTextAlignment(.center)
                .modifier(WatchArrival(part: .line))
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WatchListView: View {
    let screen: WatchScreen
    let style: WatchStyle
    /// Turns true once, when the list first shows: its lines come in one after another.
    @State private var entered = false

    var body: some View {
        List {
            WatchHeaderView(screen: screen, style: style)
                .modifier(WatchEntrance(index: 0, entered: entered))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 2, trailing: 4))
            ForEach(Array(screen.rows.enumerated()), id: \.element.id) { i, row in
                NavigationLink(value: row.id) {
                    // Only the agent that has waited longest breathes: one soft pulse on the screen.
                    WatchRowView(row: row, style: style, breathes: i == 0)
                }
                .modifier(WatchEntrance(index: i + 1, entered: entered))
                .listRowBackground(WatchPlatter(style: style))
            }
            if screen.more > 0 {
                Text("+\(screen.more) more")
                    .font(WatchStyle.place)
                    .foregroundStyle(style.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(screen.machines.enumerated()), id: \.element.id) { i, machine in
                WatchMachineRow(machine: machine, style: style)
                    .modifier(WatchEntrance(index: screen.rows.count + i + 1, entered: entered))
                    .listRowBackground(WatchPlatter(style: style))
            }
        }
        .modifier(WatchChange(value: screen))
        .task { await WatchMotion.settle(); entered = true }
    }
}

/// A row's platter: the sidebar color, as in the app.
struct WatchPlatter: View {
    let style: WatchStyle

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(style.platter)
    }
}

/// The headline, as on the agent board, in its state's color, with the machines and the
/// snapshot's age under it.
struct WatchHeaderView: View {
    let screen: WatchScreen
    let style: WatchStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            headline
                .font(WatchStyle.headline)
                // "Last seen" is quiet: the secondary color and no bold, never a warning.
                .fontWeight(screen.urgency == .offline ? .regular : nil)
                .foregroundStyle(style.headline(screen))
                .opacity(screen.dimmed ? WatchStyle.dim : 1)
                .modifier(WatchCount(value: screen.headline))
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
    var breathes = false

    var body: some View {
        HStack(spacing: 8) {
            WatchRing(row: row, style: style, diameter: 28, breathes: breathes)
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

/// A machine's name and its counts, each count in its state's color.
struct WatchMachineRow: View {
    let machine: WatchScreen.Machine
    let style: WatchStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(machine.name).font(WatchStyle.words).foregroundStyle(style.fg).privacySensitive()
            style.counts(machine).font(WatchStyle.place)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(machine.dimmed ? WatchStyle.dim : 1)
        .accessibilityElement(children: .combine)
    }
}
