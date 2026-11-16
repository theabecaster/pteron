import Synchronization
import XCTest
@testable import RexConnect

@MainActor
private final class DelegateSpy: TerminalEngineDelegate {
    var grids: [(Int, Int)] = []
    var sent: [[UInt8]] = []
    var onSend: (() -> Void)?

    func engineGridChanged(cols: Int, rows: Int) { grids.append((cols, rows)) }
    func engineSend(_ bytes: [UInt8]) { sent.append(bytes); onSend?() }
}

/// The engine seam: the stored engine kind, the factory, and the SwiftTerm adapter.
@MainActor
final class SeamTests: XCTestCase {
    private let key = "terminalEngine"
    private var saved: String?

    override func setUp() async throws {
        saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!)?[key] as? String
    }

    override func tearDown() async throws {
        if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// A `-terminalEngine` launch argument wins over the stored value; these tests can't run under one.
    private func skipIfOverridden() throws {
        try XCTSkipIf(UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil)
    }

    // MARK: Engine kind

    func testDefaultEngineIsGhostty() throws {
        try skipIfOverridden()
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(TerminalEngineKind.current, .ghostty)
        UserDefaults.standard.set("no such engine", forKey: key)
        XCTAssertEqual(TerminalEngineKind.current, .ghostty)
    }

    func testEngineKindPersistsAndPosts() throws {
        try skipIfOverridden()
        for kind in TerminalEngineKind.allCases {
            let posted = expectation(forNotification: .terminalEngineChanged, object: nil)
            TerminalEngineKind.current = kind
            wait(for: [posted], timeout: 1)
            XCTAssertEqual(UserDefaults.standard.string(forKey: key), kind.rawValue)
            XCTAssertEqual(TerminalEngineKind.current, kind)
        }
    }

    func testEveryKindHasTitleAndDetail() {
        for kind in TerminalEngineKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.detail.isEmpty)
        }
    }

    // MARK: Factory

    func testFactoryViewReportsTheEngineThatRuns() {
        for kind in TerminalEngineKind.allCases {
            let view = kind.makeView(fontSize: 11, theme: ThemeStore.fallback)
            XCTAssertEqual(view.engineKind, kind.implemented, "\(kind)")
            // The label must never claim an engine the view isn't.
            XCTAssertEqual(view is RexTerminalView, view.engineKind == .swiftTerm, "\(kind)")
        }
        XCTAssertEqual(TerminalEngineKind.swiftTerm.implemented, .swiftTerm)
    }

    // MARK: SwiftTerm adapter

    private func makeSwiftTerm() -> RexTerminalView {
        RexTerminalView(fontSize: 11, theme: ThemeStore.fallback)
    }

    func testSwiftTermFlags() {
        let view = makeSwiftTerm()
        XCTAssertEqual(view.engineKind, .swiftTerm)
        XCTAssertFalse(view.parsesOffMainThread)
        XCTAssertTrue(view.fontChangeResetsModes)
        XCTAssertFalse(view.restoreSnapshot([0x47], failed: {}))
        XCTAssertNotNil(view.selectionPressRecognizer)
        XCTAssertFalse(view.hasActiveSelection)
    }

    func testSettingTheDelegateReportsTheCurrentGrid() {
        let view = makeSwiftTerm()
        let spy = DelegateSpy()
        view.engineDelegate = spy
        XCTAssertEqual(spy.grids.count, 1)
        XCTAssertGreaterThan(spy.grids[0].0, 0)
        XCTAssertGreaterThan(spy.grids[0].1, 0)
    }

    func testSetGridReportsThroughDelegate() {
        let view = makeSwiftTerm()
        let spy = DelegateSpy()
        view.engineDelegate = spy
        spy.grids = []

        view.setGrid(cols: 100, rows: 30, force: false)
        XCTAssertEqual(spy.grids.last?.0, 100)
        XCTAssertEqual(spy.grids.last?.1, 30)

        // Same grid again: nothing to do. Forced: sized again, still the same grid.
        let n = spy.grids.count
        view.setGrid(cols: 100, rows: 30, force: false)
        XCTAssertEqual(spy.grids.count, n)
        view.setGrid(cols: 100, rows: 30, force: true)
        XCTAssertEqual(spy.grids.last?.0 ?? 100, 100)

        view.setGrid(cols: 47, rows: 12, force: false)
        XCTAssertEqual(spy.grids.last?.0, 47)
        XCTAssertEqual(spy.grids.last?.1, 12)
    }

    func testFeedAndCellSize() {
        let view = makeSwiftTerm()
        let spy = DelegateSpy()
        view.engineDelegate = spy
        view.apply(theme: ThemeStore.fallback)
        view.setGrid(cols: 80, rows: 24, force: false)

        view.feed(text: "\u{1b}c\u{1b}[3J")
        view.feed(text: "hello\r\n")
        view.feed(byteArray: Array("world \u{1b}[31mred\u{1b}[0m\r\n".utf8)[...])
        XCTAssertEqual(spy.grids.last?.0, 80, "feeding must not change the grid")

        let cell = view.cellSize
        XCTAssertTrue((4...12).contains(cell.width), "\(cell)")
        XCTAssertTrue((8...24).contains(cell.height), "\(cell)")
        XCTAssertGreaterThan(cell.height, cell.width)

        // The cell size holds across grids and grows with the font.
        view.setGrid(cols: 120, rows: 40, force: false)
        XCTAssertEqual(view.cellSize.width, cell.width, accuracy: 0.01)
        XCTAssertEqual(view.cellSize.height, cell.height, accuracy: 0.01)
        view.setFont(size: 16)
        XCTAssertGreaterThan(view.cellSize.width, cell.width)
    }

    func testTypedTextGoesToTheDelegate() {
        let view = makeSwiftTerm()
        let spy = DelegateSpy()
        view.engineDelegate = spy
        let got = expectation(description: "bytes")
        spy.onSend = { got.fulfill() }
        view.send(txt: "ls\r")
        wait(for: [got], timeout: 2)
        XCTAssertEqual(spy.sent.first, Array("ls\r".utf8))
    }

    /// SwiftTerm clears a one-shot flag after the key that used it; the key bar hears the neutral name.
    func testClearedModifiersPostTheEngineNeutralResets() {
        let view = makeSwiftTerm()
        let other = makeSwiftTerm()
        let fromOther = Mutex(0)
        let token = NotificationCenter.default.addObserver(forName: .terminalEngineControlModifierReset, object: other, queue: nil) { _ in
            fromOther.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let ctrl = expectation(forNotification: .terminalEngineControlModifierReset, object: view)
        view.controlModifier = true
        view.controlModifier = false
        wait(for: [ctrl], timeout: 1)

        let meta = expectation(forNotification: .terminalEngineMetaModifierReset, object: view)
        view.metaModifier = true
        view.metaModifier = false
        wait(for: [meta], timeout: 1)

        XCTAssertEqual(fromOther.withLock { $0 }, 0)
    }
}
