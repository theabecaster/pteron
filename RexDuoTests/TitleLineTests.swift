import SwiftUI
import Testing
import UIKit
@testable import RexDuo

/// Sidebar mode's one-line title (`TitleLine`): how the title and the session's name share the
/// line, and the line drawn for real at the largest text sizes.
@MainActor
@Suite struct TitleLineTests {
    private typealias W = TitleLine.Widths

    // MARK: Sharing the line

    @Test func bothFitWhole() {
        #expect(TitleLine.fit(room: 300, title: 40, session: 90) == W(title: 40, session: 90))
        // Exactly the room, gap included.
        #expect(TitleLine.fit(room: 40 + TitleLine.gap + 90, title: 40, session: 90) == W(title: 40, session: 90))
    }

    @Test func aShortTitleLeavesTheRestToTheSession() {
        // The session's name is cut, the title whole.
        let w = TitleLine.fit(room: 300, title: 40, session: 500)
        #expect(w == W(title: 40, session: 300 - TitleLine.gap - 40))
    }

    @Test func aLongTitleKeepsTheSessionsShare() {
        let room: CGFloat = 300, left = room - TitleLine.gap
        // The session's short name stays whole; the title takes the rest.
        #expect(TitleLine.fit(room: room, title: 400, session: 60) == W(title: left - 60, session: 60))
        // A long name keeps its share of the line.
        let share = left * TitleLine.sessionShare
        let w = TitleLine.fit(room: room, title: 400, session: 400)
        #expect(abs((w.session ?? 0) - share) < 0.001 && abs(w.title - (left - share)) < 0.001, "\(w)")
    }

    @Test func theSessionLeavesBeforeTheTitleGetsTooShort() {
        // Too narrow for both: the title takes the line.
        #expect(TitleLine.fit(room: 100, title: 80, session: 80) == W(title: 80, session: nil))
        #expect(TitleLine.fit(room: 60, title: 200, session: 80) == W(title: 60, session: nil))
    }

    @Test func nothingWithoutRoom() {
        #expect(TitleLine.fit(room: -20, title: 80, session: 80) == W(title: 0, session: nil))
        #expect(TitleLine.fit(room: 300, title: 80, session: nil) == W(title: 80, session: nil))
        #expect(TitleLine.fit(room: 300, title: 80, session: 0) == W(title: 80, session: nil))
    }

    /// Whatever the widths, the parts never pass the room.
    @Test func neverWiderThanTheRoom() {
        for room in stride(from: CGFloat(0), through: 500, by: 25) {
            for title in [CGFloat(10), 64, 150, 600] {
                for session in [CGFloat(20), 44, 120, 600] {
                    let w = TitleLine.fit(room: room, title: title, session: session)
                    let used = w.title + (w.session.map { $0 + TitleLine.gap } ?? 0)
                    #expect(used <= room + 0.001, "room \(room) title \(title) session \(session): \(w)")
                    #expect(w.title <= title && (w.session ?? 0) <= session)
                }
            }
        }
    }

    // MARK: The line drawn

    /// The title bar's line as `TabTitleBar` draws it: title, status, session, chevron.
    private func line(_ title: String, _ session: String, type: DynamicTypeSize) -> some View {
        TitleLineLayout {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                .layoutValue(key: TitleLineLayout.RoleKey.self, value: .title)
            Text(session).font(.subheadline).lineLimit(1)
                .layoutValue(key: TitleLineLayout.RoleKey.self, value: .session)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .dynamicTypeSize(...TitleLine.typeLimit)
        .environment(\.dynamicTypeSize, type)
    }

    private func size(_ v: some View, width: CGFloat) -> CGSize {
        UIHostingController(rootView: v).sizeThatFits(in: CGSize(width: width, height: 200))
    }

    /// At every text size the line fits the short bar (34 pt), so nothing clips: the largest
    /// sizes draw as the cap does.
    @Test func theLineFitsTheShortBarAtEveryTextSize() {
        let capped = size(line("api", "zz-session", type: TitleLine.typeLimit), width: 400)
        for type in DynamicTypeSize.allCases {
            let s = size(line("api", "zz-session", type: type), width: 400)
            #expect(s.height <= 34, "\(type): \(s.height)")
            if type >= TitleLine.typeLimit { #expect(s == capped, "\(type) grows past the cap") }
        }
    }

    /// A long title and session in a narrow bar stay inside it, on one line.
    @Test func longNamesTruncateInsideTheLine() {
        let v = line(String(repeating: "long-title-", count: 10), String(repeating: "session-", count: 10), type: .accessibility5)
        let s = size(v, width: 240)
        #expect(s.width <= 240 && s.height <= 34, "\(s)")
        let whole = size(line("api", "zz", type: .large), width: 240)
        #expect(whole.width < 120, "short names keep their own width: \(whole)")
    }
}
