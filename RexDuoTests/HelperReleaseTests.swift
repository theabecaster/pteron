import CryptoKit
import Foundation
import GlanceModel
import Testing
@testable import RexDuo

/// How the phone reads a helper release: which keys it trusts, what a release list must look
/// like, and when one is accepted. Lists are signed here with keys made for the test.
@MainActor
struct HelperReleaseTests {
    private let signer = Curve25519.Signing.PrivateKey()
    private let other = Curve25519.Signing.PrivateKey()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hashes: [HelperPlatform: String] = [
        .mac: String(repeating: "a1", count: 32), .linuxX64: String(repeating: "b2", count: 32), .linuxArm64: String(repeating: "c3", count: 32),
    ]

    private var trusted: [Data] { [signer.publicKey.rawRepresentation] }

    /// A release list as `release.sh` writes it, changed by `edit` before it is encoded.
    private func list(_ version: String = "0.4.0", edit: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var assets: [String: Any] = [:]
        for (i, platform) in HelperPlatform.allCases.enumerated() {
            assets[platform.rawValue] = [
                "url": "https://github.com/theabecaster/rexduo/releases/download/helper-v\(version)/\(platform.asset)",
                "sha256": hashes[platform]!, "size": 1000 + i,
            ] as [String: Any]
        }
        var o: [String: Any] = ["version": version, "min_version": "0.3.0", "released_at": "2027-01-01T00:00:00Z",
                                "expires_at": "2027-06-01T00:00:00Z", "next_key": NSNull(), "assets": assets]
        edit(&o)
        return try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    /// The list with one top-level field replaced, or removed for nil.
    private func with(_ key: String, _ value: Any?, version: String = "0.4.0") -> Data {
        list(version) { $0[key] = value }
    }

    private func signature(_ data: Data, by key: Curve25519.Signing.PrivateKey? = nil) -> Data {
        Data((try! (key ?? signer).signature(for: data).base64EncodedString() + "\n").utf8)
    }

    private func accept(_ data: Data, signature sig: Data? = nil, highWater: String? = nil, floor: String = "0.3.0",
                        at date: Date? = nil) -> Result<ReleaseManifest, ReleaseFault> {
        do {
            return .success(try HelperRelease.accept(data, signatureFile: sig ?? signature(data), trusted: trusted,
                                                     highWater: highWater.flatMap(ReleaseVersion.init), floor: ReleaseVersion(floor)!,
                                                     now: date ?? now))
        } catch {
            return .failure(error as? ReleaseFault ?? .unreachable)
        }
    }

    private func fault(_ result: Result<ReleaseManifest, ReleaseFault>) -> ReleaseFault? {
        if case .failure(let f) = result { return f }
        return nil
    }

    private func isMalformed(_ result: Result<ReleaseManifest, ReleaseFault>) -> Bool {
        if case .failure(.malformed) = result { return true }
        return false
    }

    private func edited(_ platform: HelperPlatform, _ field: String, _ value: Any) -> Data {
        list { o in
            var assets = o["assets"] as! [String: Any]
            var a = assets[platform.rawValue] as! [String: Any]
            a[field] = value
            assets[platform.rawValue] = a
            o["assets"] = assets
        }
    }

    // MARK: Keys

    @Test func theBuiltInKeysAreTheOnesInTheRepositoryFile() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Relay/update-key.pub")
        let parsed = try #require(HelperKeys.parse(try String(contentsOf: file, encoding: .utf8)))
        #expect(parsed.primary == HelperKeys.primary)
        #expect(parsed.recovery == HelperKeys.recovery)
        #expect(HelperKeys.builtin.count == 2)
        #expect(HelperKeys.builtin.allSatisfy { $0.count == 32 })
    }

    @Test func aKeyFileIsLabelledLinesAndComments() {
        let key = signer.publicKey.rawRepresentation.base64EncodedString()
        #expect(HelperKeys.parse("# note\nprimary  \(key)\n")?.primary == key)
        #expect(HelperKeys.parse("primary \(key)\nrecovery \(key)\n")?.recovery == key)
        #expect(HelperKeys.parse("recovery \(key)\n") == nil)
        #expect(HelperKeys.parse("primary \(key)\nprimary \(key)\n") == nil)
        #expect(HelperKeys.parse("signing \(key)\n") == nil)
        #expect(HelperKeys.parse("primary notakey\n") == nil)
        #expect(HelperKeys.key(Data(count: 32).base64EncodedString()) == nil)
    }

    // MARK: The shared fixtures

    /// `Relay/fixtures`: release lists the release tooling wrote (`tests-setup/make-fixtures.sh`),
    /// which the helper's tests read too. One format, three readers.
    private func fixture(_ name: String) throws -> Data {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Relay/fixtures")
        return try Data(contentsOf: dir.appendingPathComponent(name))
    }

    @Test func theSharedFixturesAreReadAsTheToolingWroteThem() throws {
        let text = try #require(String(data: try fixture("test-key.pub"), encoding: .utf8))
        let key = try #require(HelperKeys.parse(text).flatMap { Data(base64Encoded: $0.primary) })
        let now = Date()
        let zero = try #require(ReleaseVersion("0.0.1"))
        func accept(_ list: String, _ signature: String, seen: ReleaseVersion? = nil) -> Result<ReleaseManifest, ReleaseFault> {
            Result { try HelperRelease.accept(try fixture(list), signatureFile: try fixture(signature), trusted: [key],
                                              highWater: seen, floor: zero, now: now) }
                .mapError { $0 as? ReleaseFault ?? .unreachable }
        }

        let m = try accept("manifest.json", "manifest.json.sig").get()
        #expect(m.version == ReleaseVersion("9.8.7"))
        #expect(m.assets.count == 3)
        let linux = try #require(m.assets[.linuxX64])
        let signature = try fixture("rex-duo-helper-linux-x86_64.sig")
        let message = HelperRelease.binaryMessage(version: m.version, platform: .linuxX64, sha256: linux.sha256)
        #expect(HelperRelease.verify(keys: [key], message: message, signatureFile: signature))
        // A signature for one platform is not one for another.
        let other = HelperRelease.binaryMessage(version: m.version, platform: .linuxArm64, sha256: linux.sha256)
        #expect(!HelperRelease.verify(keys: [key], message: other, signatureFile: signature))

        // A list that also names the Mac app a second time, as Beacon: the app takes that entry for the
        // Mac, and a list without it gives the earlier one.
        let earlier = try #require(m.assets[.mac])
        let both = try accept("manifest-beacon.json", "manifest-beacon.json.sig").get()
        #expect(both.assets.count == 3)
        #expect(both.assets[.mac]?.sha256 == "b38897a7da6e9596060b93420bbb0876b2a65d54d790e9e6aecfcd39faf824d0")
        #expect(both.assets[.mac] != earlier && both.assets[.linuxX64] == m.assets[.linuxX64])
        // A list as a release has it today, with the Mac app a third time under `macos-app`: the
        // app takes that one before the other two.
        let all = try accept("manifest-app.json", "manifest-app.json.sig").get()
        #expect(all.assets.count == 3)
        #expect(all.assets[.mac]?.sha256 == "b6ed1d607a0e0900672ba2577996069ad5c551f9d840c93a42edf9026bbb1e53")
        #expect(all.assets[.mac] != both.assets[.mac] && all.assets[.linuxArm64] == m.assets[.linuxArm64])

        #expect(accept("manifest-expired.json", "manifest-expired.json.sig") == .failure(.expired))
        #expect(accept("manifest-older.json", "manifest-older.json.sig", seen: ReleaseVersion("9.8.7")) == .failure(.tooOld))
        #expect(accept("manifest.json", "manifest-untrusted.json.sig") == .failure(.untrusted))
    }

    // MARK: Accepting a list

    @Test func aListSignedByATrustedKeyIsAccepted() throws {
        let m = try accept(list()).get()
        #expect(m.version == ReleaseVersion("0.4.0"))
        #expect(m.minVersion == ReleaseVersion("0.3.0"))
        #expect(m.nextKey == nil)
        #expect(m.assets[.mac] == ReleaseAsset(sha256: hashes[.mac]!, size: 1000))
        #expect(m.assets.count == 3)
        #expect(m.expiresAt == HelperRelease.timestamp("2027-06-01T00:00:00Z"))
    }

    /// A newer `release.sh` may add fields. The parser reads the ones it knows and ignores the
    /// rest, so such a list is accepted, and reads the same as the list without them.
    @Test func keysTheParserDoesNotKnowAreIgnored() throws {
        let plain = try accept(list()).get()
        for extra in [["desk": "on", "signed_at": "2027-01-02T00:00:00Z"], ["desk": "off"], ["desk": 7, "signed_at": NSNull()],
                      ["some_later_field": ["nested": true]]] as [[String: Any]] {
            let data = list { o in for (key, value) in extra { o[key] = value } }
            #expect(try accept(data).get() == plain, "\(extra.keys.sorted())")
        }
    }

    @Test func aListSignedByAnotherKeyIsRefused() {
        let data = list()
        #expect(fault(accept(data, signature: signature(data, by: other))) == .untrusted)
        #expect(fault(accept(data, signature: Data())) == .untrusted)
        #expect(fault(accept(data, signature: Data("not base64\n".utf8))) == .untrusted)
    }

    @Test func aListThatDiffersByOneByteFromWhatWasSignedIsRefused() {
        let data = list()
        let sig = signature(data)
        for index in [0, data.count / 2, data.count - 1] {
            var changed = data
            changed[index] ^= 0x01
            #expect(fault(accept(changed, signature: sig)) == .untrusted, "byte \(index)")
        }
    }

    @Test func theSignatureIsCheckedBeforeAnythingIsRead() {
        // Not JSON at all, and not signed: the answer is about the signature.
        let junk = Data("{".utf8)
        #expect(fault(accept(junk, signature: signature(list()))) == .untrusted)
        #expect(isMalformed(accept(junk)))
    }

    @Test func oneGoodSignatureAmongSeveralLinesIsEnough() {
        let data = list()
        let good = try! signer.signature(for: data).base64EncodedString()
        let wrong = try! other.signature(for: data).base64EncodedString()
        let file = { (lines: [String]) in Data(lines.joined(separator: "\n").utf8) }
        #expect(fault(accept(data, signature: file([wrong, "", "  \(good)  "]))) == nil)
        #expect(fault(accept(data, signature: file([wrong, wrong]))) == .untrusted)
        // Eight lines are read. A ninth is not.
        #expect(fault(accept(data, signature: file(Array(repeating: wrong, count: 7) + [good]))) == nil)
        #expect(fault(accept(data, signature: file(Array(repeating: wrong, count: 8) + [good]))) == .untrusted)
    }

    @Test func anExpiredListIsRefused() {
        let expiry = HelperRelease.timestamp("2027-06-01T00:00:00Z")!
        #expect(fault(accept(list(), at: expiry.addingTimeInterval(-1))) == nil)
        #expect(fault(accept(list(), at: expiry)) == .expired)
        #expect(fault(accept(list(), at: expiry.addingTimeInterval(86_400))) == .expired)
    }

    @Test func aListOlderThanOneAcceptedBeforeIsRefused() {
        #expect(fault(accept(list("0.4.0"), highWater: "0.4.1")) == .tooOld)
        #expect(fault(accept(list("0.4.0"), highWater: "0.4.0")) == nil)
        #expect(fault(accept(list("0.4.0"), highWater: "0.3.9")) == nil)
    }

    @Test func aListBelowTheAppsOldestHelperIsRefused() {
        #expect(fault(accept(list("0.4.0"), floor: "0.5.0")) == .tooOld)
        #expect(fault(accept(list("0.4.0"), floor: "0.4.0")) == nil)
        // The higher of the two limits counts.
        #expect(fault(accept(list("0.4.0"), highWater: "0.1.0", floor: "0.4.1")) == .tooOld)
        #expect(HelperRelease.floor >= ReleaseVersion("0.3.0")!)
    }

    // MARK: Reading a list

    /// The list with entries for the Mac app under its newer keys too, each with a hash of its own.
    private func macList(app: String? = HelperRelease.macAppAsset, beacon: String? = HelperRelease.macBeaconAsset) -> Data {
        list { o in
            var assets = o["assets"] as! [String: Any]
            let base = "https://github.com/theabecaster/rexduo/releases/download/helper-v0.4.0/"
            if let app { assets[HelperRelease.macAppKey] = ["url": base + app, "sha256": String(repeating: "d4", count: 32), "size": 2000] as [String: Any] }
            if let beacon { assets[HelperRelease.macBeaconKey] = ["url": base + beacon, "sha256": String(repeating: "e5", count: 32), "size": 3000] as [String: Any] }
            o["assets"] = assets
        }
    }

    @Test func theMacAppIsTakenFromTheNewestEntryAListHas() throws {
        #expect((HelperRelease.macAppKey, HelperRelease.macAppAsset) == ("macos-app", "Beacon-macOS.zip"))
        let app = ReleaseAsset(sha256: String(repeating: "d4", count: 32), size: 2000)
        let beacon = ReleaseAsset(sha256: String(repeating: "e5", count: 32), size: 3000)
        let earliest = ReleaseAsset(sha256: hashes[.mac]!, size: 1000)
        #expect(try accept(macList()).get().assets[.mac] == app)
        #expect(try accept(macList(beacon: nil)).get().assets[.mac] == app)
        #expect(try accept(macList(app: nil)).get().assets[.mac] == beacon)
        #expect(try accept(macList(app: nil, beacon: nil)).get().assets[.mac] == earliest)
        // The other builds are untouched, and the Mac still counts once.
        #expect(try accept(macList()).get().assets.count == 3)
    }

    @Test func everyMacEntryAListNamesMustBeRight() {
        // Another file name under either key refuses the whole list, also when a better entry is right.
        #expect(isMalformed(accept(macList(app: "Another-Beacon.zip"))))
        #expect(isMalformed(accept(macList(app: HelperRelease.macBeaconAsset))))
        #expect(isMalformed(accept(macList(beacon: "Beacon-macOS.zip"))))
        #expect(isMalformed(accept(macList(app: nil, beacon: "Rex-DUO-Helper.zip"))))
    }

    @Test func anAddressMustBeTheOneTheAppBuilds() {
        let good = "https://github.com/theabecaster/rexduo/releases/download/helper-v0.4.0/Rex-DUO-Helper.zip"
        #expect(HelperRelease.assetURL(.mac, version: ReleaseVersion("0.4.0")!) == good)
        #expect(fault(accept(edited(.mac, "url", good))) == nil)
        let others = [
            "https://github.com/theabecaster/rexduo/releases/download/helper-v0.4.1/Rex-DUO-Helper.zip",
            "https://github.com/theabecaster/rexduo/releases/download/helper-v0.4.0/rex-duo-helper-linux-x86_64",
            "https://github.com/someone/rexduo/releases/download/helper-v0.4.0/Rex-DUO-Helper.zip",
            "https://example.com/theabecaster/rexduo/releases/download/helper-v0.4.0/Rex-DUO-Helper.zip",
            "http://github.com/theabecaster/rexduo/releases/download/helper-v0.4.0/Rex-DUO-Helper.zip",
            good + "?x=1", good + "/", good + " ", " " + good, good.uppercased(), "",
        ]
        for url in others {
            #expect(isMalformed(accept(edited(.mac, "url", url))), "\(url)")
        }
        #expect(isMalformed(accept(edited(.linuxArm64, "url", 7))))
    }

    @Test func aSizeIsAWholeNumberUpTo64MiB() {
        #expect(fault(accept(edited(.linuxX64, "size", 64 << 20))) == nil)
        #expect(fault(accept(edited(.linuxX64, "size", 1))) == nil)
        for bad: Any in [(64 << 20) + 1, 0, -1, 1.5, "1000", true, NSNull()] {
            #expect(isMalformed(accept(edited(.linuxX64, "size", bad))), "\(bad)")
        }
    }

    @Test func aHashIs64HexCharacters() throws {
        let upper = String(repeating: "AB", count: 32)
        #expect(try accept(edited(.mac, "sha256", upper)).get().assets[.mac]?.sha256 == upper.lowercased())
        for bad: Any in [String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "g", count: 64),
                         String(repeating: "a", count: 63) + "\n", String(repeating: "١", count: 64), 5] {
            #expect(isMalformed(accept(edited(.mac, "sha256", bad))), "\(bad)")
        }
    }

    @Test func versionsAndDatesHaveOneForm() {
        for bad in ["0.4", "0.4.0.1", "v0.4.0", "0.04.0", "0.4.0 ", "0.4.-1", "", "0.4.0\n", "1234567890.0.0", "٠.٤.٠"] {
            #expect(ReleaseVersion(bad) == nil, "\(bad)")
            #expect(isMalformed(accept(with("version", bad))), "version \(bad)")
            #expect(isMalformed(accept(with("min_version", bad))), "min_version \(bad)")
        }
        #expect(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.9")!)
        #expect(ReleaseVersion("1.0.0")!.description == "1.0.0")
        // A release can't require more than itself.
        #expect(isMalformed(accept(with("min_version", "0.4.1"))))
        #expect(fault(accept(with("min_version", "0.4.0"))) == nil)
        for bad: Any in ["2027-06-01", "2027-06-01T00:00:00+00:00", "2027-06-01 00:00:00Z", "2027-13-01T00:00:00Z", "soon", 1_900_000_000] {
            #expect(isMalformed(accept(with("expires_at", bad))), "expires_at \(bad)")
        }
        #expect(isMalformed(accept(with("expires_at", nil))))
        #expect(HelperRelease.timestamp("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(HelperRelease.timestamp("2027-01-15T08:00:00Z") == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func aBuildTheListNamesMustBeWholeAndOneItLeavesOutIsAbsent() throws {
        let without = list { o in
            var assets = o["assets"] as! [String: Any]
            assets["linux-aarch64"] = nil
            assets["plan9-mips"] = ["url": "https://example.com/x", "sha256": "no", "size": -4]
            o["assets"] = assets
        }
        let m = try accept(without).get()
        #expect(m.assets[.linuxArm64] == nil)
        #expect(m.assets.count == 2)
        #expect(isMalformed(accept(with("assets", "none"))))
        #expect(isMalformed(accept(with("assets", nil))))
    }

    // MARK: Handing over a key

    @Test func aNextKeyIsRememberedOnlyFromAnAcceptedList() throws {
        let next = Curve25519.Signing.PrivateKey()
        let nextText = next.publicKey.rawRepresentation.base64EncodedString()
        let handing = with("next_key", nextText, version: "0.4.1")
        var memory = ReleaseMemory()

        // Signed by a key nobody trusts: nothing is remembered, neither the key nor the version.
        #expect(throws: ReleaseFault.untrusted) {
            try HelperRelease.acceptAndRemember(handing, signatureFile: signature(handing, by: other), builtin: trusted, memory: &memory, now: now)
        }
        #expect(memory == ReleaseMemory())
        // Expired, though signed: nothing either.
        #expect(throws: ReleaseFault.expired) {
            try HelperRelease.acceptAndRemember(handing, signatureFile: signature(handing), builtin: trusted, memory: &memory,
                                                now: now.addingTimeInterval(400 * 86_400))
        }
        #expect(memory == ReleaseMemory())
        // A list signed by the next key is not accepted yet.
        let later = list("0.4.2")
        #expect(throws: ReleaseFault.untrusted) {
            try HelperRelease.acceptAndRemember(later, signatureFile: signature(later, by: next), builtin: trusted, memory: &memory, now: now)
        }

        let accepted = try HelperRelease.acceptAndRemember(handing, signatureFile: signature(handing), builtin: trusted, memory: &memory, now: now)
        #expect(accepted.manifest.nextKey == nextText)
        #expect(accepted.signer == signer.publicKey.rawRepresentation)
        #expect(memory == ReleaseMemory(highWater: "0.4.1", handedKeys: [nextText]))
        #expect(accepted.trust.keys.count == 2)
        // From now on the next key signs.
        let after = try HelperRelease.acceptAndRemember(later, signatureFile: signature(later, by: next), builtin: trusted, memory: &memory, now: now)
        #expect(after.manifest.version == ReleaseVersion("0.4.2"))
        // The list says which key signed it, and the installer gets that key first.
        #expect(after.signer == next.publicKey.rawRepresentation)
        #expect(HelperRelease.installerKeys(signer: after.signer, trusted: after.trust.keys)
            == [nextText, signer.publicKey.rawRepresentation.base64EncodedString()])
        #expect(memory.highWater == "0.4.2")
        // And an older list is no longer taken.
        #expect(throws: ReleaseFault.tooOld) {
            try HelperRelease.acceptAndRemember(handing, signatureFile: signature(handing), builtin: trusted, memory: &memory, now: now)
        }
    }

    @Test func aNextKeyMustBeAKey() {
        for bad: Any in ["short", Data(count: 32).base64EncodedString(), Data(count: 31).base64EncodedString(), 4, ["k"]] {
            #expect(isMalformed(accept(with("next_key", bad))), "\(bad)")
        }
        #expect(fault(accept(with("next_key", nil))) == nil)
    }

    @Test func atMostFourHandedOverKeysAreKept() {
        let keys = (0..<6).map { _ in Curve25519.Signing.PrivateKey().publicKey.rawRepresentation }
        var trust = ReleaseTrust(builtin: trusted)
        let builtIn = trust.handOver(trusted[0]), zero = trust.handOver(Data(count: 32))
        #expect(!builtIn && !zero)
        for key in keys {
            let added = trust.handOver(key)
            #expect(added)
        }
        let again = trust.handOver(keys[5])
        #expect(!again)
        #expect(trust.handed == Array(keys[2...]))
        #expect(trust.keys.first == trusted[0])
        #expect(ReleaseTrust(builtin: trusted, handed: keys).handed == Array(keys[2...]))
    }

    // MARK: A Linux build's own signature

    @Test func aLinuxSignatureCoversVersionPlatformAndHash() {
        let version = ReleaseVersion("0.4.0")!
        let hash = hashes[.linuxX64]!
        let message = HelperRelease.binaryMessage(version: version, platform: .linuxX64, sha256: hash.uppercased())
        #expect(String(decoding: message, as: UTF8.self) == "rex-duo-helper|0.4.0|linux-x86_64|\(hash)")
        let file = signature(message)
        #expect(HelperRelease.verify(keys: trusted, message: message, signatureFile: file))
        #expect(!HelperRelease.verify(keys: [other.publicKey.rawRepresentation], message: message, signatureFile: file))
        let others = [
            HelperRelease.binaryMessage(version: ReleaseVersion("0.4.1")!, platform: .linuxX64, sha256: hash),
            HelperRelease.binaryMessage(version: version, platform: .linuxArm64, sha256: hash),
            HelperRelease.binaryMessage(version: version, platform: .linuxX64, sha256: hashes[.mac]!),
        ]
        for message in others {
            #expect(!HelperRelease.verify(keys: trusted, message: message, signatureFile: file))
        }
    }

    // MARK: Fetching

    /// The network of a test: bodies by address, and a record of what was asked for.
    /// `@unchecked Sendable` is safe because every access takes the lock.
    private final class Web: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String: Data] = [:]
        private var seen: [String] = []

        func put(_ url: String, _ data: Data) { lock.withLock { bodies[url] = data } }
        var asked: [String] { lock.withLock { seen } }

        func get(_ url: URL) throws -> Data {
            try lock.withLock {
                seen.append(url.absoluteString)
                guard let data = bodies[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
                return data
            }
        }
    }

    private func web(_ data: Data, linuxSigner: Curve25519.Signing.PrivateKey? = nil) -> Web {
        let web = Web()
        web.put(HelperRelease.manifestURL, data)
        web.put(HelperRelease.signatureURL, signature(data))
        let version = ReleaseVersion("0.4.0")!
        for platform in [HelperPlatform.linuxX64, .linuxArm64] {
            let message = HelperRelease.binaryMessage(version: version, platform: platform, sha256: hashes[platform]!)
            web.put(HelperRelease.assetURL(platform, version: version) + ".sig", signature(message, by: linuxSigner))
        }
        return web
    }

    private func fetcher(_ web: Web, store: ReleaseMemoryStore = InMemoryReleaseStore()) -> HelperReleaseFetcher {
        var f = HelperReleaseFetcher(transport: { try web.get($0) }, store: store)
        f.builtin = trusted
        f.now = { [now] in now }
        return f
    }

    @Test func aVerifiedReleaseNeedsTheListAndBothLinuxSignaturesAndNoBuild() async throws {
        let web = web(list())
        let store = InMemoryReleaseStore()
        let release = try await fetcher(web, store: store).verified().get()
        #expect(release.version == ReleaseVersion("0.4.0"))
        // The oldest version the list allows comes along: the rows are judged by it too.
        #expect(release.minVersion == ReleaseVersion("0.3.0") && LatestRelease(release).minVersion == release.minVersion)
        #expect(release.assets[.linuxArm64] == ReleaseAsset(sha256: hashes[.linuxArm64]!, size: 1002))
        #expect(release.keys == [signer.publicKey.rawRepresentation.base64EncodedString()])
        #expect(store.value.highWater == "0.4.0")
        // The list, its signature and the two small signature files. Never a build.
        #expect(web.asked == [
            "https://github.com/theabecaster/rexduo/releases/download/helper-latest/manifest.json",
            "https://github.com/theabecaster/rexduo/releases/download/helper-latest/manifest.json.sig",
            "https://github.com/theabecaster/rexduo/releases/download/helper-v0.4.0/rex-duo-helper-linux-x86_64.sig",
            "https://github.com/theabecaster/rexduo/releases/download/helper-v0.4.0/rex-duo-helper-linux-aarch64.sig",
        ])
    }

    @Test func aLinuxBuildWithoutItsOwnSignatureStopsTheRelease() async {
        let unsigned = web(list(), linuxSigner: other)
        #expect(await fetcher(unsigned).verified() == .failure(.assetSignature(.linuxX64)))
        let missing = web(list())
        missing.put(HelperRelease.assetURL(.linuxArm64, version: ReleaseVersion("0.4.0")!) + ".sig", Data(count: (64 << 10) + 1))
        #expect(await fetcher(missing).verified() == .failure(.unreachable))
    }

    @Test func aReleaseMissingABuildIsNotInstalled() async {
        let data = list { o in
            var assets = o["assets"] as! [String: Any]
            assets["macos-universal"] = nil
            o["assets"] = assets
        }
        guard case .failure(.malformed) = await fetcher(web(data)).verified() else {
            Issue.record("a release without the Mac build was taken")
            return
        }
    }

    @Test func aFetchThatFailsOrIsTooBigIsUnreachable() async {
        #expect(await fetcher(Web()).verified() == .failure(.unreachable))
        let big = Web()
        big.put(HelperRelease.manifestURL, Data(count: (64 << 10) + 1))
        big.put(HelperRelease.signatureURL, Data())
        #expect(await fetcher(big).verified() == .failure(.unreachable))
    }

    /// A store that can't be read, then one that can't be written.
    private final class BrokenStore: ReleaseMemoryStore {
        var failsOnLoad: Bool
        init(failsOnLoad: Bool) { self.failsOnLoad = failsOnLoad }
        func load() throws -> ReleaseMemory {
            if failsOnLoad { throw KeychainError(status: -25308) }
            return ReleaseMemory()
        }
        func save(_ memory: ReleaseMemory) throws { throw KeychainError(status: -25308) }
    }

    @Test func nothingIsInstalledWhenThePhoneCannotRememberWhatItAccepted() async {
        #expect(await fetcher(web(list()), store: BrokenStore(failsOnLoad: true)).verified() == .failure(.storeFailed))
        #expect(await fetcher(web(list()), store: BrokenStore(failsOnLoad: false)).verified() == .failure(.storeFailed))
    }

    @Test func theHighestAcceptedVersionOutlivesTheFetcher() async {
        let store = InMemoryReleaseStore(ReleaseMemory(highWater: "0.5.0"))
        #expect(await fetcher(web(list()), store: store).verified() == .failure(.tooOld))
        #expect(store.value.highWater == "0.5.0")
    }

    @Test func aFetchStaysOnTheReleaseHostsOverHTTPS() {
        let ok = ["https://github.com/theabecaster/rexduo/releases/download/helper-latest/manifest.json",
                  "https://objects.githubusercontent.com/x", "https://release-assets.githubusercontent.com/x?sig=1",
                  "https://GITHUB.com/x", "https://github.com:443/x"]
        for url in ok { #expect(HelperRelease.allowed(URL(string: url)!), "\(url)") }
        let no = ["http://github.com/x", "https://github.com.example.com/x", "https://example.com/github.com", "https://raw.githubusercontent.com/x",
                  "https://user@github.com/x", "https://github.com:8443/x", "ftp://github.com/x", "https://githubusercontent.com/x"]
        for url in no { #expect(!HelperRelease.allowed(URL(string: url)!), "\(url)") }
        #expect(HelperRelease.maxDocument == 64 << 10)
    }

    // MARK: Renewal

    @Test func theRenewalLineShowsInsideThirtyDays() {
        let expiry = now.addingTimeInterval(40 * 86_400)
        #expect(HelperRelease.renewalNotice(expiresAt: expiry, now: now) == nil)
        #expect(HelperRelease.renewalDue(expiresAt: expiry, now: now.addingTimeInterval(11 * 86_400)) == expiry)
        let line = HelperRelease.renewalNotice(expiresAt: expiry, now: now.addingTimeInterval(20 * 86_400))
        #expect(line?.hasPrefix("\(Brand.beaconName) updates need renewing by ") == true)
    }

    @Test func aHelperReportsWhenItsListExpires() {
        let v = HelperVersion(["version": "0.4.0", "manifest_expires_at": "2027-06-01T00:00:00Z", "notices": "undetermined", "linger": false])
        #expect(v?.manifestExpiresAt == HelperRelease.timestamp("2027-06-01T00:00:00Z"))
        #expect(v?.notices == "undetermined")
        #expect(v?.linger == false)
        let old = HelperVersion(["version": "0.3.0"])
        #expect(old?.manifestExpiresAt == nil && old?.notices == nil && old?.linger == nil)
    }
}
