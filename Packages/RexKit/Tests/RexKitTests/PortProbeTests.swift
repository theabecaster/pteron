import Foundation
import Testing
@testable import RexKit

/// Replies as real servers send them to `GET /`, and what each one means.
struct PortProbeClassifyTests {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func webSocketServersAreNoWebPage() {
        // An editor plugin's server on Bun or `ws` (Claude Code's IDE link in nvim).
        let bun = "HTTP/1.1 400 Bad Request\r\ncontent-type: text/plain;charset=utf-8\r\nDate: Sat, 21 Nov 2026 10:00:00 GMT\r\n"
            + "Content-Length: 64\r\n\r\nBad WebSocket upgrade request: Missing or invalid Upgrade header"
        #expect(PortProbe.classify(bytes(bun)) == .notWeb)
        // Node's `ws` with a port of its own answers every plain request with 426.
        let ws = "HTTP/1.1 426 Upgrade Required\r\nContent-Type: text/plain\r\nDate: Sat, 21 Nov 2026 10:00:00 GMT\r\n"
            + "Connection: close\r\nContent-Length: 16\r\n\r\nUpgrade Required"
        #expect(PortProbe.classify(bytes(ws)) == .notWeb)
        // The words may be in the headers only.
        #expect(PortProbe.classify(bytes("HTTP/1.1 400 Bad Request\r\nUpgrade: WebSocket\r\nSec-WebSocket-Version: 13\r\n\r\n")) == .notWeb)
    }

    @Test func everyOtherHTTPReplyIsAWebServer() {
        let vite = "HTTP/1.1 200 OK\r\nVary: Origin\r\nContent-Type: text/html\r\nCache-Control: no-cache\r\nEtag: W/\"1f4-abc\"\r\n"
            + "Date: Sat, 21 Nov 2026 10:00:00 GMT\r\nConnection: close\r\n\r\n<!doctype html>\n<html lang=\"en\">\n  <head>\n"
            + "    <script type=\"module\" src=\"/@vite/client\"></script>\n"
        #expect(PortProbe.classify(bytes(vite)) == .web)
        // A dev server with no page at `/` is still a web server.
        let next = "HTTP/1.1 404 Not Found\r\nCache-Control: no-store, must-revalidate\r\nX-Powered-By: Next.js\r\n"
            + "Content-Type: text/html; charset=utf-8\r\nDate: Sat, 21 Nov 2026 10:00:00 GMT\r\nConnection: close\r\n\r\n<!DOCTYPE html><html>"
        #expect(PortProbe.classify(bytes(next)) == .web)
        let python = "HTTP/1.0 200 OK\r\nServer: SimpleHTTP/0.6 Python/3.12.4\r\nDate: Sat, 21 Nov 2026 10:00:00 GMT\r\n"
            + "Content-type: text/html; charset=utf-8\r\nContent-Length: 512\r\n\r\n<!DOCTYPE HTML>\n<html lang=\"en\">"
        #expect(PortProbe.classify(bytes(python)) == .web)
        for status in ["401 Unauthorized", "403 Forbidden", "500 Internal Server Error", "302 Found", "101 Switching Protocols"] {
            #expect(PortProbe.classify(bytes("HTTP/1.1 \(status)\r\nContent-Length: 0\r\n\r\n")) == .web, "\(status)")
        }
        // Go's HTTPS server answering plain HTTP: a 400 about something else.
        #expect(PortProbe.classify(bytes("HTTP/1.0 400 Bad Request\r\n\r\nClient sent an HTTP request to an HTTPS server.\n")) == .web)
        // HTTP/0.9: the page alone.
        #expect(PortProbe.classify(bytes("  <!DOCTYPE html><html><body>hi")) == .web)
        #expect(PortProbe.classify(bytes("<html><body>")) == .web)
    }

    @Test func noReplyOrTLSIsUnknown() {
        #expect(PortProbe.classify(Data()) == .unknown, "an empty close")
        // A TLS alert (HTTPS-only server, vite --https) and a handshake record.
        #expect(PortProbe.classify(Data([0x15, 0x03, 0x01, 0x00, 0x02, 0x02, 0x46])) == .unknown)
        #expect(PortProbe.classify(Data([0x16, 0x03, 0x03, 0x00, 0x7a, 0x02])) == .unknown)
    }

    @Test func otherProtocolsAreNoWebPage() {
        #expect(PortProbe.classify(bytes("-ERR unknown command 'GET', with args beginning with: '/' 'HTTP/1.1' \r\n")) == .notWeb)
        #expect(PortProbe.classify(bytes("SSH-2.0-OpenSSH_9.6\r\n")) == .notWeb)
        #expect(PortProbe.classify(Data([0x00, 0x00, 0x12, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00])) == .notWeb, "an h2c frame")
        #expect(PortProbe.classify(bytes("-")) == .notWeb)
    }

    @Test func aPartialHeaderDecidesOnlyFromWhatItHas() {
        #expect(PortProbe.classify(bytes("HT")) == .unknown)
        #expect(PortProbe.classify(bytes("HTTP/1.")) == .unknown)
        #expect(PortProbe.classify(bytes("HTTP/1.1 20")) == .unknown)
        #expect(PortProbe.classify(bytes("HTTP/1.1 200 OK\r\nContent-Ty")) == .web)
        #expect(PortProbe.classify(bytes("HTTP/1.1 400 Bad Re")) == .web, "a 400 that hasn't said why is a web server")
        #expect(PortProbe.classify(bytes("HTTP/1.1 4x6 Huh\r\n\r\n")) == .unknown)
        #expect(PortProbe.classify(bytes("<!doc")) == .unknown)
        #expect(!PortProbe.settled(bytes("HTTP/1.1 400 Bad Request\r\n\r\n")), "a 400 reads on for its reason")
        #expect(PortProbe.settled(bytes("HTTP/1.1 200 OK\r\n")))
        #expect(PortProbe.settled(bytes("-ERR")))
    }

    @Test func theRequestAsksForTheRootAndCloses() {
        let r = String(decoding: PortProbe.request(port: 5173), as: UTF8.self)
        #expect(r == "GET / HTTP/1.1\r\nHost: localhost:5173\r\nAccept: */*\r\nConnection: close\r\n\r\n")
        #expect(!r.lowercased().contains("cookie"))
    }
}

/// The probe's one exchange on a tunnel connection.
struct PortProbeReadTests {
    /// A sleep that never ends by itself: the read must not depend on the clock.
    static let never: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

    @Test func readsTheWholeReplyAndDropsTheConnection() async {
        let s = FakeTunnelSocket()
        s.push(Data("HTTP/1.1 400 Bad Request\r\n\r\nBad WebSocket ".utf8))
        s.push(Data("upgrade request".utf8))
        s.push(Data())
        let got = await PortProbe.read(s, port: 10955, sleep: Self.never)
        #expect(PortProbe.classify(got) == .notWeb)
        #expect(s.sent == [PortProbe.request(port: 10955)], "one request, and no end of data from the phone")
        #expect(s.aborted)
    }

    @Test func stopsOnceTheVerdictIsSettled() async {
        let s = FakeTunnelSocket()
        // A page that streams forever: the status is enough.
        s.push(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8))
        let got = await PortProbe.read(s, port: 3000, sleep: Self.never)
        #expect(PortProbe.classify(got) == .web)
        #expect(s.aborted)
    }

    @Test func readsAtMostTheLimit() async {
        let s = FakeTunnelSocket()
        s.push(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
        s.push(Data(repeating: 0x61, count: 5000))
        s.push(Data(repeating: 0x61, count: 5000))
        let got = await PortProbe.read(s, port: 3000, sleep: Self.never)
        #expect(got.count == PortProbe.replyLimit)
        #expect(PortProbe.classify(got) == .web)
    }

    @Test func aRefusedTargetGivesNothing() async {
        let s = FakeTunnelSocket()
        s.serverClose(1001)
        let got = await PortProbe.read(s, port: 3000, sleep: Self.never)
        #expect(got.isEmpty)
        #expect(PortProbe.classify(got) == .unknown)
    }

    @Test func aSilentServerEndsAtTheDeadline() async {
        let (asked, c) = AsyncStream<Duration>.makeStream()
        let clock = TickClock(asked: c)
        let s = FakeTunnelSocket()
        let read = Task { await PortProbe.read(s, port: 3000, sleep: { try await clock.sleep($0) }) }
        var it = asked.makeAsyncIterator()
        #expect(await it.next() == PortProbe.replyWait)
        clock.tick()
        let got = await read.value
        #expect(got.isEmpty)
        #expect(s.aborted)
    }

    @Test func whatCameBeforeTheDeadlineIsTheAnswer() async {
        let (asked, c) = AsyncStream<Duration>.makeStream()
        let clock = TickClock(asked: c)
        let s = FakeTunnelSocket()
        s.push(Data("HTTP/1.1 400 Bad Request\r\nUpgrade: websocket\r\n".utf8))
        let read = Task { await PortProbe.read(s, port: 3000, sleep: { try await clock.sleep($0) }) }
        var it = asked.makeAsyncIterator()
        _ = await it.next()
        clock.tick()
        #expect(PortProbe.classify(await read.value) == .notWeb)
    }
}

/// Which ports are asked, when, and what shows meanwhile.
struct PortProbeBookTests {
    typealias Key = PortProbeBook.Key
    let vite = Key(pid: 10, port: 5173, host: "127.0.0.1")
    let nvim = Key(pid: 20, port: 10955, host: "127.0.0.1")
    let pane = PortProbeBook.Place(session: "session:1", block: "block:1a")
    let other = PortProbeBook.Place(session: "session:1", block: "block:1b")

    @Test func aNewPortIsHeldUntilItsProbeAnswers() {
        var b = PortProbeBook()
        b.update([vite: pane, nvim: pane], relisted: [vite, nvim], now: 0, canProbe: true)
        #expect(b.hidden(vite, now: 0) && b.hidden(nvim, now: 0))
        let jobs = b.start()
        #expect(jobs.map(\.key) == [vite, nvim], "in port order")
        #expect(jobs.allSatisfy { $0.session == "session:1" })
        let took1 = b.finish(jobs[0], .web)
        #expect(took1)
        let took2 = b.finish(jobs[1], .notWeb)
        #expect(took2)
        #expect(!b.hidden(vite, now: 0.2))
        #expect(b.hidden(nvim, now: 0.2))
        #expect(b.hidden(nvim, now: 100), "notWeb is final")
        #expect(b.nextRelease(now: 0.2) == nil)
    }

    @Test func aSlowProbeLetsTheRowShowAfterTheHold() {
        var b = PortProbeBook()
        b.update([vite: pane], relisted: [], now: 10, canProbe: true)
        let job = b.start()[0]
        #expect(b.nextRelease(now: 10) == 10 + PortProbeBook.hold)
        #expect(b.hidden(vite, now: 11.4))
        #expect(!b.hidden(vite, now: 11.5))
        #expect(b.nextRelease(now: 11.5) == nil)
        // It answers late that it is no web page after all: it goes.
        b.finish(job, .notWeb)
        #expect(b.hidden(vite, now: 12))
    }

    @Test func unknownShowsAndIsAskedAgainOncePerNewListing() {
        var b = PortProbeBook()
        b.update([vite: pane], relisted: [vite], now: 0, canProbe: true)
        b.finish(b.start()[0], .unknown)
        #expect(!b.hidden(vite, now: 0.1))
        // The same list again, or another pane's new list: nothing is asked.
        b.update([vite: pane], relisted: [], now: 1, canProbe: true)
        b.update([vite: pane], relisted: [], now: 1, canProbe: true)
        #expect(b.start().isEmpty)
        // Its pane's list is new: asked once more, shown meanwhile.
        b.update([vite: pane], relisted: [vite], now: 2, canProbe: true)
        let again = b.start()
        #expect(again.map(\.key) == [vite])
        #expect(!b.hidden(vite, now: 2))
        b.update([vite: pane], relisted: [vite], now: 3, canProbe: true)
        #expect(b.start().isEmpty, "running: not asked twice")
        b.finish(again[0], .web)
        b.update([vite: pane], relisted: [vite], now: 4, canProbe: true)
        #expect(b.start().isEmpty, "web is final")
    }

    @Test func whileProbesCantRunANewPortShowsAtOnce() {
        var b = PortProbeBook()
        b.update([vite: pane], relisted: [vite], now: 0, canProbe: false)
        #expect(!b.hidden(vite, now: 0))
        #expect(b.verdict(vite) == .unknown)
        #expect(b.start().isEmpty)
        b.update([vite: pane], relisted: [vite], now: 5, canProbe: true)
        #expect(b.start().map(\.key) == [vite])
        #expect(!b.hidden(vite, now: 5), "it showed already: no hold")
    }

    @Test func atMostTwoProbesRunAtOnce() {
        var b = PortProbeBook()
        let keys = (0..<6).map { Key(pid: 100 + $0, port: 3000 + $0, host: "127.0.0.1") }
        b.update(Dictionary(uniqueKeysWithValues: keys.map { ($0, pane) }), relisted: [], now: 0, canProbe: true)
        let first = b.start()
        #expect(first.map(\.key) == Array(keys[0..<2]))
        #expect(b.start().isEmpty)
        #expect(b.running == 2)
        b.finish(first[0], .web)
        let next = b.start()
        #expect(next.map(\.key) == [keys[2]])
        b.finish(first[1], .unknown)
        b.finish(next[0], .web)
        #expect(b.start().map(\.key) == [keys[3], keys[4]])
    }

    @Test func aRestartUnderANewPidIsAskedAgainWithoutABlink() {
        var b = PortProbeBook()
        b.update([vite: pane], relisted: [], now: 0, canProbe: true)
        b.finish(b.start()[0], .web)
        // The server stops: its port goes. Then it is back under another pid.
        b.update([:], relisted: [], now: 5, canProbe: true)
        #expect(b.verdict(vite) == nil, "dropped with its port")
        let restarted = Key(pid: 11, port: 5173, host: "127.0.0.1")
        b.update([restarted: pane], relisted: [restarted], now: 8, canProbe: true)
        #expect(!b.hidden(restarted, now: 8), "it took a shown row's place")
        let job = b.start()
        #expect(job.map(\.key) == [restarted], "asked again")
        // The pid changed in one listing too.
        let third = Key(pid: 12, port: 5173, host: "127.0.0.1")
        b.update([third: pane], relisted: [third], now: 9, canProbe: true)
        #expect(!b.hidden(third, now: 9))
        let took3 = b.finish(job[0], .notWeb)
        #expect(!took3, "the old process's answer is dropped")
        #expect(b.start().map(\.key) == [third])
    }

    @Test func aPortThatWentLongAgoIsNewAgain() {
        var b = PortProbeBook()
        b.update([vite: pane], relisted: [], now: 0, canProbe: true)
        b.finish(b.start()[0], .web)
        b.update([:], relisted: [], now: 1, canProbe: true)
        let later = Key(pid: 99, port: 5173, host: "127.0.0.1")
        b.update([later: pane], relisted: [], now: 1 + PortProbeBook.goneLife + 1, canProbe: true)
        #expect(b.hidden(later, now: 62.5))
    }

    @Test func aHiddenPortThatGoesIsNoTakeOver() {
        var b = PortProbeBook()
        b.update([nvim: pane], relisted: [], now: 0, canProbe: true)
        b.finish(b.start()[0], .notWeb)
        b.update([:], relisted: [], now: 1, canProbe: true)
        let back = Key(pid: 21, port: 10955, host: "127.0.0.1")
        b.update([back: pane], relisted: [], now: 2, canProbe: true)
        #expect(b.hidden(back, now: 2), "held: no row was shown for that port")
    }

    @Test func anAnswerForAClosedPaneIsDropped() {
        var b = PortProbeBook()
        b.update([vite: pane], relisted: [], now: 0, canProbe: true)
        let job = b.start()[0]
        b.update([:], relisted: [], now: 0.5, canProbe: true)
        let took4 = b.finish(job, .web)
        #expect(!took4)
        #expect(b.verdict(vite) == nil)
        #expect(b.running == 0, "its slot is free")
        // The same port back in a new pane is asked anew; the old answer still changes nothing.
        b.update([vite: other], relisted: [], now: 1, canProbe: true)
        let again = b.start()
        #expect(again.map(\.session) == ["session:1"])
        let took5 = b.finish(job, .web)
        #expect(!took5)
        let took6 = b.finish(again[0], .web)
        #expect(took6)
    }

    @Test func onePortInTwoPanesIsAskedOnce() {
        var b = PortProbeBook()
        b.update([vite: pane], relisted: [], now: 0, canProbe: true)
        b.update([vite: other], relisted: [vite], now: 0.1, canProbe: true)
        #expect(b.start().count == 1)
        #expect(b.start().isEmpty)
    }

    @Test func goingOfflineMidProbeShows() {
        var b = PortProbeBook()
        b.update([vite: pane], relisted: [], now: 0, canProbe: true)
        let job = b.start()[0]
        // The tunnel dropped under the probe: no bytes, unknown.
        b.finish(job, PortProbe.classify(Data()))
        #expect(!b.hidden(vite, now: 0.3))
        // Back online, the same list read again on the new connection asks once more.
        b.update([vite: pane], relisted: [vite], now: 30, canProbe: true)
        #expect(b.start().count == 1)
    }
}
