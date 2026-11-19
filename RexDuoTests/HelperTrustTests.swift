import CryptoKit
import Foundation
import GlanceModel
import Testing
import RexKit
@testable import RexDuo

/// How the phone checks that a helper is the one it pinned, and how it reads a helper's refusals.
struct HelperTrustTests {
    private let key = Curve25519.Signing.PrivateKey()
    private let challenge = "Zm9yLXRlc3RzLW9ubHktMzItYnl0ZXMtb2YtY2hhbGxlbmdl"
    private let helper = "client:helper"
    private let phone = "client:phone"
    private let device = "a1b2c3d4"

    /// What a helper answers, signing the message built from the given parts.
    private func reply(signedBy signer: Curve25519.Signing.PrivateKey? = nil, challenge c: String? = nil, helper h: String? = nil,
                       requester: String? = nil, device d: String? = nil, clientID: String? = nil) throws -> JSONObject {
        let signer = signer ?? key
        let message = HelperIdentity.message(challenge: c ?? challenge, helper: h ?? helper, requester: requester ?? phone,
                                             device: d ?? device)
        return ["public_key": key.publicKey.rawRepresentation.base64EncodedString(),
                "signature": try signer.signature(for: message).base64EncodedString(),
                "client_id": clientID ?? helper]
    }

    private func verify(_ reply: JSONObject) -> Result<String, HelperIdentity.Failure> {
        HelperIdentity.verify(reply: reply, challenge: challenge, called: helper, requester: phone, device: device)
    }

    @Test func theSignedMessageIsFiveLinesWithNoTrailingNewline() {
        let text = String(decoding: HelperIdentity.message(challenge: "abc", helper: "client:h", requester: "client:p", device: "a1b2c3d4"),
                          as: UTF8.self)
        #expect(text == "rexduo-helper-identity-v1\nabc\nclient:h\nclient:p\na1b2c3d4")
    }

    @Test func aChallengeIs32RandomBytesInBase64URL() {
        let a = HelperIdentity.challenge(), b = HelperIdentity.challenge()
        #expect(a != b)
        #expect(a.count == 43)
        #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }

    @Test func aGoodSignatureGivesTheHelpersKey() throws {
        #expect(verify(try reply()) == .success(key.publicKey.rawRepresentation.base64EncodedString()))
    }

    @Test func anAnswerToAnotherChallengeIsRefused() throws {
        #expect(verify(try reply(challenge: "b2xkLWNoYWxsZW5nZQ")) == .failure(.badSignature))
    }

    @Test func anAnswerFromAnotherHelperClientIsRefused() throws {
        // Signed for itself by some other client, and passed on under the called client's id.
        #expect(verify(try reply(helper: "client:other")) == .failure(.badSignature))
        // The reply says outright that another client answered.
        #expect(verify(try reply(helper: "client:other", clientID: "client:other")) == .failure(.wrongClient))
    }

    @Test func anAnswerMadeForAnotherRequesterIsRefused() throws {
        // The real helper signed this for a third client, which relays it to the phone.
        #expect(verify(try reply(requester: "client:relay")) == .failure(.badSignature))
    }

    @Test func anAnswerForAnotherDeviceIsRefused() throws {
        #expect(verify(try reply(device: "ffffffff")) == .failure(.badSignature))
    }

    @Test func aSignatureByAnotherKeyIsRefused() throws {
        #expect(verify(try reply(signedBy: Curve25519.Signing.PrivateKey())) == .failure(.badSignature))
    }

    @Test func aMalformedKeyOrSignatureIsRefused() throws {
        let good = try reply()
        for (field, value) in [("public_key", "not base64!"), ("public_key", Data(count: 31).base64EncodedString()),
                               ("signature", "###"), ("signature", Data(count: 63).base64EncodedString())] {
            var bad = good
            bad[field] = value
            #expect(verify(bad) == .failure(.malformed))
        }
        for field in ["public_key", "signature", "client_id"] {
            var bad = good
            bad[field] = nil
            #expect(verify(bad) == .failure(.malformed))
        }
        var number = good
        number["signature"] = 7
        #expect(verify(number) == .failure(.malformed))
    }

    @Test func theFirstKeyIsPinnedAndAnotherOneStops() {
        #expect(HelperIdentity.pin(pinned: nil, offered: "key1") == .first)
        #expect(HelperIdentity.pin(pinned: "key1", offered: "key1") == .same)
        #expect(HelperIdentity.pin(pinned: "key1", offered: "key2") == .changed)
    }

    // MARK: What a helper answers

    @Test func aReplyIsAResultOrTheHelpersError() {
        guard case .success(let r) = HelperFailure.read(["result": ["registered": true, "devices": 1]]) else {
            Issue.record("expected a result"); return
        }
        #expect(r.bool("registered") == true)
        #expect(HelperFailure.read(["error": ["code": "secret_dropped", "message": "This secret was refused."]]).failure
                == HelperFailure(code: "secret_dropped", message: "This secret was refused."))
        // An action with nothing to say answers with no result at all.
        guard case .success(let empty) = HelperFailure.read([:]) else { Issue.record("expected a result"); return }
        #expect(empty.isEmpty)
    }

    @Test func refusalsAreToldApart() {
        let unknown = HelperFailure(code: "not_supported", message: "unknown action helper_identity")
        #expect(unknown.isUnknownAction && !unknown.isSecretDropped)
        #expect(HelperFailure(RexError(code: "internal", message: "Unknown action: helper_identity")).isUnknownAction)
        #expect(!HelperFailure(code: "timeout", message: "the client did not answer").isUnknownAction)

        #expect(HelperFailure(code: "secret_dropped", message: "This secret was refused.").isSecretDropped)
        // Rex may pass the helper's code on inside its own message.
        #expect(HelperFailure(RexError(code: "client_error", message: "secret_dropped: this secret was refused")).isSecretDropped)
        #expect(!HelperFailure(code: "not_your_device", message: "Another account registered this iPhone.").isSecretDropped)

        #expect(HelperFailure(code: "invalid", message: "token must be the APNs device token in hex").isLegacyRefusal)
    }

    @MainActor @Test func aFailureReadsAsOneSentence() {
        #expect(HelperFailure(code: "not_your_device", message: "Another account registered this iPhone.").sentence(helper: "Studio")
                == "\(Brand.beaconName) on Studio: Another account registered this iPhone.")
        #expect(HelperFailure(code: "", message: "timed out ").sentence(helper: "Studio") == "\(Brand.beaconName) on Studio: timed out.")
        #expect(HelperFailure(code: "", message: "").sentence(helper: "Studio") == "\(Brand.beaconName) on Studio: the request failed.")
    }

    // MARK: Labels

    @Test func aSecretsLabelIsTheServersNameInPrintableCharacters() {
        #expect(SecretLabel.make("Studio") == "Studio")
        #expect(SecretLabel.make("  Alex's Mac mini\n") == "Alex's Mac mini")
        #expect(SecretLabel.make("Büro\u{7}\tMac") == "BroMac")
        #expect(SecretLabel.make(String(repeating: "a", count: 63) + " bcd") == String(repeating: "a", count: 63))
        #expect(SecretLabel.make(String(repeating: "x", count: 200)).count == 64)
        // Never empty: the gateway refuses a label without characters.
        #expect(SecretLabel.make("") == "Rex server")
        #expect(SecretLabel.make("工作室") == "Rex server")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
