import RexKit
import XCTest
@testable import RexDuo

/// A prompt click while predicted echo's guesses are drawn: sent at once, counted from the cursor
/// on screen. The program's cursor is on column 12 of row 0 and the guesses put the cursor on
/// screen on column 20, unless a test says otherwise.
final class EchoPromptClickTests: XCTestCase {
    private func facts(tap: Int, row: Int = 0, real: Int = 12, predicted: Int = 20, predictedRow: Int = 0, wide: Bool = false) -> EchoTapFacts {
        EchoTapFacts(tap: .init(col: tap, row: row), real: .init(col: real, row: 0), predicted: .init(col: predicted, row: predictedRow), wide: wide)
    }

    /// On text the program has: the engine's count from its own cursor, and the pending keys.
    func testOnRealTextTheEnginesCountGetsThePendingKeysOnTop() {
        XCTAssertEqual(EchoPromptClick.click(engine: .keys(left: 8, right: 0), nearReal: false, facts(tap: 4)), .keys(left: 16, right: 0))
        // Pending Backspaces: the cursor on screen is left of the program's.
        XCTAssertEqual(EchoPromptClick.click(engine: .keys(left: 8, right: 0), nearReal: false, facts(tap: 4, predicted: 10)), .keys(left: 6, right: 0))
        // Near the program's cursor the engine counted nothing: the columns are counted.
        XCTAssertEqual(EchoPromptClick.click(engine: .none, nearReal: true, facts(tap: 10)), .keys(left: 10, right: 0))
        // A tap the engine made nothing of, away from its cursor, stays nothing.
        XCTAssertEqual(EchoPromptClick.click(engine: .none, nearReal: false, facts(tap: 1)), GhosttyPromptClick.none)
    }

    /// On a guessed cell: the columns to the cursor on screen.
    func testOnAGuessedCellTheColumnsToTheCursorOnScreenAreCounted() {
        XCTAssertEqual(EchoPromptClick.click(engine: .none, nearReal: true, facts(tap: 13)), .keys(left: 7, right: 0))
        XCTAssertEqual(EchoPromptClick.click(engine: .none, nearReal: false, facts(tap: 16)), .keys(left: 4, right: 0))
        // Right of the cursor on screen there is nothing to move to.
        XCTAssertEqual(EchoPromptClick.click(engine: .none, nearReal: false, facts(tap: 30)), GhosttyPromptClick.none)
    }

    /// Near the cursor on screen a tap moves nothing, as near the program's cursor without
    /// guesses.
    func testNearTheCursorOnScreenATapMovesNothing() {
        for tap in 17...23 {
            XCTAssertEqual(EchoPromptClick.click(engine: .none, nearReal: false, facts(tap: tap)), GhosttyPromptClick.none, "column \(tap)")
        }
    }

    /// A wrapped input line or a wide character on the row: the engine's own count from the
    /// program's cursor, as without predicted echo.
    func testAWrappedLineOrAWideCharacterFallsBackToTheEnginesCount() {
        let engine = GhosttyPromptClick.keys(left: 8, right: 0)
        XCTAssertEqual(EchoPromptClick.click(engine: engine, nearReal: false, facts(tap: 4, wide: true)), engine, "a wide character")
        XCTAssertEqual(EchoPromptClick.click(engine: engine, nearReal: false, facts(tap: 4, row: 1)), engine, "a tap on another row of the line")
        XCTAssertEqual(EchoPromptClick.click(engine: engine, nearReal: false, facts(tap: 4, predictedRow: 1)), engine, "guesses on another row")
        XCTAssertEqual(EchoPromptClick.click(engine: .none, nearReal: true, facts(tap: 10, wide: true)), GhosttyPromptClick.none,
                       "near the program's cursor nothing moves, as without guesses")
    }
}
