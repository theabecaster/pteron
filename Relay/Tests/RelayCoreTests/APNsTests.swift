import CryptoKit
import RexKit
import XCTest
@testable import RelayCore

final class APNsTests: XCTestCase {
    func b64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    func testJWTFormat() throws {
        let key = P256.Signing.PrivateKey()
        let issued = Date(timeIntervalSince1970: 1_763_300_000)
        let jwt = APNsToken.make(key: key, keyID: "5G2D4URHAC", teamID: "R2PVQ496X7", issuedAt: issued)
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(parts.count, 3)
        for p in parts { XCTAssertFalse(p.contains("=") || p.contains("+") || p.contains("/")) }

        let header = try XCTUnwrap(JSONCodec.decode(try XCTUnwrap(b64urlDecode(parts[0]))))
        XCTAssertEqual(header as NSDictionary, ["alg": "ES256", "kid": "5G2D4URHAC"])
        let claims = try XCTUnwrap(JSONCodec.decode(try XCTUnwrap(b64urlDecode(parts[1]))))
        XCTAssertEqual(claims as NSDictionary, ["iss": "R2PVQ496X7", "iat": 1_763_300_000])

        let sig = try XCTUnwrap(b64urlDecode(parts[2]))
        XCTAssertEqual(sig.count, 64, "ES256 JWS signature is raw r||s")
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: sig)
        XCTAssertTrue(key.publicKey.isValidSignature(ecdsa, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    func testTokenIsReusedThenRefreshed() {
        var t = APNsToken(key: P256.Signing.PrivateKey(), keyID: "K", teamID: "T")
        let now = Date()
        let a = t.current(now: now)
        XCTAssertEqual(t.current(now: now.addingTimeInterval(49 * 60)), a)
        let b = t.current(now: now.addingTimeInterval(51 * 60))
        XCTAssertNotEqual(a, b)
        t.invalidate()
        XCTAssertNotEqual(t.current(now: now.addingTimeInterval(52 * 60)), b)
    }

    func testLoadsPKCS8PEM() throws {
        let key = P256.Signing.PrivateKey()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AuthKey_TEST.p8")
        try key.pemRepresentation.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var t = try APNsToken(p8Path: url.path, keyID: "K", teamID: "T")
        XCTAssertEqual(t.current().split(separator: ".").count, 3)
    }

    func testRequestHeaders() {
        let ref = BlockRef(server: "s", sessionID: "session:1", blockID: "block:1")
        let m = PushMessage.compose(PushIntent(category: .blocked, ref: ref, state: "blocked", recordID: ""), context: BlockContext())
        let dev = Device(token: String(repeating: "ab", count: 32), environment: "sandbox")
        let r = APNsSender.request(for: m, device: dev, topic: "dev.abrahamgonzalez.rexduo", jwt: "x.y.z")
        XCTAssertEqual(r.url?.absoluteString, "https://api.sandbox.push.apple.com/3/device/\(dev.token)")
        XCTAssertEqual(r.value(forHTTPHeaderField: "authorization"), "bearer x.y.z")
        XCTAssertEqual(r.value(forHTTPHeaderField: "apns-topic"), "dev.abrahamgonzalez.rexduo")
        XCTAssertEqual(r.value(forHTTPHeaderField: "apns-push-type"), "alert")
        XCTAssertEqual(r.value(forHTTPHeaderField: "apns-priority"), "10")
        var prod = dev
        prod.environment = "production"
        XCTAssertEqual(APNsSender.request(for: m, device: prod, topic: "t", jwt: "j").url?.host, "api.push.apple.com")
    }
}

final class PresenceTests: XCTestCase {
    let dev = Device(token: String(repeating: "0", count: 64), environment: "sandbox", deviceID: "a1b2c3d4",
                     tailscaleNode: "abes-iphone")

    func app(_ id: String, label: String?, state: String? = "connected", node: String? = nil,
             platform: String = "ios", kind: String = "app") -> ClientSnapshot {
        ClientSnapshot(clientID: id, kind: kind, platform: platform, name: "Rex Connect", label: label,
                       connectionState: state, tailscaleNode: node)
    }

    func testLabelDeviceID() {
        XCTAssertEqual(Presence.deviceID(fromLabel: "Abe's iPhone #A1B2C3D4"), "a1b2c3d4")
        XCTAssertNil(Presence.deviceID(fromLabel: "Abe's iPhone"))
        XCTAssertNil(Presence.deviceID(fromLabel: "Room #1"))
    }

    func testMatchesByLabelDeviceID() {
        XCTAssertTrue(Presence.isAppOpen(dev, clients: [app("c1", label: "iPhone #a1b2c3d4")], backgrounded: []))
        XCTAssertFalse(Presence.isAppOpen(dev, clients: [app("c1", label: "iPhone #ffff0000", node: "abes-iphone")], backgrounded: []))
    }

    func testIgnoresLostBackgroundedAndNonIOS() {
        XCTAssertFalse(Presence.isAppOpen(dev, clients: [app("c1", label: "x #a1b2c3d4", state: "lost")], backgrounded: []))
        XCTAssertFalse(Presence.isAppOpen(dev, clients: [app("c1", label: "x #a1b2c3d4")], backgrounded: ["c1"]))
        XCTAssertFalse(Presence.isAppOpen(dev, clients: [app("c1", label: "x #a1b2c3d4", platform: "macos")], backgrounded: []))
    }

    func testTailscaleNodeFallbackOnlyWithoutDeviceID() {
        // Registered with a device id: an unlabeled client on the same node is someone else.
        XCTAssertFalse(Presence.isAppOpen(dev, clients: [app("c1", label: "iPhone", node: "abes-iphone")], backgrounded: []))
        var old = dev
        old.deviceID = nil
        XCTAssertTrue(Presence.isAppOpen(old, clients: [app("c1", label: "iPhone", node: "abes-iphone")], backgrounded: []))
        XCTAssertFalse(Presence.isAppOpen(old, clients: [app("c1", label: "iPhone", node: "other")], backgrounded: []))
        XCTAssertFalse(Presence.isAppOpen(old, clients: [app("c1", label: "iPhone #a1b2c3d4", node: "abes-iphone")], backgrounded: []))
    }

    func testClientSnapshotParsing() {
        let c = ClientSnapshot(["client_id": "client:1", "connection_state": "connected",
                                "info": ["kind": "app", "platform": "ios", "label": "iPhone #abcd1234"],
                                "principal": ["kind": "tailscale", "node": "abes-iphone"]])
        XCTAssertEqual(c?.tailscaleNode, "abes-iphone")
        XCTAssertEqual(c?.label, "iPhone #abcd1234")
    }

    @MainActor func testDeviceStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("devices-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = DeviceStore(url: url)
        s.register(Device(token: String(repeating: "AB", count: 32), environment: "sandbox", deviceID: "a1b2"))
        // Same device id, new token: replaces the old entry.
        s.register(Device(token: String(repeating: "cd", count: 32), environment: "production", deviceID: "a1b2"))
        XCTAssertEqual(DeviceStore(url: url).devices.map(\.token), [String(repeating: "cd", count: 32)])
        XCTAssertTrue(s.remove(token: String(repeating: "CD", count: 32)))
        XCTAssertTrue(DeviceStore(url: url).devices.isEmpty)
    }
}
