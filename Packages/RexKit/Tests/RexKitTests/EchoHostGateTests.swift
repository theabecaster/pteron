import XCTest
@testable import RexKit

/// The pane's main-thread gate: where a typed key may be a guess at all.
final class EchoHostGateTests: XCTestCase {
    private let shell = EchoHostConditions(foreground: "-zsh")

    func testAKeyAtAShellIsAGuess() {
        XCTAssertEqual(EchoHostGate.admit(.char(0x61), shell), .char(0x61))
        XCTAssertEqual(EchoHostGate.admit(.backspace, shell), .backspace)
        for name in ["zsh", "/bin/bash", "fish", "sh", "ssh", "-bash"] {
            XCTAssertTrue(EchoHostConditions(foreground: name).allowsGuesses, name)
        }
    }

    func testEveryConditionOfThePaneMakesAKeyABoundary() {
        var cases: [(String, EchoHostConditions)] = []
        var c = shell; c.fenced = true; cases.append(("the fence is up", c))
        c = shell; c.composing = true; cases.append(("the keyboard is composing", c))
        c = shell; c.selecting = true; cases.append(("a selection is up", c))
        c = shell; c.finding = true; cases.append(("find is open", c))
        c = shell; c.scrolledBack = true; cases.append(("the view is in the history", c))
        c = shell; c.agent = true; cases.append(("an agent runs in the pane", c))
        for name in ["vim", "claude", "node", "python3", "less", "top", "", "sleep"] {
            cases.append(("\(name) is in front", EchoHostConditions(foreground: name)))
        }
        cases.append(("the foreground is unknown", EchoHostConditions(foreground: nil)))
        for (what, conditions) in cases {
            XCTAssertFalse(conditions.allowsGuesses, what)
            XCTAssertEqual(EchoHostGate.admit(.char(0x61), conditions), .boundary(newLine: false), what)
            XCTAssertEqual(EchoHostGate.admit(.backspace, conditions), .boundary(newLine: false), what)
        }
    }

    func testABoundaryPassesAsItIs() {
        for conditions in [shell, EchoHostConditions(agent: true, foreground: "claude")] {
            XCTAssertEqual(EchoHostGate.admit(.boundary(newLine: true), conditions), .boundary(newLine: true))
            XCTAssertEqual(EchoHostGate.admit(.boundary(newLine: false), conditions), .boundary(newLine: false))
        }
    }
}
