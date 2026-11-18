import CryptoKit
import Foundation
import Security
import os

/// A helper version, `major.minor.patch`: digits only, no leading zeros, at most nine digits a
/// part. The same reading as the helper's own (`Relay/src/update.rs`).
struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            let bytes = Array(part.utf8)
            guard (1...9).contains(bytes.count), bytes.allSatisfy({ (0x30...0x39).contains($0) }),
                  bytes.count == 1 || bytes[0] != 0x30, let n = Int(String(part)) else { return nil }
            numbers.append(n)
        }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// The three builds a release has, by the name the release list gives each.
enum HelperPlatform: String, CaseIterable, Sendable {
    case mac = "macos-universal"
    case linuxX64 = "linux-x86_64"
    case linuxArm64 = "linux-aarch64"

    /// The file's name in a release.
    var asset: String {
        switch self {
        case .mac: "Rex-DUO-Helper.zip"
        case .linuxX64: "rex-duo-helper-linux-x86_64"
        case .linuxArm64: "rex-duo-helper-linux-aarch64"
        }
    }

    /// A Linux build carries a signature of its own beside it; a Mac build carries Apple's.
    var hasSignatureFile: Bool { self != .mac }
}

struct ReleaseAsset: Equatable, Sendable {
    /// 64 lowercase hex characters.
    var sha256: String
    var size: Int
}

/// What the release list says, once its signature is checked and every field is read.
struct ReleaseManifest: Equatable, Sendable {
    var version: ReleaseVersion
    var minVersion: ReleaseVersion
    var expiresAt: Date
    /// A key the publisher is moving to, base64.
    var nextKey: String?
    var assets: [HelperPlatform: ReleaseAsset]
}

/// A release the phone has checked from end to end: what the installer is told to fetch.
struct VerifiedRelease: Equatable, Sendable {
    var version: ReleaseVersion
    /// The oldest version the release list still allows to run.
    var minVersion: ReleaseVersion
    var assets: [HelperPlatform: ReleaseAsset]
    var expiresAt: Date
    /// The keys the installer checks a Linux build with, base64: the key that signed the release
    /// list first, then the other keys this phone trusts (`HelperRelease.installerKeys`).
    var keys: [String]
}

enum ReleaseFault: Error, Equatable {
    /// The release list or a signature couldn't be fetched.
    case unreachable
    /// No signature from a key this phone trusts.
    case untrusted
    /// Signed, but a field is missing or not in its form.
    case malformed(String)
    case expired
    /// Older than a release this phone accepted before, or than the oldest this app installs.
    case tooOld
    /// A build's own signature doesn't cover what the list says about it.
    case assetSignature(HelperPlatform)
    /// The Keychain couldn't say what was accepted before, or keep what was accepted now.
    case storeFailed
}

/// What this phone remembers about releases: the newest version it accepted, and keys an accepted
/// release list handed over.
struct ReleaseMemory: Codable, Equatable {
    var highWater: String?
    /// Oldest first, base64.
    var handedKeys: [String] = []
}

/// The keys a release list or a Linux build may be signed with: the ones built in, and up to four
/// an accepted list handed over. The same rules as the helper's `Trust`.
struct ReleaseTrust: Equatable {
    static let handedLimit = 4

    private(set) var builtin: [Data]
    /// Oldest first.
    private(set) var handed: [Data] = []

    init(builtin: [Data], handed: [Data] = []) {
        self.builtin = builtin
        for key in handed { handOver(key) }
    }

    var keys: [Data] { builtin + handed }

    /// Adds a key an accepted list named as the next one. True when the set changed.
    @discardableResult
    mutating func handOver(_ key: Data) -> Bool {
        guard key.count == 32, key.contains(where: { $0 != 0 }), !builtin.contains(key), !handed.contains(key) else { return false }
        if handed.count >= Self.handedLimit { handed.removeFirst() }
        handed.append(key)
        return true
    }
}

/// The rules for a helper release, with no network in them: where its files live, how its list is
/// signed and read, and when a list is accepted. They mirror `Relay/src/update.rs`, so the phone
/// and the helper agree on what a release is.
enum HelperRelease {
    static let base = "https://github.com/theabecaster/rexduo/releases/download/"
    static let manifestURL = base + "helper-latest/manifest.json"
    static let signatureURL = manifestURL + ".sig"
    /// The oldest helper this app installs. Raised by app releases.
    static let floor = ReleaseVersion("0.3.0")!
    /// The most a release list or a signature file may weigh.
    static let maxDocument = 64 << 10
    /// The most a build may weigh.
    static let maxAsset = 64 << 20
    /// The most signatures read from one signature file.
    static let maxSignatures = 8
    /// The publisher renews a list before it expires. Inside this window the app says so.
    static let renewalWindow: TimeInterval = 30 * 24 * 3600
    /// The hosts a fetch may be sent on to.
    static let hosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    /// The list's entry for the Mac app under the name Rex DUO Beacon, and that file's name.
    static let macBeaconKey = "macos-universal-beacon"
    static let macBeaconAsset = "Rex-DUO-Beacon.zip"

    /// Where a build of `version` lives. The app builds every address itself.
    static func assetURL(_ platform: HelperPlatform, version: ReleaseVersion) -> String {
        "\(base)helper-v\(version)/\(platform.asset)"
    }

    /// A fetch may go only to these hosts, over https, on the default port.
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), url.user() == nil, url.password() == nil,
              url.port == nil || url.port == 443 else { return false }
        return hosts.contains(host)
    }

    // MARK: Signatures

    /// A signature file is one base64 signature of 64 bytes per line. One that verifies under one
    /// of `keys` is enough, so a list can carry the old key's and the new key's while helpers move
    /// from one to the other.
    static func verify(keys: [Data], message: Data, signatureFile: Data) -> Bool {
        signer(keys: keys, message: message, signatureFile: signatureFile) != nil
    }

    /// The key that made one of the file's signatures: the first of `keys`, in their order, that
    /// a signature verifies under. Nil when none does.
    static func signer(keys: [Data], message: Data, signatureFile: Data) -> Data? {
        guard let text = String(data: signatureFile, encoding: .utf8) else { return nil }
        let signatures = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(maxSignatures)
            .compactMap { Data(base64Encoded: $0) }
            .filter { $0.count == 64 }
        return keys.first { raw in
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return signatures.contains { key.isValidSignature($0, for: message) }
        }
    }

    /// The most keys the installer takes.
    static let installerKeyLimit = 6

    /// The keys handed to the installer, base64: the one that signed the release list first, then
    /// the rest of `trusted` in their order, six at most.
    static func installerKeys(signer: Data, trusted: [Data]) -> [String] {
        var keys = [signer]
        for key in trusted where !keys.contains(key) { keys.append(key) }
        return keys.prefix(installerKeyLimit).map { $0.base64EncodedString() }
    }

    /// What a Linux build's signature covers: the version and the platform as well as the hash, so
    /// a signature belongs to one build of one version.
    static func binaryMessage(version: ReleaseVersion, platform: HelperPlatform, sha256: String) -> Data {
        Data("rex-duo-helper|\(version)|\(platform.rawValue)|\(sha256.lowercased())".utf8)
    }

    // MARK: The release list

    /// Reads manifest.json. Called only on bytes whose signature was checked.
    static func parse(_ data: Data) throws -> ReleaseManifest {
        func bad(_ what: String) -> ReleaseFault { .malformed(what) }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw bad("json") }
        guard let version = (o["version"] as? String).flatMap(ReleaseVersion.init) else { throw bad("version") }
        guard let minVersion = (o["min_version"] as? String).flatMap(ReleaseVersion.init), minVersion <= version else {
            throw bad("min_version")
        }
        guard let expiresAt = (o["expires_at"] as? String).flatMap(timestamp) else { throw bad("expires_at") }
        var nextKey: String?
        if let raw = o["next_key"], !(raw is NSNull) {
            guard let text = raw as? String, HelperKeys.key(text) != nil else { throw bad("next_key") }
            nextKey = text
        }
        guard let listed = o["assets"] as? [String: Any] else { throw bad("assets") }
        var assets: [HelperPlatform: ReleaseAsset] = [:]
        /// One entry of the list: nil when the list leaves it out; one it names must be right.
        func entry(_ key: String, at address: String) throws -> ReleaseAsset? {
            guard let raw = listed[key] else { return nil }
            guard let a = raw as? [String: Any] else { throw bad(key) }
            // The address must be the one this app would build, to the letter.
            guard a["url"] as? String == address else { throw bad("\(key) url") }
            guard let hash = a["sha256"] as? String, isHex64(hash.lowercased()), hash.utf8.count == 64 else {
                throw bad("\(key) sha256")
            }
            guard let size = wholeNumber(a["size"]), (1...maxAsset).contains(size) else { throw bad("\(key) size") }
            return ReleaseAsset(sha256: hash.lowercased(), size: size)
        }
        for platform in HelperPlatform.allCases {
            assets[platform] = try entry(platform.rawValue, at: assetURL(platform, version: version))
        }
        // The Mac app under its own name, Rex DUO Beacon. A list that has this entry also keeps
        // the earlier one, the same app in a folder of the earlier name, for the versions that
        // update themselves from it. The installer takes either file; the app gives it this one.
        if let beacon = try entry(macBeaconKey, at: "\(base)helper-v\(version)/\(macBeaconAsset)") {
            assets[.mac] = beacon
        }
        return ReleaseManifest(version: version, minVersion: minVersion, expiresAt: expiresAt, nextKey: nextKey, assets: assets)
    }

    /// Decides whether the bytes of a release list are believed, in this order: a signature from a
    /// trusted key, then the contents, then that it hasn't expired, then that it isn't older than
    /// the newest list this phone accepted or than the oldest helper this app installs.
    static func accept(_ data: Data, signatureFile: Data, trusted: [Data], highWater: ReleaseVersion?, floor: ReleaseVersion = floor,
                       now: Date) throws -> ReleaseManifest {
        try accepted(data, signatureFile: signatureFile, trusted: trusted, highWater: highWater, floor: floor, now: now).manifest
    }

    /// `accept`, also saying which of the trusted keys signed the list.
    static func accepted(_ data: Data, signatureFile: Data, trusted: [Data], highWater: ReleaseVersion?, floor: ReleaseVersion = floor,
                         now: Date) throws -> (manifest: ReleaseManifest, signer: Data) {
        guard let signer = signer(keys: trusted, message: data, signatureFile: signatureFile) else { throw ReleaseFault.untrusted }
        let manifest = try parse(data)
        guard now < manifest.expiresAt else { throw ReleaseFault.expired }
        guard manifest.version >= max(floor, highWater ?? floor) else { throw ReleaseFault.tooOld }
        return (manifest, signer)
    }

    /// `accept` against what the phone remembers, which it then brings up to date: the newest
    /// version accepted, and a key the list hands over. Only an accepted list changes either.
    /// `signer` is the trusted key that signed the list.
    static func acceptAndRemember(_ data: Data, signatureFile: Data, builtin: [Data], memory: inout ReleaseMemory,
                                  floor: ReleaseVersion = floor, now: Date) throws
        -> (manifest: ReleaseManifest, trust: ReleaseTrust, signer: Data) {
        var trust = ReleaseTrust(builtin: builtin, handed: memory.handedKeys.compactMap(HelperKeys.key))
        let highWater = memory.highWater.flatMap(ReleaseVersion.init)
        let (manifest, signer) = try accepted(data, signatureFile: signatureFile, trusted: trust.keys, highWater: highWater,
                                              floor: floor, now: now)
        if highWater.map({ manifest.version > $0 }) ?? true { memory.highWater = manifest.version.description }
        if let next = manifest.nextKey.flatMap(HelperKeys.key), trust.handOver(next) {
            memory.handedKeys = trust.handed.map { $0.base64EncodedString() }
        }
        return (manifest, trust, signer)
    }

    /// The date the publisher has to renew the list by, when that is within the renewal window.
    static func renewalDue(expiresAt: Date, now: Date) -> Date? {
        expiresAt.timeIntervalSince(now) < renewalWindow ? expiresAt : nil
    }

    /// The quiet line for that date.
    static func renewalNotice(expiresAt: Date, now: Date) -> String? {
        guard let due = renewalDue(expiresAt: expiresAt, now: now) else { return nil }
        return "Rex DUO Beacon updates need renewing by \(due.formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: Fields

    /// `YYYY-MM-DDTHH:MM:SSZ`, exactly: 20 characters, UTC.
    static func timestamp(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard b.count == 20 else { return nil }
        for (i, c) in b.enumerated() {
            let want: UInt8? = switch i {
            case 4, 7: 0x2D
            case 10: 0x54
            case 13, 16: 0x3A
            case 19: 0x5A
            default: nil
            }
            guard want.map({ $0 == c }) ?? (0x30...0x39).contains(c) else { return nil }
        }
        func n(_ r: Range<Int>) -> Int { b[r].reduce(0) { $0 * 10 + Int($1 - 0x30) } }
        let (y, m, d, h, min, s) = (n(0..<4), n(5..<7), n(8..<10), n(11..<13), n(14..<16), n(17..<19))
        guard (1970...9999).contains(y), (1...12).contains(m), (1...31).contains(d), h <= 23, min <= 59, s <= 59 else { return nil }
        // Days since 1970 from a civil date, the same arithmetic the helper uses.
        let y2 = m <= 2 ? y - 1 : y
        let era = y2 / 400, yoe = y2 % 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let seconds = (era * 146_097 + doe - 719_468) * 86_400 + h * 3600 + min * 60 + s
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// 64 characters, each `0-9` or `a-f`.
    static func isHex64(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A JSON number that is a whole, non-negative number. `true` and `1.5` are not.
    private static func wholeNumber(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d >= 0, d <= 9_007_199_254_740_992, d == d.rounded() else { return nil }
        return Int(d)
    }
}

// MARK: - What the phone remembers

/// Where `ReleaseMemory` is kept. The Keychain on a device; memory in tests. Both calls throw
/// when the store didn't do what was asked, so "nothing accepted yet" and "can't tell" never
/// look alike.
protocol ReleaseMemoryStore: AnyObject {
    func load() throws -> ReleaseMemory
    func save(_ memory: ReleaseMemory) throws
}

final class InMemoryReleaseStore: ReleaseMemoryStore {
    var value: ReleaseMemory
    init(_ value: ReleaseMemory = ReleaseMemory()) { self.value = value }
    func load() -> ReleaseMemory { value }
    func save(_ memory: ReleaseMemory) { value = memory }
}

/// One Keychain item, on this device only (`KeychainItem`).
final class KeychainReleaseStore: ReleaseMemoryStore {
    private let item: KeychainItem

    init(service: String = "dev.abrahamgonzalez.rexduo.helper-release", keychain: KeychainCalls = .system) {
        item = KeychainItem(service: service, account: "helper-release", keychain: keychain)
    }

    func load() throws -> ReleaseMemory {
        guard let data = try item.read() else { return ReleaseMemory() }
        return try JSONDecoder().decode(ReleaseMemory.self, from: data)
    }

    func save(_ memory: ReleaseMemory) throws {
        try item.write(try JSONEncoder().encode(memory))
    }
}

// MARK: - Fetching

/// Gets the current release and checks it: the list and its signature, then each Linux build's
/// own signature. It downloads no build. `transport` is the network, replaced in tests; it returns
/// the body of one address, or throws.
@MainActor
struct HelperReleaseFetcher {
    var transport: @Sendable (URL) async throws -> Data
    var store: ReleaseMemoryStore
    var builtin: [Data] = HelperKeys.builtin
    var floor = HelperRelease.floor
    var now: () -> Date = { Date() }

    private static let log = Logger(subsystem: "dev.abrahamgonzalez.rexduo", category: "helper-setup")

    init(transport: (@Sendable (URL) async throws -> Data)? = nil, store: ReleaseMemoryStore) {
        self.transport = transport ?? ReleaseTransport.fetch
        self.store = store
    }

    func verified() async -> Result<VerifiedRelease, ReleaseFault> {
        do {
            let data = try await get(HelperRelease.manifestURL)
            let signature = try await get(HelperRelease.signatureURL)
            var memory: ReleaseMemory
            do { memory = try store.load() } catch { throw ReleaseFault.storeFailed }
            let before = memory
            let (manifest, trust, signer) = try HelperRelease.acceptAndRemember(data, signatureFile: signature, builtin: builtin,
                                                                                memory: &memory, floor: floor, now: now())
            if memory != before {
                do { try store.save(memory) } catch { throw ReleaseFault.storeFailed }
            }
            if let due = HelperRelease.renewalDue(expiresAt: manifest.expiresAt, now: now()) {
                Self.log.notice("the helper release list needs renewing by \(due, privacy: .public)")
            }
            var assets: [HelperPlatform: ReleaseAsset] = [:]
            for platform in HelperPlatform.allCases {
                guard let asset = manifest.assets[platform] else { throw ReleaseFault.malformed("\(platform.rawValue) missing") }
                if platform.hasSignatureFile {
                    let file = try await get(HelperRelease.assetURL(platform, version: manifest.version) + ".sig")
                    let message = HelperRelease.binaryMessage(version: manifest.version, platform: platform, sha256: asset.sha256)
                    guard HelperRelease.verify(keys: trust.keys, message: message, signatureFile: file) else {
                        throw ReleaseFault.assetSignature(platform)
                    }
                }
                assets[platform] = asset
            }
            return .success(VerifiedRelease(version: manifest.version, minVersion: manifest.minVersion, assets: assets,
                                            expiresAt: manifest.expiresAt,
                                            keys: HelperRelease.installerKeys(signer: signer, trusted: trust.keys)))
        } catch let fault as ReleaseFault {
            return .failure(fault)
        } catch {
            return .failure(.unreachable)
        }
    }

    /// The app's fetcher: the release list from its real address, remembered in the Keychain.
    static func standard(defaults: UserDefaults = .standard) -> HelperReleaseFetcher {
        #if DEBUG
        // `-helperReleaseMirror <http://127.0.0.1:port>` (debug builds): read the release list from
        // a copy of the release folders on this machine. The list is still checked against the
        // built-in keys; the installer on the computer still downloads from the real address.
        if let mirror = defaults.string(forKey: "helperReleaseMirror"), let root = URL(string: mirror),
           root.host == "127.0.0.1" || root.host == "localhost" {
            return HelperReleaseFetcher(transport: { url in
                let path = url.absoluteString.replacingOccurrences(of: HelperRelease.base, with: "")
                let (data, response) = try await URLSession.shared.data(from: root.appendingPathComponent(path))
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= HelperRelease.maxDocument else {
                    throw ReleaseFault.unreachable
                }
                return data
            }, store: KeychainReleaseStore())
        }
        #endif
        return HelperReleaseFetcher(store: KeychainReleaseStore())
    }

    private func get(_ address: String) async throws -> Data {
        guard let url = URL(string: address), HelperRelease.allowed(url) else { throw ReleaseFault.unreachable }
        let data: Data
        do { data = try await transport(url) } catch { throw ReleaseFault.unreachable }
        guard data.count <= HelperRelease.maxDocument else { throw ReleaseFault.unreachable }
        return data
    }
}

/// The network under `HelperReleaseFetcher`: one GET on a session that keeps nothing (no cookies,
/// no cache, no credentials), follows a redirect only to the release hosts, and stops reading at
/// the size limit.
enum ReleaseTransport {
    static let fetch: @Sendable (URL) async throws -> Data = { url in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.urlCredentialStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg, delegate: Redirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = http.url, HelperRelease.allowed(final),
              http.expectedContentLength <= Int64(HelperRelease.maxDocument) else {
            throw ReleaseFault.unreachable
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < HelperRelease.maxDocument else { throw ReleaseFault.unreachable }
            data.append(byte)
        }
        return data
    }

    /// Lets a redirect through only when it stays on the release hosts.
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, HelperRelease.allowed(url) else { return nil }
            return request
        }
    }
}
