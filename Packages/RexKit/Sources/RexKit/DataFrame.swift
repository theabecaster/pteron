import Foundation

/// The binary handshake of a terminal data socket (`/api/data`, subprotocol `rex.data.terminal.v1`).
///
/// - Client hello: `0x01` + the 16-byte ticket from `data.connect`.
/// - Client resume: `0x02` + the 16-byte resume token + bytes received so far (UInt64, little-endian).
/// - Server refusal: `0x82` + a reason byte.
/// - Server welcome: `0x81`, 32 bytes, resume token at 1..<17, nonce (UInt64 LE) at 24..<32.
///   The nonce marks Rex's own APC messages in the stream (see `APCFilter`).
public enum DataFrame {
    public struct Welcome: Equatable, Sendable {
        public var token: [UInt8]
        public var nonce: UInt64
    }

    /// The hello for a ticket in base64url, or nil if it isn't 16 bytes.
    public static func ticketHello(_ ticket: String) -> [UInt8]? {
        guard let t = base64url(ticket), t.count == 16 else { return nil }
        return [0x01] + t
    }

    public static func resumeHello(token: [UInt8], received: UInt64) -> [UInt8] {
        var hello: [UInt8] = [0x02] + token
        var c = received
        for _ in 0..<8 { hello.append(UInt8(c & 0xff)); c >>= 8 }
        return hello
    }

    /// Parses the server's first frame. Throws on a refusal or anything that isn't a welcome.
    public static func welcome(_ b: [UInt8]) throws -> Welcome {
        if b.first == 0x82 {
            throw RexError.local("stream refused (reason \(b.count > 1 ? Int(b[1]) : 0))")
        }
        guard b.count == 32, b[0] == 0x81 else { throw RexError.local("bad welcome") }
        var nonce: UInt64 = 0
        for k in 0..<8 { nonce |= UInt64(b[24 + k]) << (8 * UInt64(k)) }
        return Welcome(token: Array(b[1..<17]), nonce: nonce)
    }

    /// Decodes base64url (RFC 4648 §5), with or without padding.
    public static func base64url(_ s: String) -> [UInt8]? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        return [UInt8](d)
    }
}
