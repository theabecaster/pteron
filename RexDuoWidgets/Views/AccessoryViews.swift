import GlanceModel
import GlanceUI
import SwiftUI
import WidgetKit

/// The Lock Screen accessories. Monochrome: the system picks the color, so a state shows by
/// shape (a raised hand for waiting, an arc for working) and by its word. They never show a
/// message; an agent's name and place are private, and left out altogether while the system
/// asks for redaction (`GlanceDigest.accessory(private:)`). Counts always show.
struct GlanceCircularView: View {
    let accessory: GlanceDigest.Accessory
    /// The count's color where the system draws in full color (a watch face). Nil: as inherited.
    var accent: Color?
    var symbols: Bundle = .main

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let count = accessory.count {
                if !accessory.hand, count > 0 {
                    // Working: the ring's arc.
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2.5)
                        .widgetAccentable()
                }
                VStack(spacing: -2) {
                    mark.font(.system(size: 13, weight: .bold))
                    Text("\(count)")
                        .font(GlanceType.count)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .modifier(GlanceAccent(color: accent))
                        .widgetAccentable()
                }
                .padding(.horizontal, 6)
                .opacity(accessory.dimmed ? 0.6 : 1)
            } else {
                mark.font(.system(size: 26, weight: .medium))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessory.count.map { "\($0) \(accessory.hand ? "waiting" : "working")" } ?? GlanceDigest.openText)
    }

    @ViewBuilder private var mark: some View {
        if accessory.hand {
            Image(systemName: "hand.raised.fill")
        } else {
            Image(GlanceStyle.markOpen, bundle: symbols)
        }
    }
}

struct GlanceRectangularView: View {
    let accessory: GlanceDigest.Accessory
    /// The first line's color where the system draws in full color (a watch face). Nil: as inherited.
    var accent: Color?
    var symbols: Bundle = .main

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if accessory.hand {
                    Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .bold))
                } else {
                    Image(GlanceStyle.markOpen, bundle: symbols).font(.system(size: 13, weight: .semibold))
                }
                GlanceHeadline(headline: accessory.title).font(.system(size: 15, weight: quiet ? .regular : .bold)).monospacedDigit()
            }
            .modifier(GlanceAccent(color: accent))
            .widgetAccentable()
            .opacity(accessory.dimmed || quiet ? 0.6 : 1)
            if let detail = accessory.detail {
                Text(detail).font(.system(size: 13)).privacySensitive()
            } else if let fallback = accessory.fallback {
                Text(fallback).font(.system(size: 13))
            }
            last.font(.system(size: 13)).opacity(0.7)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// "Last seen 12:04" stands in for the counts of machines that were down: quiet, no bold.
    private var quiet: Bool {
        if case .lastSeen = accessory.title { return true }
        return false
    }

    /// The age when there is one to tell; else how long the oldest wait has lasted.
    @ViewBuilder private var last: some View {
        if accessory.age != .current {
            GlanceAgeLine(age: accessory.age)
        } else if accessory.hand, let since = accessory.since {
            Text("waiting \(Text(.currentDate, format: .offset(to: since, allowedFields: [.day, .hour, .minute], maxFieldCount: 1, sign: .never)))")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GlanceInlineView: View {
    let accessory: GlanceDigest.Accessory

    var body: some View {
        // An old snapshot keeps its counts, dimmed; an accessory never asks to be refreshed.
        Group {
            if case .asOf(let date) = accessory.age {
                Label { Text("\(GlanceHeadline(headline: accessory.title).textValue) · \(Text(date, style: .time))") } icon: { icon }
            } else {
                Label { GlanceHeadline(headline: accessory.inline) } icon: { icon }
            }
        }
        .opacity(accessory.dimmed ? 0.6 : 1)
    }

    @ViewBuilder private var icon: some View {
        if accessory.hand { Image(systemName: "hand.raised.fill") }
    }
}

extension GlanceHeadline {
    /// The headline as one `Text`, for places that take only that.
    var textValue: Text {
        switch headline {
        case .text(let t): Text(t)
        case .lastSeen(let date): Text("Last seen \(Text(date, style: .time))")
        }
    }
}
