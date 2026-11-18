import Testing
@testable import RexDuo

/// A pinch is a request for a text size: in every state it stores the size it reached, and on a
/// pane resized elsewhere it also fits the pane here. It never only zooms the view.
@MainActor
struct TerminalPinchTests {
    private typealias State = TerminalPinch.PaneState

    /// Which state leads to which actions, for a pinch from 13 pt by 1.3 (17 pt).
    @Test func eachStateStoresTheSizeAndOnlyAPaneResizedElsewhereIsFittedHere() {
        #expect(TerminalPinch.outcome(.fitted, base: 13, scale: 1.3) == TerminalPinchOutcome(size: 17, fitHere: false))
        #expect(TerminalPinch.outcome(.resizedElsewhere, base: 13, scale: 1.3) == TerminalPinchOutcome(size: 17, fitHere: true))
        #expect(TerminalPinch.outcome(.mirror, base: 13, scale: 1.3) == TerminalPinchOutcome(size: 17, fitHere: false))
    }

    /// The bug: a pinch on a pane the Mac had resized zoomed the view and stored nothing.
    @Test func noStateIsZoomOnly() {
        for state in State.allCases {
            #expect(TerminalPinch.outcome(state, base: 11, scale: 1.5).size == 16.5, "\(state)")
            #expect(TerminalPinch.outcome(state, base: 11, scale: 0.8).size == 9, "\(state)")
        }
    }

    /// A pinch that lands on the size the pane has stores nothing. A pane resized elsewhere is
    /// still fitted here: the user asked for the text at that size, and only a fitted pane shows it.
    @Test func aPinchBackToTheSameSizeChangesNothingButStillFitsHere() {
        #expect(TerminalPinch.outcome(.fitted, base: 11, scale: 1.01) == TerminalPinchOutcome(size: nil, fitHere: false))
        #expect(TerminalPinch.outcome(.mirror, base: 11, scale: 0.99) == TerminalPinchOutcome(size: nil, fitHere: false))
        #expect(TerminalPinch.outcome(.resizedElsewhere, base: 11, scale: 1) == TerminalPinchOutcome(size: nil, fitHere: true))
        // At the top of the range, pinching out further is the same size.
        #expect(TerminalPinch.outcome(.fitted, base: 20, scale: 2).size == nil)
    }

    /// The size is the one every other path stores: in range, to the half point.
    @Test func theSizeFollowsTheSharedRule() {
        for state in State.allCases {
            #expect(TerminalPinch.outcome(state, base: 11, scale: 3).size == Prefs.fontSizes.upperBound)
            #expect(TerminalPinch.outcome(state, base: 11, scale: 0.1).size == Prefs.fontSizes.lowerBound)
            #expect(TerminalPinch.outcome(state, base: 13, scale: 0.97).size == Prefs.fontSize(13 * 0.97))
        }
    }

    /// Dragging a selection keeps the pinch from starting, so nothing resizes; otherwise it starts.
    @Test func aPinchDoesNotStartDuringASelection() {
        #expect(!TerminalPinch.starts(selecting: true))
        #expect(TerminalPinch.starts(selecting: false))
    }
}
