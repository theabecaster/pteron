import CryptoKit
import Foundation
import RexKit

/// How the phone makes sure the client it is about to give a secret to is the real Rex DUO Helper
/// on that server, and the same one as last time. The helper holds an ed25519 key and signs a
/// challenge; the phone pins the public half the first time, or, during an install from the app,
/// once the helper showed that install's setup proof (`HelperAdmission`, docs/notifications.md).
enum HelperIdentity {
    static let version = "rexduo-helper-identity-v1"

    enum Failure: Error, Equatable {
        /// A field is missing, or the key or signature isn't the right size.
        case malformed
        /// The reply names another client than the one that was asked.
        case wrongClient
        case badSignature
    }

    /// 32 random bytes, base64url without padding. `SystemRandomNumberGenerator` is the system's
    /// cryptographic generator on Apple platforms.
    static func challenge() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// What the helper signs. Both client ids are in it, so a third client can't pass the phone's
    /// challenge on to the real helper and present the answer as its own.
    static func message(challenge: String, helper: String, requester: String, device: String) -> Data {
        Data([version, challenge, helper, requester, device].joined(separator: "\n").utf8)
    }

    /// The helper's public key (base64, as pinned) when its `helper_identity` reply proves it holds
    /// the private half. `called` is the client the phone asked, `requester` the phone's own Rex
    /// client id, `device` its 8-hex id.
    static func verify(reply: JSONObject, challenge: String, called: String, requester: String, device: String) -> Result<String, Failure> {
        guard let keyText = reply.str("public_key"), let signatureText = reply.str("signature"), let client = reply.str("client_id"),
              let keyBytes = Data(base64Encoded: keyText), keyBytes.count == 32,
              let signature = Data(base64Encoded: signatureText), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            return .failure(.malformed)
        }
        guard client == called else { return .failure(.wrongClient) }
        let signed = message(challenge: challenge, helper: called, requester: requester, device: device)
        guard key.isValidSignature(signature, for: signed) else { return .failure(.badSignature) }
        // Encoded again, so two spellings of one key compare equal.
        return .success(keyBytes.base64EncodedString())
    }

    enum Pin: Equatable {
        /// No key is pinned for this server yet. `HelperAdmission` says whether this one is.
        case first
        case same
        /// Another key than the pinned one: hand over nothing until the user says so.
        case changed
    }

    static func pin(pinned: String?, offered: String) -> Pin {
        guard let pinned else { return .first }
        return pinned == offered ? .same : .changed
    }
}

/// Why a call to the helper failed: the error Rex passed on from the helper, or Rex's own.
struct HelperFailure: Error, Equatable {
    var code: String
    var message: String

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    init(_ error: Error) {
        if let e = error as? RexError {
            self.init(code: e.code, message: e.message)
        } else {
            self.init(code: "", message: error.localizedDescription)
        }
    }

    /// A `client.perform` reply: the helper's result, or the error object it answered with.
    static func read(_ payload: JSONObject) -> Result<JSONObject, HelperFailure> {
        if let e = payload.obj("error") {
            return .failure(HelperFailure(code: e.str("code") ?? "", message: e.str("message") ?? "error"))
        }
        return .success(payload.obj("result") ?? [:])
    }

    /// The helper doesn't know the action: it is from before this app's contract. Only meaningful
    /// for an action every current helper has; `not_supported` is also its code for other refusals.
    var isUnknownAction: Bool { code == "not_supported" || message.lowercased().contains("unknown action") }

    /// A helper from before the gateway refuses a registration that has no APNs token with this.
    var isLegacyRefusal: Bool { HelperVersion.isLegacyRefusal(message) }

    /// The helper has seen the gateway refuse this secret and won't take it again.
    var isSecretDropped: Bool { code == "secret_dropped" || message.contains("secret_dropped") }

    /// The line Settings shows.
    func sentence(helper name: String) -> String {
        let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = said.isEmpty ? "the request failed" : said
        let end = text.last.map { ".!?".contains($0) } == true ? "" : "."
        return "Rex DUO Beacon on \(name): \(text)\(end)"
    }
}

/// The name the gateway lists a helper's secret under: the server's name.
enum SecretLabel {
    static let limit = 64

    /// The gateway takes 1 to 64 printable characters. Only printable ASCII is kept, since that is
    /// certain to pass; the label is for telling secrets apart, not for display in the app.
    static func make(_ name: String) -> String {
        let kept = name.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        let clipped = String(text.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return clipped.isEmpty ? "Rex server" : clipped
    }
}
