import Foundation
import Testing
@testable import RexKit

struct JSONTests {
    @Test func accessorsReadLooseNumbers() {
        let o = JSONCodec.decode(#"{"i": 3, "d": 2.5, "s": "x", "b": true, "o": {"k": 1}, "a": [{"k": 2}, 7]}"#)!
        #expect(o.int("i") == 3)
        #expect(o.int("d") == 2)
        #expect(o.dbl("i") == 3)
        #expect(o.str("s") == "x")
        #expect(o.bool("b") == true)
        #expect(o.obj("o")?.int("k") == 1)
        #expect(o.arr("a").count == 1)
        #expect(o.str("missing") == nil)
    }

    @Test func encodeRoundTrips() {
        let text = JSONCodec.encode(["type": "hello", "n": 1])
        #expect(JSONCodec.decode(text)?.str("type") == "hello")
    }
}
