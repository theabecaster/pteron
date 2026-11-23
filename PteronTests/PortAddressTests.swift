import XCTest
import RexKit
@testable import Pteron

/// A typed address of a dev server: what it names, and which computers listen there.
@MainActor
final class PortAddressTests: XCTestCase {
    private func local(_ s: String) -> PortAddress? {
        if case .local(let a)? = PortAddress.parse(s) { return a }
        return nil
    }

    private func row(_ port: Int, block: String = "block:1", program: String? = "node", folder: String? = "/srv/anchor") -> PortRow {
        PortRow(sessionID: "session:1", blockID: block,
                entry: PortEntry(port: port, dialHost: "127.0.0.1", process: program, pid: 7, program: program, folder: folder))
    }

    private let a = UUID(), b = UUID(), c = UUID()

    private func machines(bOnline: Bool = true) -> [PortAddress.Machine] {
        [PortAddress.Machine(id: a, name: "Desk", online: true, rows: [row(3000), row(5173, block: "block:2")]),
         PortAddress.Machine(id: b, name: "Mini", online: bOnline, rows: [row(3000, program: "Python", folder: "/srv/site")]),
         PortAddress.Machine(id: c, name: "Lab", online: true, rows: [])]
    }

    // MARK: Parsing

    func testTheThreeFormsNameTheSamePort() {
        XCTAssertEqual(local("localhost:3000"), PortAddress(scheme: "http", shown: "localhost:3000", port: 3000, rest: "/"))
        XCTAssertEqual(local("127.0.0.1:3000"), PortAddress(scheme: "http", shown: "127.0.0.1:3000", port: 3000, rest: "/"))
        XCTAssertEqual(local(":3000"), PortAddress(scheme: "http", shown: "localhost:3000", port: 3000, rest: "/"))
        XCTAssertEqual(local("  localhost:3000 ")?.port, 3000)
    }

    func testTheOtherLocalFormsCountToo() {
        XCTAssertEqual(local("[::1]:3000")?.shown, "[::1]:3000")
        XCTAssertEqual(local("0.0.0.0:3000")?.shown, "0.0.0.0:3000")
        XCTAssertEqual(local("http://localhost:3000")?.scheme, "http")
        XCTAssertEqual(local("https://localhost:3000"), PortAddress(scheme: "https", shown: "localhost:3000", port: 3000, rest: "/"))
    }

    func testATypedPathAndQueryAreKept() {
        let typed = local("localhost:3000/admin?x=1#top")
        XCTAssertEqual(typed?.rest, "/admin?x=1#top")
        XCTAssertEqual(typed?.text, "localhost:3000/admin?x=1#top")
        XCTAssertEqual(local(":3000/a b"), nil, "a space is no address")
        XCTAssertEqual(local(":3000")?.text, "localhost:3000")
    }

    func testWhatIsNoAddress() {
        for s in ["3000", "next", "localhost", "", ":", ":0", ":99999", "ftp://localhost:3000", "localhost:abc", "open localhost:3000"] {
            XCTAssertNil(PortAddress.parse(s), s)
        }
    }

    func testAnAddressSomewhereElseIsNotLocal() throws {
        XCTAssertEqual(PortAddress.parse("example.com"), .elsewhere(try XCTUnwrap(URL(string: "http://example.com"))))
        XCTAssertEqual(PortAddress.parse("https://example.com/docs?a=1"), .elsewhere(try XCTUnwrap(URL(string: "https://example.com/docs?a=1"))))
        // Another machine's address is not this one's loopback either.
        XCTAssertEqual(PortAddress.parse("172.16.0.9:3000"), .elsewhere(try XCTUnwrap(URL(string: "http://172.16.0.9:3000"))))
        XCTAssertEqual(PortAddress.parse("192.0.2.7:8080/x"), .elsewhere(try XCTUnwrap(URL(string: "http://192.0.2.7:8080/x"))))
    }

    // MARK: Matching

    func testNoneOneAndSeveralMachines() throws {
        let m = machines()
        XCTAssertEqual(PortAddress.matches(try XCTUnwrap(local(":9999")), in: m), [])
        let one = PortAddress.matches(try XCTUnwrap(local("127.0.0.1:5173")), in: m)
        XCTAssertEqual(one.map(\.serverID), [a])
        XCTAssertEqual(one.first?.row.blockID, "block:2")
        let two = PortAddress.matches(try XCTUnwrap(local("localhost:3000/admin")), in: m)
        XCTAssertEqual(two.map(\.serverID), [a, b], "one row a machine, in the sidebar's order")
        XCTAssertEqual(two.map(\.title), ["Desk · Node · anchor", "Mini · Python · site"])
        XCTAssertEqual(PortAddress.nothing(try XCTUnwrap(local(":9999"))), "Nothing is running on localhost:9999 on your computers.")
    }

    func testAnOfflineMachineIsLeftOut() throws {
        let found = PortAddress.matches(try XCTUnwrap(local(":3000")), in: machines(bOnline: false))
        XCTAssertEqual(found.map(\.serverID), [a])
    }

    func testAskingCostsNothingPerKeystroke() throws {
        // Ten machines with ten ports each, and a query typed a character at a time.
        let many = (0..<10).map { m in
            PortAddress.Machine(id: UUID(), name: "M\(m)", online: true, rows: (0..<10).map { row(3000 + $0, block: "block:\(m)-\($0)") })
        }
        let typed = ["l", "lo", "localhost", "localhost:", "localhost:3", "localhost:30", "localhost:300", "localhost:3009", "localhost:3009/admin"]
        let rounds = 500
        let start = ContinuousClock.now
        var found = 0
        for _ in 0..<rounds {
            for q in typed {
                if case .local(let address)? = PortAddress.parse(q) { found += PortAddress.matches(address, in: many).count }
            }
        }
        let each = (ContinuousClock.now - start) / (rounds * typed.count)
        let micros = Double(each.components.attoseconds) / 1e12
        print("PORT_ADDRESS_TIMING \(String(format: "%.2f", micros)) us a keystroke, 10 machines x 10 ports")
        XCTAssertEqual(found, rounds * 2 * 10)
        XCTAssertLessThan(each, .milliseconds(1), "far under a frame, even in a debug build")
    }

    // MARK: Go to Anything

    func testThePaletteListsOneRowAMachineForATypedAddress() throws {
        let m = machines()
        let (rows, runs) = GoToModel.addressRows("localhost:3000/admin?x=1", scope: .anything) { PortAddress.matches($0, in: m) }
        XCTAssertEqual(rows.map(\.title), ["Desk · Node · anchor", "Mini · Python · site"])
        XCTAssertEqual(rows.map(\.subtitle), ["localhost:3000/admin?x=1", "localhost:3000/admin?x=1"])
        guard case .address(let server, let rowID, let address)? = runs[try XCTUnwrap(rows.last?.id)] else { return XCTFail("the row opens the address") }
        XCTAssertEqual(server, b)
        XCTAssertEqual(rowID, "block:1:3000")
        XCTAssertEqual(address.rest, "/admin?x=1")
        XCTAssertEqual(address.shown, "localhost:3000")
    }

    func testThePaletteSaysWhenNothingListensAndKeepsQuietOtherwise() {
        let m = machines()
        let (none, runs) = GoToModel.addressRows(":9999", scope: .anything) { PortAddress.matches($0, in: m) }
        XCTAssertEqual(none.map(\.title), ["Nothing is running on localhost:9999 on your computers."])
        XCTAssertEqual(none.first?.dimmed, true)
        XCTAssertTrue(runs.isEmpty)
        // A bare number, a word and an address elsewhere add no row; nor does the commands scope.
        for q in ["3000", "next", "example.com"] {
            XCTAssertTrue(GoToModel.addressRows(q, scope: .anything) { PortAddress.matches($0, in: m) }.0.isEmpty, q)
        }
        XCTAssertTrue(GoToModel.addressRows(":3000", scope: .commands) { PortAddress.matches($0, in: m) }.0.isEmpty)
    }

    // MARK: The browser's address line

    @MainActor
    private final class Seen {
        var said: [String] = []
        var left: [URL] = []
    }

    private func actions(_ seen: Seen, _ machines: [PortAddress.Machine]) -> PortActions {
        var parts = PortActions.Parts()
        parts.notify = { text, _ in seen.said.append(text) }
        parts.openURL = { seen.left.append($0) }
        parts.machines = { machines }
        return PortActions(model: nil, parts: parts)
    }

    /// A browser showing Desk's port 3000 from the phone's own listener on another port.
    private func browser() throws -> PreviewBrowser {
        let page = PreviewPage(load: try XCTUnwrap(URL(string: "http://localhost:49200/")), shown: "localhost:3000",
                               source: PortActions.source(a, port: 3000))
        return PreviewBrowser(page: page, onClose: {})
    }

    func testGoOnTheSameServerMovesThePageAndShowsTheAddressAsTyped() throws {
        let seen = Seen(), b = try browser()
        let ports = actions(seen, machines(bOnline: false))
        XCTAssertEqual(ports.go("127.0.0.1:3000/admin?x=1", from: b), .moved)
        XCTAssertEqual(b.page.shown, "127.0.0.1:3000", "as typed")
        XCTAssertEqual(PreviewAddress.load("/admin?x=1", b.page)?.absoluteString, "http://localhost:49200/admin?x=1",
                       "what loads is still the phone's listener")
        XCTAssertEqual(seen.said, [])
        XCTAssertEqual(seen.left, [])
    }

    func testGoToAPortOfAnotherMachineOpensThatOne() throws {
        let seen = Seen(), br = try browser()
        var m = machines()
        m[0].rows = []
        XCTAssertEqual(actions(seen, m).go(":3000", from: br), .opened(b))
    }

    func testGoWithSeveralMachinesAsksWhich() throws {
        let seen = Seen(), br = try browser()
        guard case .asked(let found) = actions(seen, machines()).go("localhost:3000/admin", from: br) else { return XCTFail("a list asks which machine") }
        XCTAssertEqual(found.map(\.title), ["Desk · Node · anchor", "Mini · Python · site"])
        XCTAssertEqual(br.page.shown, "localhost:3000", "nothing moved before an answer")
    }

    func testGoToNothingSaysSoAndStays() throws {
        let seen = Seen(), br = try browser()
        XCTAssertEqual(actions(seen, machines()).go("localhost:9999", from: br), .nothing)
        XCTAssertEqual(br.said, ["Nothing is running on localhost:9999 on your computers."], "said over the page, where it is seen")
        XCTAssertEqual(seen.said, [])
        XCTAssertEqual(br.page.shown, "localhost:3000")
    }

    func testAnAddressSomewhereElseLeavesForTheSystemsBrowser() throws {
        let seen = Seen(), br = try browser()
        let url = try XCTUnwrap(URL(string: "http://example.com"))
        XCTAssertEqual(actions(seen, machines()).go("example.com", from: br), .elsewhere(url))
        XCTAssertEqual(seen.left, [url])
        XCTAssertNil(br.webView, "nothing was loaded here")
        XCTAssertEqual(br.page.shown, "localhost:3000")
        XCTAssertEqual(actions(seen, machines()).go("next", from: br), .notAnAddress)
        XCTAssertEqual(br.said, ["That isn't an address. Try localhost:3000."])
        XCTAssertEqual(seen.left, [url])
    }

    func testTheAddressLineEditsTheAddressAsShownWithThePathOnScreen() throws {
        let page = PreviewPage(load: try XCTUnwrap(URL(string: "http://localhost:49200/")), shown: "0.0.0.0:8000")
        XCTAssertEqual(PreviewAddress.editing(URL(string: "http://localhost:49200/a/b?c=1"), page), "0.0.0.0:8000/a/b?c=1")
        XCTAssertEqual(PreviewAddress.editing(nil, page), "0.0.0.0:8000")
        XCTAssertEqual(PreviewAddress.editing(URL(string: "https://example.com/x"), page), "https://example.com/x")
    }
}
