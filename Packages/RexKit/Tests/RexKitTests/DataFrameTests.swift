import Foundation
import Testing
@testable import RexKit

struct DataFrameTests {
    @Test func ticketHello() throws {
        let ticket = Data((0..<16).map { UInt8($0) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let hello = try #require(DataFrame.ticketHello(ticket))
        #expect(hello == [0x01] + (0..<16).map { UInt8($0) })
    }

    @Test func ticketMustBe16Bytes() {
        #expect(DataFrame.ticketHello("AAAA") == nil)
        #expect(DataFrame.ticketHello("not base64 !") == nil)
    }

    @Test func resumeHelloIsLittleEndian() {
        let token = [UInt8](repeating: 0xab, count: 16)
        let hello = DataFrame.resumeHello(token: token, received: 0x0102_0304_0506_0708)
        #expect(hello.count == 25)
        #expect(hello[0] == 0x02)
        #expect(Array(hello[1..<17]) == token)
        #expect(Array(hello[17...]) == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    }

    @Test func welcomeParsesTokenAndNonce() throws {
        var b = [UInt8](repeating: 0, count: 32)
        b[0] = 0x81
        for i in 1..<17 { b[i] = UInt8(i) }
        b[24] = 0x2a  // nonce 42, little-endian
        b[25] = 0x01  // + 256
        let w = try DataFrame.welcome(b)
        #expect(w.token == (1..<17).map { UInt8($0) })
        #expect(w.nonce == 298)
    }

    @Test func refusalAndGarbageThrow() {
        #expect(throws: RexError.self) { try DataFrame.welcome([0x82, 3]) }
        #expect(throws: RexError.self) { try DataFrame.welcome([0x81, 0, 0]) }
        #expect(throws: RexError.self) { try DataFrame.welcome([]) }
    }

    @Test(arguments: [("TQ", "M"), ("TWE", "Ma"), ("TWFu", "Man"), ("-_8", "\u{fb}\u{ff}")])
    func base64urlWithAndWithoutPadding(input: String, expected: String) {
        let want: [UInt8] = expected.unicodeScalars.map { UInt8($0.value) }
        #expect(DataFrame.base64url(input) == want)
    }
}
