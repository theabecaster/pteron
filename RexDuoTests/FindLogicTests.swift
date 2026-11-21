import CoreGraphics
import RexKit
import Foundation
import Testing
import UIKit
@testable import RexDuo

/// Find's pure parts: the needle, the count, where the bar floats, the tints, the reveal, the
/// keys and the focus rules.
struct FindQueryTests {
    @Test func theNeedleIsTheFirstLineComposedAndCapped() {
        #expect(FindQuery.sanitize("error") == Array("error".utf8))
        #expect(FindQuery.sanitize("first\nsecond") == Array("first".utf8))
        #expect(FindQuery.sanitize("a\r\nb") == Array("a".utf8))
        // NFD to NFC: "é" as e + combining acute becomes one scalar.
        #expect(FindQuery.sanitize("cafe\u{301}") == Array("café".utf8))
        let long = String(repeating: "é", count: 600)  // 1200 bytes
        let cut = FindQuery.sanitize(long)
        #expect(cut.count == 1024)
        #expect(String(decoding: cut, as: UTF8.self).count == 512, "cut at a character boundary")
        #expect(FindQuery.sanitize("").isEmpty)
    }

    @Test func shortNeedlesWaitAndLongerOnesDont() {
        #expect(FindQuery.delay(for: "") == 0)
        #expect(FindQuery.delay(for: "e") == 0.3)
        #expect(FindQuery.delay(for: "er") == 0.3)
        #expect(FindQuery.delay(for: "err") == 0)
    }

    @Test func theCountReads() {
        var r = FindResult(open: true, needle: Array("x".utf8))
        r.complete = false
        #expect(FindQuery.count(r) == nil, "nothing found yet while searching")
        r.complete = true
        #expect(FindQuery.count(r) == "No matches")
        r.historyFull = true
        #expect(FindQuery.count(r) == "No matches in recent history")
        r.total = 12
        #expect(FindQuery.count(r) == "– of 12")
        r.selectedIndex = 2
        #expect(FindQuery.count(r) == "3 of 12")
        r.complete = false
        r.selectedIndex = nil
        #expect(FindQuery.count(r) == "12+")
        #expect(FindQuery.count(FindResult(open: true)) == nil, "no needle, no count")
        #expect(FindQuery.count(FindResult()) == nil)
    }
}

struct FindBarPlacementTests {
    let pane = CGRect(x: 0, y: 0, width: 400, height: 600)

    @Test func theMainScreenBarIsAtTheBottomClearOfTheHomeIndicator() {
        let f = FindBarPlacement.frame(bounds: pane, safeTop: 0, safeBottom: 34, edge: .bottom, barHeight: 46, chipShown: false, crease: nil)
        #expect(f == CGRect(x: 8, y: 600 - 38 - 46, width: 384, height: 46))
        let flat = FindBarPlacement.frame(bounds: pane, safeTop: 0, safeBottom: 0, edge: .bottom, barHeight: 46, chipShown: false, crease: nil)
        #expect(flat.maxY == 592)
    }

    @Test func theTopBarSitsBelowTheStatusChip() {
        let free = FindBarPlacement.frame(bounds: pane, safeTop: 0, safeBottom: 0, edge: .top, barHeight: 46, chipShown: false, crease: nil)
        #expect(free.minY == 8)
        let chip = FindBarPlacement.frame(bounds: pane, safeTop: 0, safeBottom: 0, edge: .top, barHeight: 46, chipShown: true, crease: nil)
        #expect(chip.minY >= FindBarPlacement.chipBottom)
        #expect(!chip.intersects(CGRect(x: 0, y: 8, width: 400, height: 22)), "the chip stays tappable")
    }

    @Test func theEdgeFlipsOnlyOnTheAlternateScreenAndOnlyForTheUser() {
        func edge(_ alt: Bool, _ match: ClosedRange<CGFloat>?, flip: Bool, current: FindBarPlacement.Edge = .top) -> FindBarPlacement.Edge {
            FindBarPlacement.edge(alternateScreen: alt, current: current, barHeight: 46, paneHeight: 600, safeTop: 0,
                                  matchRows: match, flip: flip)
        }
        #expect(edge(false, 10...20, flip: true) == .bottom, "the main screen keeps the bottom")
        #expect(edge(true, nil, flip: true) == .top)
        #expect(edge(true, 10...20, flip: true) == .bottom, "a match under the top bar sends it down")
        #expect(edge(true, 300...320, flip: true) == .top)
        #expect(edge(true, 10...20, flip: false) == .top, "output never moves it")
        #expect(edge(true, 300...320, flip: false, current: .bottom) == .bottom)
    }

    @Test func theBarKeepsOffACreaseOnTheRoomierSide() {
        let f = FindBarPlacement.frame(bounds: pane, safeTop: 0, safeBottom: 0, edge: .bottom, barHeight: 46, chipShown: false,
                                       crease: 150...160)
        #expect(f.minX >= 160 + KeyBarPlacement.creaseClearance)
        #expect(f.maxX == 392)
        let left = FindBarPlacement.frame(bounds: pane, safeTop: 0, safeBottom: 0, edge: .bottom, barHeight: 46, chipShown: false,
                                          crease: 250...260)
        #expect(left.maxX <= 250 - KeyBarPlacement.creaseClearance)
    }

    @Test func compactAndMinimalSizes() {
        #expect(FindBarPlacement.size(width: 320) == .full)
        #expect(FindBarPlacement.size(width: 299) == .compact)
        #expect(FindBarPlacement.size(width: 199) == .minimal)
    }

    @Test func theInsetCoversOnlyTheBottomBarOnTheMainScreen() {
        let bar = CGRect(x: 8, y: 546, width: 384, height: 46)
        #expect(FindBarPlacement.findInset(bar: bar, edge: .bottom, paneHeight: 600, alternateScreen: false) == 54)
        #expect(FindBarPlacement.findInset(bar: bar, edge: .top, paneHeight: 600, alternateScreen: false) == 0)
        #expect(FindBarPlacement.findInset(bar: bar, edge: .bottom, paneHeight: 600, alternateScreen: true) == 0)
        // Mirror: divided by the zoom, and nothing when the scaled grid ends above the bar.
        #expect(FindBarPlacement.findInset(bar: bar, edge: .bottom, paneHeight: 600, alternateScreen: false, zoom: 0.5,
                                           gridBottom: 580) == 108)
        #expect(FindBarPlacement.findInset(bar: bar, edge: .bottom, paneHeight: 600, alternateScreen: false, zoom: 0.5,
                                           gridBottom: 500) == 0)
    }

    @Test func theJumpButtonSitsAboveTheBar() {
        let bar = CGRect(x: 8, y: 546, width: 384, height: 46)
        let y: CGFloat = FindBarPlacement.jumpCenterY(bar: bar, radius: 20)
        #expect(y == CGFloat(518))
    }
}

@MainActor
struct FindHighlightTests {
    let colors = GhosttyFindHighlights.Colors.fallback

    private func result(_ matches: [FindSpan], selected: FindSpan? = nil) -> FindResult {
        FindResult(serial: 1, open: true, needle: [1], total: matches.count, selected: selected, matches: matches)
    }

    @Test func screenRowsMapToViewportRows() {
        let s = FindSpan(startRow: 105, startCol: 3, endRow: 105, endCol: 7)
        #expect(GhosttyFindHighlights.ranges(s, viewTop: 100, rows: 10, cols: 40) == [.init(row: 5, first: 3, last: 7)])
        #expect(GhosttyFindHighlights.ranges(s, viewTop: 106, rows: 10, cols: 40).isEmpty, "above the viewport")
        #expect(GhosttyFindHighlights.ranges(s, viewTop: 90, rows: 10, cols: 40).isEmpty, "below it")
        let tall = FindSpan(startRow: 99, startCol: 30, endRow: 101, endCol: 2)
        #expect(GhosttyFindHighlights.ranges(tall, viewTop: 100, rows: 10, cols: 40)
                == [.init(row: 0, first: 0, last: 39), .init(row: 1, first: 0, last: 2)], "partly off the top")
        // The overscan row counts as a row.
        let overscan = FindSpan(startRow: 110, startCol: 0, endRow: 110, endCol: 1)
        #expect(GhosttyFindHighlights.ranges(overscan, viewTop: 100, rows: 11, cols: 40).count == 1)
    }

    @Test func everyMatchIsTintedAndTheCurrentOneIsOpaqueWithRecoloredText() {
        let a = FindSpan(startRow: 1, startCol: 0, endRow: 1, endCol: 4)
        let b = FindSpan(startRow: 3, startCol: 2, endRow: 3, endCol: 6)
        let built = GhosttyFindHighlights.build(result([a, b], selected: b), viewTop: 0, rows: 5, cols: 20, cellWidth: 10,
                                                cellHeight: 20, colors: colors) { _, _ in false }
        #expect(built.rects.count == 2)
        #expect(built.rects[0].color == colors.match && built.rects[0].row == 1 && built.rects[0].w == 50)
        #expect(built.rects[1].color == colors.current, "the current match last, opaque")
        #expect(built.spans == [.init(row: 3, first: 2, last: 6)])
    }

    @Test func aWideCharacterAtTheEndIsCoveredWhole() {
        let a = FindSpan(startRow: 0, startCol: 0, endRow: 0, endCol: 2)
        let built = GhosttyFindHighlights.build(result([a], selected: a), viewTop: 0, rows: 2, cols: 10, cellWidth: 10,
                                                cellHeight: 20, colors: colors) { r, c in r == 0 && c == 2 }
        #expect(built.rects[0].w == 40)
        #expect(built.spans[0].last == 3)
    }

    @Test func onlyTheFirstFourRowsOfTheCurrentMatchAreRecolored() {
        let long = FindSpan(startRow: 0, startCol: 5, endRow: 5, endCol: 2)
        let built = GhosttyFindHighlights.build(result([long], selected: long), viewTop: 0, rows: 8, cols: 10, cellWidth: 10,
                                                cellHeight: 20, colors: colors) { _, _ in false }
        #expect(built.spans.count == GhosttyFindHighlights.maxSpans)
        #expect(built.rects.filter { $0.color == colors.current }.count == 4)
        #expect(built.rects.filter { $0.color == colors.match }.count == 2, "the rest get the plain tint")
    }

    @Test func nothingIsDrawnWithFindClosedOrNoNeedle() {
        let a = FindSpan(startRow: 0, startCol: 0, endRow: 0, endCol: 1)
        var r = result([a])
        r.open = false
        #expect(GhosttyFindHighlights.build(r, viewTop: 0, rows: 2, cols: 4, cellWidth: 1, cellHeight: 1, colors: colors) { _, _ in false }.rects.isEmpty)
        r.open = true
        r.needle = []
        #expect(GhosttyFindHighlights.build(r, viewTop: 0, rows: 2, cols: 4, cellWidth: 1, cellHeight: 1, colors: colors) { _, _ in false }.rects.isEmpty)
    }

    @Test func everyThemesCurrentMatchTextReadsAtFourAndAHalfToOne() {
        for t in ThemeStore.all {
            let bright = GhosttyTerminalView.rgb(t.ansi[safe: 11] ?? t.foreground)
            let text = FindContrast.text(on: bright)
            #expect(FindContrast.ratio(text, bright) >= 4.5, "\(t.name)")
        }
        #expect(ThemeStore.all.count > 1, "themes.json loaded")
    }
}

struct FindRevealTests {
    // 10 rows of 20 px; maxRow 100.
    func reveal(_ top: Int, _ bottom: Int, viewTop: Int = 50, cover: Int = 0, inset: Int = 0, bounce: Int = 0) -> Int? {
        GhosttyScrollMath.reveal(top: top, bottom: bottom, viewTop: viewTop, len: 10, cellHeight: 20, cover: cover,
                                 findInset: inset, bounce: bounce, maxRow: 100)
    }

    @Test func aMatchOnScreenDoesntMove() {
        #expect(reveal(50, 50) == nil)
        #expect(reveal(59, 59) == nil)
        #expect(reveal(55, 56) == nil)
    }

    @Test func aMatchOffScreenGoesAThirdOfTheWayDown() {
        #expect(reveal(20, 20) == 17)
        #expect(reveal(70, 70) == 67)
        #expect(reveal(1, 1) == 0, "clamped at the top")
        #expect(reveal(105, 105) == 100, "the bottom position at the end")
    }

    @Test func rowsUnderTheKeyboardAndTheBarDontCount() {
        // 3 rows covered by the keyboard: rows 57-59 are hidden.
        #expect(reveal(58, 58, cover: 60) != nil)
        #expect(reveal(56, 56, cover: 60) == nil)
        // The find bar covers 2 more.
        #expect(reveal(55, 55, cover: 60, inset: 40) != nil)
        // The grid shifted up by 40 px shows two more at the bottom and loses the top two.
        #expect(reveal(58, 58, cover: 60, bounce: 40) == nil)
        #expect(reveal(51, 51, cover: 60, bounce: 40) != nil)
    }
}

@MainActor
struct FindKeyAndFocusTests {
    @Test func theThreeFindActionsResolveAndAreBoundByDefault() {
        #expect(AppAction.resolve("client.find.open", nil).map { if case .command(.find(.open)) = $0 { true } else { false } } == true)
        #expect(AppAction.resolve("client.find.next", nil).map { if case .command(.find(.next)) = $0 { true } else { false } } == true)
        #expect(AppAction.resolve("client.find.previous", nil).map { if case .command(.find(.previous)) = $0 { true } else { false } } == true)
        #expect(AppAction.resolve("client.find", nil) == nil, "the bare name stays unknown")
        let defaults = KeyDefaults.resolved
        #expect(defaults.contains { $0.chord.spelling == "cmd+f" && $0.action == "client.find.open" })
        #expect(defaults.contains { $0.chord.spelling == "cmd+g" && $0.action == "client.find.next" })
        #expect(defaults.contains { $0.chord.spelling == "shift+cmd+g" && $0.action == "client.find.previous" })
        #expect(KeyActions.byName["client.find.open"]?.title == "Find…")
    }

    @Test func theFindKeysAreAppShortcuts() {
        let list = AppShortcuts.list(KeyDefaults.resolved)
        #expect(list.contains { $0.command == .find(.open) && $0.id == "cmd+f" })
        #expect(list.contains { $0.command == .find(.next) })
        #expect(list.contains { $0.command == .find(.previous) })
    }

    @Test func theMenuLabelComesFromTheKeymap() {
        #expect(KeyLabel.for(action: "client.find.open", in: KeyDefaults.resolved) == "⌘F")
        #expect(KeyLabel.for(action: "client.find.previous", in: KeyDefaults.resolved) == "⇧⌘G")
        // init.lua gives ⌘F to another action: it runs that, and the label hides.
        let rebound = [KeyBinding(chord: KeyChord(spelling: "cmd+f")!, action: "client.tab.new", args: nil)] + KeyDefaults.resolved
        #expect(KeyLabel.for(action: "client.find.open", in: rebound) == nil)
        // Nothing bound to it: no label.
        #expect(KeyLabel.for(action: "client.find.open", in: KeyDefaults.resolved.filter { $0.action != "client.find.open" }) == nil)
        // A binding the app can't perform doesn't hide the next one on the key.
        let unknown = [KeyBinding(chord: KeyChord(spelling: "cmd+f")!, action: "pane.copy_mode.enter", args: nil)] + KeyDefaults.resolved
        #expect(KeyLabel.for(action: "client.find.open", in: unknown) == "⌘F")
    }

    @Test func whileTheFieldEditsOnlyAppCommandsAndFindKeysStay() {
        func keeps(_ action: String, _ args: JSONObject?, _ chord: String) -> Bool {
            FindKeys.keepsWhileEditing(action: AppAction.resolve(action, args)!, chord: KeyChord(spelling: chord)!)
        }
        #expect(keeps("client.tab.new", nil, "cmd+t"))
        #expect(keeps("client.find.next", nil, "cmd+g"))
        #expect(keeps("client.close", nil, "cmd+w"), "⌘W closes the pane, as on the Mac")
        #expect(!keeps("pane.send_key", ["key": "ctrl+u"], "cmd+backspace"))
        #expect(!keeps("pane.copy", nil, "cmd+c"))
        #expect(!keeps("pane.paste", nil, "cmd+v"))
        #expect(!keeps("client.scroll.page_up", nil, "shift+pageup"))
        #expect(!keeps("com.superlogical.terminal.clear", nil, "cmd+k"), "a server action is the pane's")
        #expect(!keeps("client.key.forward", nil, "cmd+e"))
        // Text-editing chords are the field's whatever they are bound to.
        #expect(!keeps("pane.split.right", nil, "shift+cmd+right"))
        #expect(!keeps("pane.split.down", nil, "shift+cmd+down"))
        #expect(!keeps("client.tab.new", nil, "cmd+z"))
        #expect(!keeps("client.tab.new", nil, "shift+cmd+z"))
        #expect(!keeps("client.tab.new", nil, "cmd+x"))
        #expect(!keeps("client.tab.new", nil, "cmd+a"))
    }

    @Test func anotherPanesFindFieldIsAFindFieldAndOurOwnIsNobody() {
        let own = FindField(), other = FindField(), term = UIView()
        #expect(KeyboardFocusPolicy.holder(other, own: term, ownFields: [own]) == .findField)
        #expect(KeyboardFocusPolicy.holder(own, own: term, ownFields: [own]) == .nobody)
        // From the app menu (no pane): every find field is one.
        #expect(KeyboardFocusPolicy.holder(own, own: nil) == .findField)
        #expect(KeyboardFocusPolicy.holder(UITextField(), own: term, ownFields: [own]) == .textInput)
    }

    @Test func aPaneTakesTheKeyboardFromAnotherPanesFieldAndAppShortcutsRunFromOne() {
        var s = KeyboardFocusPolicy.Situation()
        s.holder = .findField
        #expect(KeyboardFocusPolicy.takesKeyboard(s))
        s.holder = .textInput
        #expect(!KeyboardFocusPolicy.takesKeyboard(s))
        #expect(KeyboardFocusPolicy.runsAppShortcut(holder: .findField, sheetUp: false))
        #expect(!KeyboardFocusPolicy.runsAppShortcut(holder: .findField, sheetUp: true))
        #expect(!KeyboardFocusPolicy.runsAppShortcut(holder: .textInput, sheetUp: false), "⌘W in a rename field still closes nothing")
    }

    @Test func theFieldHasTheTerminalsTraits() {
        let f = FindField()
        #expect(f.autocapitalizationType == .none)
        #expect(f.autocorrectionType == .no)
        #expect(f.spellCheckingType == .no)
        #expect(f.smartQuotesType == .no)
        #expect(f.smartDashesType == .no)
        #expect(f.smartInsertDeleteType == .no)
        #expect(f.inlinePredictionType == .no)
        #expect(f.keyboardType == .default)
        #expect(f.returnKeyType == .default)
        #expect(!f.enablesReturnKeyAutomatically)
        #expect(f.writingToolsBehavior == .none)
    }

    @Test func theBarsHaveTheKeyBarsHeight() {
        let bar = FindAccessoryBar()
        bar.layoutIfNeeded()
        #expect(bar.systemLayoutSizeFitting(CGSize(width: 400, height: 0)).height == KeyBar.barHeight)
        let spacer = FindSpacer()
        #expect(spacer.systemLayoutSizeFitting(CGSize(width: 400, height: 0)).height == KeyBar.barHeight)
        #expect(FindOverlayBar.height(compact: false) == KeyBar.keyHeight + 2 * KeyBar.ring)
        #expect(FindHandover.shipped == .accessory)
    }
}

@MainActor
struct FindFitTests {
    final class Transport: FitClaimTransport {
        var calls: [String] = []
        func own() async -> FitClaimAnswer { calls.append("own"); return .done }
        func resize(cols: Int, rows: Int) async -> FitClaimAnswer { calls.append("resize \(cols)x\(rows)"); return .done }
        func disown() async { calls.append("disown") }
        func whenConnected(_ body: @escaping @MainActor () -> Void) {}
    }

    @Test func theWantedSizeIsTheNewestRequestEvenWhileItSettles() async {
        var release: CheckedContinuation<Void, Never>?
        let claim = FitClaim(transport: Transport()) { await withCheckedContinuation { release = $0 } }
        #expect(claim.wanted == nil)
        claim.request(cols: 80, rows: 24)
        #expect(claim.isSettling)
        #expect(claim.wanted?.cols == 80 && claim.wanted?.rows == 24)
        claim.release()
        #expect(!claim.isSettling)
        #expect(claim.wanted == nil)
        release?.resume()
    }

    @Test func aHeldGridWinsOverWhatFits() {
        let held = TerminalLayout.fitGrid(bounds: CGSize(width: 300, height: 200), rest: nil, alternateScreen: true,
                                          cell: CGSize(width: 10, height: 20), held: (cols: 30, rows: 30))
        #expect(held.cols == 30 && held.rows == 30)
        let free = TerminalLayout.fitGrid(bounds: CGSize(width: 300, height: 200), rest: nil, alternateScreen: true,
                                          cell: CGSize(width: 10, height: 20), held: nil)
        #expect(free.cols == 30 && free.rows == 10)
    }
}
