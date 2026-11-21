import RexKit
import SwiftUI
import Testing
import UIKit
@testable import RexDuo

/// The strip's views, drawn for real: the session chip's measured width, the chips at the
/// largest text sizes, fifty tabs in a row, and what a tap on each part reports.
@MainActor
@Suite struct StripViewTests {
    private let theme = ThemeStore.fallback

    /// The session chip's own size in a bar `height` tall, as the strip measures it.
    private func ideal(_ chip: SessionChip, height: CGFloat = 44, type: DynamicTypeSize = .large) -> CGSize {
        let view = SessionChipIdeal(chip: chip, height: height, theme: theme).environment(\.dynamicTypeSize, type)
        return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 2000, height: height))
    }

    /// A chip's own size, with nothing proposed.
    private func size(_ chip: TabChip, type: DynamicTypeSize) -> CGSize {
        let view = TabChipView(chip: chip, theme: theme, onTap: {}, onAction: { _ in })
            .fixedSize()
            .environment(\.dynamicTypeSize, type)
        return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 2000, height: 2000))
    }

    // MARK: The session chip's width

    /// The chip is as wide as its name asks, and the strip gives it that, up to 120 pt.
    @Test func theSessionChipIsAsWideAsItsName() {
        let short = ideal(SessionChip(name: "api", machine: nil, waiting: 0))
        let longer = ideal(SessionChip(name: "workspace", machine: nil, waiting: 0))
        let longest = ideal(SessionChip(name: "a-session-with-a-very-long-name-indeed", machine: nil, waiting: 0))
        #expect(short.height == 44 && longest.height == 44)
        #expect(short.width > 20 && short.width < longer.width && longer.width < longest.width)
        #expect(short.width < StripLayout.sessionMax, "a short name leaves its room to the tabs: \(short.width)")
        #expect(longest.width > StripLayout.sessionMax, "a long name asks for more than it gets: \(longest.width)")

        func chip(_ ideal: CGSize) -> CGFloat? {
            StripLayout(.init(width: 750, sessionIdeal: ideal.width.rounded(.up))).frame(.session)?.width
        }
        #expect(chip(short) == max(short.width.rounded(.up), StripLayout.hit))
        #expect(chip(longer) == longer.width.rounded(.up))
        #expect(chip(longest) == StripLayout.sessionMax)
    }

    /// The waiting dot's room is always part of the width, so the dot comes and goes without
    /// moving the tabs; a glyph chip measures as its name too, for the bar that has room.
    @Test func theWaitingDotAndTheFormDontChangeTheWidth() {
        let quiet = ideal(SessionChip(name: "work", machine: nil, waiting: 0))
        #expect(ideal(SessionChip(name: "work", machine: nil, waiting: 1)) == quiet)
        #expect(ideal(SessionChip(name: "work", machine: nil, waiting: 4)) == quiet)
        #expect(ideal(SessionChip(name: "work", machine: nil, waiting: 0, form: .glyph)) == quiet)
    }

    /// With more than one computer the chip has the computer's name under the session's, where
    /// the bar is tall enough: it is as wide as the wider line. A short bar has the one line.
    @Test func theComputersLineCountsWhereItShows() {
        let alone = ideal(SessionChip(name: "api", machine: nil, waiting: 0))
        let named = ideal(SessionChip(name: "api", machine: "a-computer-with-a-long-name", waiting: 0))
        #expect(named.width > alone.width)
        let short = ideal(SessionChip(name: "api", machine: "a-computer-with-a-long-name", waiting: 0), height: 34)
        #expect(short.width == ideal(SessionChip(name: "api", machine: nil, waiting: 0), height: 34).width)
    }

    // MARK: Accessibility text sizes

    /// At AX3 and AX5 the strip is what it is at the largest standard size, where its text stops
    /// growing (`StripStyle.chipTypeLimit`): the bar keeps the title bar's height, so the chips
    /// keep their size and their titles truncate. The session chip's measured width is that
    /// size's too, and every layout made with it keeps its frames.
    @Test(arguments: [DynamicTypeSize.accessibility3, .accessibility5])
    func theStripStopsGrowingAtTheLargestStandardSize(type: DynamicTypeSize) {
        let limit = StripStyle.chipTypeLimit
        let strip = StripLayout(.init(width: 402))
        let chips = [
            TabChip(id: "1", title: "claude", active: true, position: 1, count: 3, panes: [.claude, nil], status: "working", strip: strip),
            TabChip(id: "2", title: "~/code/a/rather/long/path/to/some/folder", active: false, position: 2, count: 3,
                    panes: [nil, nil, .codex, nil], status: "blocked"),
            TabChip(id: "3", title: "build", active: false, position: 3, count: 3, panes: [nil], status: nil),
        ]
        for chip in chips {
            let big = size(chip, type: type), capped = size(chip, type: limit), standard = size(chip, type: .large)
            #expect(big == capped, "\(chip.title): \(big) at \(type), \(capped) at the limit")
            // Larger text makes a chip wider, but for a title cut at its cap.
            if chip.title.count < 12 { #expect(capped.width > standard.width, "\(chip.title)") }
            // The chip's content fits the short bar too, with the capsule's inset.
            #expect(big.height <= 34, "\(chip.title) is \(big.height) pt tall")
            #expect(big.width >= StripLayout.chipMin, "\(chip.title)")
        }
        // An inactive chip's title is cut at 120 pt at every size.
        let long = size(chips[1], type: type)
        let fixed = StripStyle.chipPadding * 2 + StripStyle.iconSize * 3 + StripStyle.iconSpacing * 2 + StripStyle.chipSpacing * 2
        #expect(long.width <= fixed + StripLayout.inactiveTitleMax + 40, "\(long.width) pt")

        for height in [34, 44] as [CGFloat] {
            let names = [SessionChip(name: "api", machine: nil, waiting: 0),
                         SessionChip(name: "workspace", machine: "studio", waiting: 2),
                         SessionChip(name: "a-session-with-a-very-long-name-indeed", machine: nil, waiting: 0)]
            for name in names {
                let big = ideal(name, height: height, type: type)
                #expect(big == ideal(name, height: height, type: limit), "\(name.name), \(height) pt")
                #expect(big.width >= ideal(name, height: height).width && big.height == height, "\(name.name), \(height) pt")
                for (width, bar) in [(375, false), (382, true), (402, false), (430, false), (594, true), (750, false), (867, true)] as [(CGFloat, Bool)] {
                    var i = StripLayout.Input(width: width, height: height, bar: bar, zoomed: true, panes: 6, waiting: 1)
                    i.sessionIdeal = big.width.rounded(.up)
                    let l = StripLayout(i)
                    StripLayoutTests.checkFrames(l, i, "\(type), \(name.name), \(width) pt, bar \(bar)")
                    #expect((l.frame(.session)?.width ?? 0) <= StripLayout.sessionMax)
                    // The text size never decides the strip's form.
                    var plain = i
                    plain.sessionIdeal = nil
                    #expect(l.compact == StripLayout(plain).compact && l.showsClose)
                }
            }
        }
    }

    // MARK: Fifty tabs

    private func model() throws -> AppModel {
        let suite = "strip-view-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AppModel(prefs: Prefs(defaults: defaults), connect: false)
    }

    /// One computer with session "work" of `tabs` tabs of one pane each: tab n is `w<n>`,
    /// labelled `tab-<n>`, with pane `b<n>`.
    private func server(_ model: AppModel, tabs: Int) -> ServerConnection {
        let s = ServerConnection(config: ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"),
                                 prefs: model.prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        let windows = (1...tabs).map { n -> JSONObject in
            ["window_id": "w\(n)", "label": "tab-\(n)", "focused_block_id": "b\(n)",
             "layers": [["kind": "tiled", "blocks": [
                ["block_id": "b\(n)", "creator_name": "com.superlogical.terminal"] as JSONObject,
             ]] as JSONObject]]
        }
        s.sessions = [SessionEntry(id: "work", label: "work")]
        s.views = ["work": SessionView(["revision": 1, "session_id": "work", "label": "work", "active_window_id": "w1",
                                        "windows": windows])]
        s.phase = .online
        s.synced = true
        s.agentsWereRead()
        return s
    }

    /// Fifty tabs: fifty chips in Rex's order, each with its place, one of them active and only
    /// that one with a close button; none is narrower than a hit target or wider than the row.
    @Test func fiftyTabsAreFiftyChips() throws {
        let m = try model()
        let s = server(m, tabs: 50)
        let view = try #require(s.views["work"])
        for width in [382, 402, 867] as [CGFloat] {
            let strip = StripLayout(.init(width: width, bar: width == 382))
            let ids = s.orderedWindowIDs("work")
            #expect(ids == (1...50).map { "w\($0)" })
            let chips = try ids.enumerated().map { n, id in
                TabChip.of(try #require(view.window(id)), position: n + 1, count: ids.count, server: s, active: id == "w37",
                           block: "b37", strip: strip)
            }
            #expect(chips.count == 50 && Set(chips.map(\.id)).count == 50)
            #expect(chips.map(\.position) == Array(1...50) && chips.allSatisfy { $0.count == 50 })
            #expect(chips.filter(\.active).map(\.id) == ["w37"])
            #expect(chips.filter(\.showsClose).map(\.id) == ["w37"])
            #expect(chips[49].spoken == "tab-50, tab 50 of 50" && chips[0].spoken == "tab-1, tab 1 of 50")
            #expect(chips.allSatisfy { $0.menu.contains(.closeOthers) })
            // Every chip's width stays between a hit target and the row, however many there are.
            #expect(strip.chip.lowerBound == StripLayout.chipMin && strip.chip.upperBound == strip.chipsWidth)
            #expect(strip.activeChip.lowerBound == StripLayout.closeChipMin && strip.activeChip.upperBound == strip.chipsWidth)
            #expect(StripLayout(.init(width: width, bar: width == 382)) == strip, "the tabs don't change the layout")
        }
    }

    #if DEBUG
    private final class Reported {
        var picked: [String] = []
        var chip: [String] = []
        var newTabs = 0
        var steps: [Int] = []
    }

    private func actions(_ r: Reported) -> StripActions {
        StripActions(pick: { r.picked.append($0) }, chip: { r.chip.append("\($0) \($1)") }, newTab: { r.newTabs += 1 },
                     stepPane: { r.steps.append($0) })
    }

    private func strip(_ m: AppModel, _ s: ServerConnection, tab: String, block: String, dots: [String] = [],
                       _ r: Reported = Reported()) -> some View {
        TabStrip(target: StripTarget(server: s, sessionID: "work", windowID: tab, block: block), dots: dots, theme: theme,
                 actions: actions(r)) { EmptyView() }
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(m)
            .environment(m.prefs)
    }

    /// Fifty tabs in a phone's strip draw the chips in view and not the rest, with the tab on
    /// screen among them, and a strip that rests draws nothing more.
    @Test func fiftyTabsDrawOnlyTheChipsInView() async throws {
        let m = try model()
        let s = server(m, tabs: 50)
        let before = RenderCount.value(.tabChips)
        let window = Hosted.window(strip(m, s, tab: "w37", block: "b37"), size: CGSize(width: 402, height: 300))
        defer { window.isHidden = true }
        _ = await Hosted.settle { RenderCount.value(.tabChips) > before }
        _ = await Hosted.settle { false }
        let drawn = RenderCount.value(.tabChips) - before
        #expect(drawn > 0 && drawn < 50, "\(drawn) chips drawn for 50 tabs")
        let strips = RenderCount.value(.tabStrips)
        _ = await Hosted.settle { false }
        #expect(RenderCount.value(.tabChips) - before == drawn, "a strip at rest draws no chip again")
        #expect(RenderCount.value(.tabStrips) == strips, "nor itself")
    }

    // MARK: Taps

    /// What a touch on each part reports, through the element VoiceOver and a finger share: a
    /// chip picks its tab, the active chip's close button closes it, the chip's menu offers its
    /// actions, New Tab makes one, and the pane count steps.
    @Test func aTapOnEachPartReportsIt() async throws {
        try #require(Hosted.setAccessibility(on: true), "the simulator's accessibility runtime")
        defer { _ = Hosted.setAccessibility(on: false) }
        let m = try model()
        let s = server(m, tabs: 3)
        let r = Reported()
        // Wide, so New Tab is in the strip; two panes to page through.
        let window = Hosted.window(strip(m, s, tab: "w2", block: "b2", dots: ["b2", "x"], r), size: CGSize(width: 750, height: 300))
        defer { window.isHidden = true }
        func element(_ label: String) async throws -> NSObject {
            try await Hosted.eventually {
                Hosted.accessibilityElements(in: window).first { $0.isAccessibilityElement && $0.accessibilityLabel == label }
            }
        }

        let session = try await element("Session work")
        #expect(session.accessibilityHint == SessionChip.hint)

        let other = try await element("tab-3, tab 3 of 3")
        #expect(other.accessibilityActivate())
        #expect(r.picked == ["w3"])
        let active = try await element("tab-2, tab 2 of 3")
        #expect(active.accessibilityTraits.contains(.selected) && !other.accessibilityTraits.contains(.selected))

        // The chip's menu, as VoiceOver's actions: what the touch-and-hold menu holds.
        let names = (active.accessibilityCustomActions ?? []).map(\.name)
        #expect(Set(names) == ["Rename Tab…", "Close Tab", "Close Other Tabs"] && names.count == 3, "\(names)")

        let close = try await element("Close Tab")
        #expect(close.accessibilityActivate())
        #expect(r.chip == ["close w2"])

        let newTab = try await element(TabAction.newTab.title)
        #expect(newTab.accessibilityActivate())
        #expect(r.newTabs == 1)

        let dots = try await element("Pane 1 of 2")
        dots.accessibilityIncrement()
        dots.accessibilityDecrement()
        #expect(r.steps == [1, -1])
        // Nothing else ran.
        #expect(r.picked == ["w3"] && r.chip == ["close w2"] && r.newTabs == 1)
    }
    #endif
}
