import Foundation
import Testing
@testable import RexKit

/// Feeds chunks through an APCFilter and records what comes out, in order.
private struct Run {
    var filter = APCFilter(nonce: 42)
    var output: [UInt8] = []
    var messages: [String] = []
    /// Output and messages interleaved, to check ordering.
    var events: [String] = []

    mutating func feed(_ chunk: [UInt8]) {
        var out: [UInt8] = []
        var msgs: [String] = []
        var evs: [String] = []
        filter.process(Data(chunk), output: { b in
            out.append(contentsOf: b)
            evs.append("out:" + String(decoding: b, as: UTF8.self))
        }, message: { m in
            let t = m.str("type") ?? "?"
            msgs.append(t)
            evs.append("msg:" + t)
        })
        output += out
        messages += msgs
        events += evs
    }

    mutating func feed(_ s: String) { feed(Array(s.utf8)) }
}

private func apc(_ json: String, nonce: UInt64 = 42) -> String { "\u{1b}_rex1;\(nonce);\(json)\u{1b}\\" }

struct APCFilterTests {
    @Test func dropsSnapshotBeforeFirstMessage() {
        var r = Run()
        r.feed("GHOSTSNP binary snapshot bytes" + apc(#"{"type":"resize","cols":80,"rows":24}"#) + "hello")
        #expect(r.messages == ["resize"])
        #expect(String(decoding: r.output, as: UTF8.self) == "hello")
    }

    @Test func passesOutputThroughAfterFirstMessage() {
        var r = Run()
        r.feed(apc(#"{"type":"theme"}"#))
        let plain: [UInt8] = Array("ls -la\r\n\u{1b}[31mred\u{1b}[0m\u{1b}]0;title\u{07}".utf8) + [0x00, 0xff]
        r.feed(plain)
        #expect(r.output == plain)
    }

    @Test func trailingEscWaitsForTheNextChunk() {
        var r = Run()
        r.feed(apc(#"{"type":"resize"}"#))
        r.feed([0x61, 0x1b])
        // The ESC could start a Rex message split across chunks, so it is held back for now.
        #expect(r.output == [0x61])
    }

    @Test func twoMessagesInOneChunkKeepTheirOrder() {
        var r = Run()
        r.feed(apc(#"{"type":"resize"}"#) + "a" + apc(#"{"type":"theme"}"#) + "b")
        #expect(r.events == ["msg:resize", "out:a", "msg:theme", "out:b"])
    }

    @Test func markerSplitAtEveryOffset() {
        let stream = Array(("snapshot" + apc(#"{"type":"resize","cols":100}"#) + "after" + apc(#"{"type":"child_exited"}"#) + "tail").utf8)
        for cut in 0...stream.count {
            var r = Run()
            r.feed(Array(stream[..<cut]))
            r.feed(Array(stream[cut...]))
            #expect(r.messages == ["resize", "child_exited"], "cut at \(cut)")
            #expect(String(decoding: r.output, as: UTF8.self) == "aftertail", "cut at \(cut)")
        }
    }

    @Test func everyByteInItsOwnChunk() {
        let stream = Array((apc(#"{"type":"resize"}"#) + "x\u{1b}[1my" + apc(#"{"type":"theme"}"#)).utf8)
        var r = Run()
        for b in stream { r.feed([b]) }
        #expect(r.messages == ["resize", "theme"])
        #expect(String(decoding: r.output, as: UTF8.self) == "x\u{1b}[1my")
    }

    @Test func otherNoncesAreOutput() {
        var r = Run()
        r.feed(apc(#"{"type":"resize"}"#))
        let foreign = apc(#"{"type":"spoof"}"#, nonce: 7)
        r.feed(foreign)
        #expect(r.messages == ["resize"])
        #expect(String(decoding: r.output, as: UTF8.self) == foreign)
    }

    @Test func loneTrailingEscIsOutput() {
        var r = Run()
        r.feed(apc(#"{"type":"resize"}"#))
        r.feed([0x61, 0x1b])
        r.feed(Array("[0m".utf8))
        #expect(String(decoding: r.output, as: UTF8.self) == "a\u{1b}[0m")
    }

    @Test func unterminatedMessageOverLimitIsDropped() {
        var r = Run()
        r.feed(apc(#"{"type":"resize"}"#))
        // A marker with no ST, then more than 4 MB: the filter gives up on it instead of buffering forever.
        r.feed("\u{1b}_rex1;42;{\"type\":\"x\",\"pad\":\"")
        r.feed([UInt8](repeating: 0x41, count: 4 * 1024 * 1024 + 1))
        r.feed(apc(#"{"type":"theme"}"#) + "ok")
        #expect(r.messages.last == "theme")
        #expect(String(decoding: r.output, as: UTF8.self).hasSuffix("ok"))
    }
}
