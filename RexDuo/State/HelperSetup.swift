import CryptoKit
import Foundation
import GlanceModel
import RexKit

// Installing Beacon from the phone, without the network or Rex in it: what the installer
// is told, what its progress means, and what the sheet shows for it. `HelperSetupRunner` drives
// these against a real server. The flow is described in docs/notifications.md.

// MARK: - What the installer is told

/// The installer's arguments. The script in the app bundle runs as
/// `/bin/sh -c <script> rexduo-setup <12 arguments>`, with no shell reading any of them. Each
/// value is checked against its own pattern here, and the script checks it again. The run's setup
/// code is not among them: it goes to the script's terminal once the script asks (`SetupCode`).
struct SetupArgs: Equatable {
    enum Linger: String { case ask, skip }

    /// Everything as text, the way it reaches the script.
    struct Fields: Equatable {
        var version: String
        var floor: String
        var macHash: String
        var macSize: String
        var linuxX64Hash: String
        var linuxX64Size: String
        var linuxArm64Hash: String
        var linuxArm64Size: String
        /// One to six keys joined by `,`, the one that signed the release list first.
        var keys: String
        var linger: String
    }

    static let mode = "2"
    /// The script's remove mode: it stops the helper and deletes it, and takes nothing else.
    static let removeMode = "3"
    static let count = 12
    static let shell = "/bin/sh"
    static let name = "rexduo-setup"
    /// The last argument, kept for a later use.
    static let reserved = "-"

    /// The 12 arguments, in the script's order.
    let values: [String]

    /// Nil unless every field is in its pattern. Nothing is trimmed, cut or escaped to make a
    /// value fit: a value that doesn't fit means no arguments at all.
    init?(_ f: Fields) {
        let hashes = [f.macHash, f.linuxX64Hash, f.linuxArm64Hash]
        let sizes = [f.macSize, f.linuxX64Size, f.linuxArm64Size]
        guard hashes.allSatisfy(HelperRelease.isHex64), sizes.allSatisfy(Self.isSize),
              Self.isVersion(f.version), Self.isVersion(f.floor), Self.isKeyList(f.keys),
              Linger(rawValue: f.linger) != nil else { return nil }
        values = [Self.mode, f.version, f.floor, f.macHash, f.macSize, f.linuxX64Hash, f.linuxX64Size,
                  f.linuxArm64Hash, f.linuxArm64Size, f.keys, f.linger, Self.reserved]
    }

    /// The arguments for a release the phone verified, with the keys in the release's order.
    init?(release: VerifiedRelease, floor: ReleaseVersion = HelperRelease.floor, linger: Linger) {
        guard let mac = release.assets[.mac], let x64 = release.assets[.linuxX64], let arm64 = release.assets[.linuxArm64] else { return nil }
        self.init(Fields(version: release.version.description, floor: floor.description,
                         macHash: mac.sha256, macSize: String(mac.size),
                         linuxX64Hash: x64.sha256, linuxX64Size: String(x64.size),
                         linuxArm64Hash: arm64.sha256, linuxArm64Size: String(arm64.size),
                         keys: release.keys.joined(separator: ","), linger: linger.rawValue))
    }

    /// The whole command for the terminal block: the shell by its absolute path, the script as one
    /// argument, the name it runs under, then the 12 values.
    func command(script: String) -> [String] {
        [Self.shell, "-c", script, Self.name] + values
    }

    /// The whole command that removes the helper: the same shell, script and name, then the
    /// remove mode and the reserved `-`. Nothing of the server's, the release's or the phone's is
    /// in it.
    static func removeCommand(script: String) -> [String] {
        [shell, "-c", script, name, removeMode, reserved]
    }

    // The patterns, on bytes, so only the plain ASCII characters count.

    private static func isDigit(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) }

    /// `^(0|[1-9][0-9]{0,3})(\.(0|[1-9][0-9]{0,3})){2}$`
    static func isVersion(_ text: String) -> Bool {
        let parts = text.utf8.split(separator: 0x2E, omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { part in
            (1...4).contains(part.count) && part.allSatisfy(isDigit) && (part.count == 1 || part.first != 0x30)
        }
    }

    /// `^[1-9][0-9]{0,7}$`
    static func isSize(_ text: String) -> Bool {
        (1...8).contains(text.utf8.count) && text.utf8.allSatisfy(isDigit) && text.utf8.first != 0x30
    }

    /// `^[A-Za-z0-9+/]{43}=$`
    static func isKey(_ text: String) -> Bool {
        isKey(Array(text.utf8)[...])
    }

    /// One to six keys with a `,` between each two.
    static func isKeyList(_ text: String) -> Bool {
        let keys = Array(text.utf8).split(separator: 0x2C, omittingEmptySubsequences: false)
        return (1...HelperRelease.installerKeyLimit).contains(keys.count) && keys.allSatisfy(isKey)
    }

    private static func isKey(_ b: ArraySlice<UInt8>) -> Bool {
        guard b.count == 44, b.last == 0x3D else { return false }
        return b.dropLast().allSatisfy { isDigit($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2B || $0 == 0x2F }
    }
}

// MARK: - The setup code

/// The run's one-time setup code: 32 random bytes as 64 hex characters, made by the phone. It
/// reaches the computer one way only: typed into the installer's terminal when the installer asks
/// for it, with echo off. It is in no command, no option of the block and no log. The installer
/// passes it to the helper it installs, which then shows it holds it (`SetupProof`).
enum SetupCode {
    /// The step token of the installer's request for the code.
    static let token = "code"

    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// The installer asks for the code now, and this run hasn't answered yet.
    static func isRequest(_ record: SetupRecord, answered: Bool) -> Bool {
        !answered && record.token == token && record.state == "working"
    }

    /// Whether the code may be typed into the setup terminal: only while the terminal has echo
    /// off and the program in front is the shell the block started, which runs the installer.
    /// `inputMode` is the terminal's `input_mode` reply, `process` its `process` reply. A reply
    /// that is missing, or missing a field, is a no.
    static func allows(inputMode: JSONObject?, process: JSONObject?) -> Bool {
        guard let inputMode, inputMode.bool("echo") == false else { return false }
        return frontIsInstaller(process)
    }

    /// The program in front is the block's own program, or a copy of it that it started: the
    /// shell reading a line for the script.
    static func frontIsInstaller(_ process: JSONObject?) -> Bool {
        guard let child = process?.obj("child"), let front = process?.obj("foreground"),
              let started = child.int("pid"), let pid = front.int("pid") else { return false }
        if pid == started { return true }
        // A part of the script that runs in a shell of its own: the same executable, started by
        // the block's program and by nothing else in between.
        guard let path = child.str("path"), front.str("path") == path, let ancestors = process?.arr("ancestors"),
              !ancestors.isEmpty, ancestors.last?.int("pid") == started else { return false }
        return ancestors.allSatisfy { $0.str("path") == path }
    }

    /// What is typed: the code, then Return.
    static func input(_ code: String) -> String { code + "\r" }
}

/// The block the installer runs in: a terminal that starts the command directly, with no shell of
/// the user's around it, and stays open after the command exits so its output can still be read.
enum SetupBlock {
    static let label = "\(Brand.beaconName) setup"
    static let flavor = "com.superlogical.terminal.shell"
    /// The oldest control API whose terminal takes a program to run directly (`command` with
    /// `shell: "none"`). The options themselves are checked too, in `supported`.
    static let minRevision = 13

    static func layout(command: [String], theme: TermTheme) -> JSONObject {
        ["block": [
            "flavor": flavor,
            "label": SetupArgs.name,
            "options": [
                "shell": "none",
                "command": command,
                "size": ["columns": 80, "rows": 24],
                "theme": ["foreground": theme.foreground, "background": theme.background, "cursor": theme.cursor],
                "exit": ["on_completion": false],
            ] as JSONObject,
        ] as JSONObject]
    }

    /// `session.create`'s payload: a session of its own, so no tab of the user's is touched.
    static func session(command: [String], theme: TermTheme) -> JSONObject {
        ["label": label, "initial_windows": [["window_label": label, "layout": layout(command: command, theme: theme)] as JSONObject]]
    }

    /// `session.new_window`'s payload, for a server that is at its session limit. The user's
    /// active tab stays the active one.
    static func window(in session: String, command: [String], theme: TermTheme) -> JSONObject {
        ["session_id": session, "window_label": label, "focus": false, "layout": layout(command: command, theme: theme)]
    }

    /// Whether this server can run the installer: its API is new enough, and its terminal's
    /// options include `command` and `shell`. `version` is `server.version`, `creators` is
    /// `block_creator.list`.
    static func supported(version: JSONObject, creators: JSONObject) -> Bool {
        guard (version.int("api_revision") ?? 0) >= minRevision else { return false }
        let flavors = creators.arr("creators").flatMap { $0.arr("flavors") }
        guard let properties = flavors.first(where: { $0.str("flavor") == flavor })?.obj("options_schema")?.obj("properties") else {
            return false
        }
        return properties["command"] != nil && properties["shell"] != nil
    }
}

// MARK: - Proof that the helper is the one this run installed

/// The helper answers `helper_identity` with `setup_proof` while it holds a setup code: an HMAC
/// keyed by the code, which only this run of the app and the helper that install started know.
/// A run pins a helper's key and reports Connected only for a helper that showed this proof.
enum SetupProof {
    static let version = "rexduo-setup-v1"
    /// The most requests for a proof one run makes. The helper answers this many per code.
    static let requests = 3

    /// What a helper's reply held.
    enum Answer: Equatable {
        /// No proof in the reply: the helper holds no code, or not yet.
        case missing
        /// A proof that isn't this run's.
        case wrong
        case valid
    }

    static func message(challenge: String, helper: String, requester: String) -> Data {
        Data([version, challenge, helper, requester].joined(separator: "\n").utf8)
    }

    /// Reads the `setup_proof` of a `helper_identity` reply.
    static func answer(proof: String?, code: String, challenge: String, helper: String, requester: String) -> Answer {
        guard let proof else { return .missing }
        return verify(proof: proof, code: code, challenge: challenge, helper: helper, requester: requester) ? .valid : .wrong
    }

    /// True when `proof` (base64 of 32 bytes) is the HMAC-SHA256 of the message under the 32
    /// bytes the code's hex stands for.
    static func verify(proof: String?, code: String, challenge: String, helper: String, requester: String) -> Bool {
        guard let proof, let mac = Data(base64Encoded: proof), mac.count == 32, let key = bytes(hex: code), key.count == 32 else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message(challenge: challenge, helper: helper, requester: requester),
                                                      using: SymmetricKey(data: key))
    }

    static func bytes(hex: String) -> Data? {
        let b = Array(hex.utf8)
        guard b.count % 2 == 0 else { return nil }
        func value(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x61...0x66: c - 0x61 + 10
            default: nil
            }
        }
        var out = Data(capacity: b.count / 2)
        for i in stride(from: 0, to: b.count, by: 2) {
            guard let hi = value(b[i]), let lo = value(b[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        return out
    }
}

/// A setup run's `register_push` carries `setup_seal`: an HMAC keyed by the run's setup code over
/// the secret and the phone's install id. It tells the helper that the registration comes from
/// the phone that holds the code.
enum SetupSeal {
    static let version = "rexduo-setup-register-v1"

    static func message(secret: String, device: String) -> Data {
        Data([version, secret, device].joined(separator: "\n").utf8)
    }

    /// Base64 of the HMAC-SHA256 of the message under the 32 bytes the code's hex stands for.
    /// Nil for a code that isn't 64 hex characters.
    static func make(code: String, secret: String, device: String) -> String? {
        guard let key = SetupProof.bytes(hex: code), key.count == 32 else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: message(secret: secret, device: device), using: SymmetricKey(data: key))
        return Data(mac).base64EncodedString()
    }
}

/// The arguments of `register_push`.
enum PushRegistration {
    /// `setup` is where the server's install stands and `code` that install's setup code. The
    /// seal is added only for the helper that showed the install's proof. `presenceKey` is the
    /// phone's presence key, given only for a computer confirmed as the person's own; without
    /// it the argument is left out, and a helper that held a key lets it go.
    static func arguments(gateway: String, secret: String, environment: String, deviceName: String, deviceID: String,
                          setup: HelperAdmission.Setup = .none, code: String? = nil, presenceKey: PresenceKey? = nil) -> JSONObject {
        var args: JSONObject = ["gateway": gateway, "push_secret": secret, "environment": environment,
                                "device_name": deviceName, "device_id": deviceID]
        if let presenceKey { args["presence_key"] = presenceKey.wireValue }
        if setup == .proven(sameKey: true), let code, let seal = SetupSeal.make(code: code, secret: secret, device: deviceID) {
            args["setup_seal"] = seal
        }
        return args
    }
}

/// What a registration does with the key a helper proved, given the key pinned for the server
/// and whether an install is deciding who the server's helper is.
///
/// A helper's key is pinned on first use only outside an install. During an install that sent a
/// setup code, a helper is registered, and its key pinned, only once it showed that run's proof;
/// that also replaces a key pinned before, so a reinstall needs no "Trust".
enum HelperAdmission: Equatable {
    enum Pin: Equatable {
        /// The pinned key is this one.
        case keep
        /// Nothing is pinned: pin this key.
        case first
        /// Another key is pinned: this one takes its place, and the old secret is deleted.
        case replace
    }

    /// Where the server's install stands.
    enum Setup: Equatable {
        /// No install sent a code for this server.
        case none
        /// An install sent its code and no helper has shown the proof yet.
        case unproven
        /// A helper showed the proof. `sameKey`: it is the helper asking now.
        case proven(sameKey: Bool)
    }

    case register(Pin)
    /// Give it nothing and keep its key for "Trust" in Settings.
    case changed
    /// Give it nothing for now: the install decides.
    case wait

    /// `heldBack`: an install on this server ended without a proof, so the helper there waits
    /// for "Trust" even when nothing is pinned.
    static func decide(pin: HelperIdentity.Pin, setup: Setup, heldBack: Bool) -> HelperAdmission {
        switch setup {
        case .unproven, .proven(sameKey: false):
            return .wait
        case .proven(sameKey: true):
            switch pin {
            case .same: return .register(.keep)
            case .first: return .register(.first)
            case .changed: return .register(.replace)
            }
        case .none:
            switch pin {
            case .same: return .register(.keep)
            case .first: return heldBack ? .changed : .register(.first)
            case .changed: return .changed
            }
        }
    }
}

// MARK: - The password for "keep running after logout"

/// Decides whether a password may be typed into the setup terminal. Only while the terminal has
/// echo off and the program in front is one of the two that ask for it; otherwise the person
/// types it on the computer.
enum PasswordGuard {
    static let programs: Set<String> = ["/usr/bin/pkttyagent", "/usr/bin/loginctl", "/bin/loginctl"]

    /// `inputMode` is the terminal's `input_mode` reply, `process` its `process` reply. A reply
    /// that is missing, or missing the field, is a no.
    static func allows(inputMode: JSONObject?, process: JSONObject?) -> Bool {
        guard let inputMode, inputMode.bool("echo") == false else { return false }
        return frontIsPrompt(process)
    }

    /// The program in front is one that reads the password.
    static func frontIsPrompt(_ process: JSONObject?) -> Bool {
        guard let path = process?.obj("foreground")?.str("path") else { return false }
        return programs.contains(path)
    }
}

// MARK: - Whether to offer the install

enum HelperOffer: Equatable {
    /// Offer to install.
    case install
    /// The computer is someone else's: say to ask them.
    case askOwner
    /// Nothing to offer: a system the helper doesn't run on, a helper already there, or an install
    /// already under way.
    case none

    /// Whether the app can run Beacon's installer on a computer of this platform
    /// (`server.version`'s, such as `darwin_arm64`): macOS and Linux. The installer is a shell
    /// script, so install, repair, reinstall and removal are each offered and run only where this
    /// holds. A platform not known yet is a no.
    static func installable(platform: String?) -> Bool {
        guard let platform = platform?.lowercased() else { return false }
        return platform.hasPrefix("darwin_") || platform.hasPrefix("linux_")
    }

    /// - `platform`: `server.version`'s, such as `darwin_arm64`.
    /// - `hasHelper`: a helper is connected on the server's own machine.
    /// - `owner`, `viewer`: the logins `ServerIdentity` reads; only two known, different logins
    ///   mean someone else's computer.
    /// - `running`: an install for this server is under way.
    static func decide(platform: String?, hasHelper: Bool, owner: String?, viewer: String?, running: Bool) -> HelperOffer {
        guard installable(platform: platform) else { return .none }
        guard !hasHelper, !running else { return .none }
        if let owner, let viewer, owner.caseInsensitiveCompare(viewer) != .orderedSame { return .askOwner }
        return .install
    }

    /// The same question right after pairing, from the identity card's facts. An identity that
    /// didn't say (no answer, an unknown system) offers nothing.
    static func decide(_ identity: ServerIdentity?) -> HelperOffer {
        guard let identity, identity.hasHelper == false else { return .none }
        let platform: String? = switch identity.platform {
        case .mac: "darwin_"
        case .linux: "linux_"
        default: nil
        }
        return decide(platform: platform, hasHelper: false, owner: identity.owner, viewer: identity.viewer, running: false)
    }
}

// MARK: - Progress

/// One progress report from the installer: its OSC 7501 record, as Rex passes it on.
struct SetupRecord: Equatable {
    static let id = "rexduo-setup"

    var state: String
    /// The step token: `download`, `verify`, `code`, `install`, `start`, `notify`, `linger`,
    /// `done`, `fail:<CODE>`.
    var token: String
    var progress: Int?
    /// What a blocked record waits for.
    var kind: String?
    /// When Rex received it. Two reports of one state differ in this.
    var updatedAt: String?

    init(state: String, token: String, progress: Int? = nil, kind: String? = nil, updatedAt: String? = nil) {
        self.state = state
        self.token = token
        self.progress = progress
        self.kind = kind
        self.updatedAt = updatedAt
    }

    /// Nil for a record that isn't the installer's.
    init?(_ record: JSONObject) {
        guard record.str("id") == Self.id, record.str("app") == Self.id else { return nil }
        self.init(state: record.str("state") ?? "idle", token: record.str("title") ?? "", progress: record.int("progress"),
                  kind: record.str("kind"), updatedAt: record.str("updated_at"))
    }

    /// The installer's record among a terminal's `program_status` records.
    static func find(in records: [JSONObject]) -> SetupRecord? {
        records.lazy.compactMap(SetupRecord.init).first
    }
}

/// Why an install stopped, with the sentence and the buttons the sheet shows for it.
enum SetupError: Equatable {
    case network, noDownloader, verify, release, unsupportedComputer, oldMacOS, write, busy
    /// Installed, but the helper didn't start or didn't connect in time.
    case notStarted
    case noGUI, noSystemd, appManagement, interrupted
    /// iOS doesn't let the app show notifications.
    case notificationsOff
    /// The helper there didn't show that this install started it.
    case identityChanged
    /// This server's Rex can't run the installer.
    case manual

    enum Action: Equatable { case tryAgain, repair, openSettings, showDetails, close }

    /// The installer's exit code. 0 is no error.
    init?(exitCode: Int) {
        switch exitCode {
        case 0: return nil
        case 10: self = .release
        case 11: self = .unsupportedComputer
        case 12: self = .noDownloader
        case 13: self = .network
        case 14: self = .verify
        case 15: self = .write
        case 16: self = .busy
        case 17: self = .notStarted
        case 18: self = .noGUI
        case 19: self = .noSystemd
        case 20: self = .appManagement
        case 21: self = .oldMacOS
        default: self = .interrupted
        }
    }

    func message(name: String) -> String {
        switch self {
        case .network: "\(name) couldn't download \(Brand.beaconName). Check the internet connection on \(name), then try again."
        case .noDownloader: "\(name) needs curl to download \(Brand.beaconName). Install curl on \(name), then try again."
        case .verify: "The download didn't pass its security check, so nothing was installed. Try again later."
        case .release: "\(Brand.appName) can't get Beacon right now. Try again later."
        case .unsupportedComputer: "\(Brand.beaconName) isn't available for this computer yet."
        case .oldMacOS: "\(Brand.beaconName) needs macOS 14 or later."
        case .write: "\(name) couldn't save \(Brand.beaconName). Free up space on \(name), then try again."
        case .busy: "Another install is already running on \(name)."
        case .notStarted: "\(Brand.beaconName) is installed but didn't start."
        case .noGUI: "Log in on \(name), then try again."
        case .noSystemd: "\(name) doesn't start background services the usual way. Show Details says how to start \(Brand.beaconName)."
        case .appManagement: "\(name) didn't let Rex replace the old \(Brand.beaconName). On \(name), drag \(Brand.beaconName) from Applications to the Trash, then try again."
        case .interrupted: "The install stopped before it finished."
        case .notificationsOff: "Notifications are off for \(Brand.appName)."
        case .identityChanged: "\(Brand.beaconName) on \(name) has changed. Only trust Beacon if you reinstalled it on \(name)."
        case .manual: "Rex on \(name) is too old to install \(Brand.beaconName) from here. Update Rex on \(name), or install Beacon by hand.\nMac: drag \(Brand.beaconName) to Applications and open it once.\nLinux: run the command below."
        }
    }

    /// The buttons, first one filled. `hasTab` is false when nothing ran on the computer, so
    /// there are no details to show.
    func actions(hasTab: Bool) -> [Action] {
        let first: [Action] = switch self {
        case .network, .noDownloader, .verify, .release, .write, .noGUI, .appManagement, .interrupted: [.tryAgain]
        case .notStarted: [.repair]
        case .notificationsOff: [.openSettings]
        case .unsupportedComputer, .oldMacOS, .busy, .noSystemd, .identityChanged, .manual: []
        }
        return first + (hasTab ? [.showDetails] : []) + [.close]
    }

    static func connectionLost(name: String) -> String {
        "Lost the connection to \(name). The install keeps going on \(name), and \(Brand.appName) catches up when it reconnects."
    }
}

/// What the install sheet shows, as a function of what has happened so far. Events go in
/// (`handle`); the step list, the card for something a person has to do, and the error come out.
///
/// The installer's own reports only move the step list. "Connected" needs three things that no
/// terminal output can supply: the installer exited with 0, the helper showed this run's setup
/// proof (`proof(.valid)`), and that helper registered with this phone (`helperRegistered`, which
/// follows `PushRegistrar` pinning its key and handing it its secret). The proof is asked for
/// once the installer's `start` step is over, at most `SetupProof.requests` times; a run whose
/// helper shows none, or a wrong one, ends as `identityChanged`.
struct SetupState: Equatable {
    enum Kind: Equatable { case install, repair, reinstall }
    enum Computer: Equatable { case mac, linux }

    /// The four rows of the sheet.
    enum Step: Int, CaseIterable, Comparable {
        case downloading, verifying, installing, connected

        var title: String {
            switch self {
            case .downloading: "Downloading"
            case .verifying: "Checking"
            case .installing: "Installing"
            case .connected: "Connected"
            }
        }

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    enum Phase: Equatable {
        /// Asking iOS, reading the release, opening the tab on the computer.
        case preparing
        /// The installer runs.
        case running
        /// The installer finished; waiting for the helper to connect and register.
        case connecting
        case connected
        case failed(SetupError)
        /// Stopped by the person.
        case cancelled
    }

    enum Human: Equatable {
        /// Mac: click Allow on the computer.
        case allowNotifications
        /// Linux: the password that lets the helper keep running after logout.
        case password(wrong: Bool)
        /// The person chose to type that password on the computer.
        case passwordOnComputer
    }

    enum Event: Equatable {
        /// The release was verified; `version` is the helper's.
        case release(version: String)
        /// The tab is open on the computer and the installer is starting.
        case started
        case record(SetupRecord)
        case exited(code: Int)
        /// The helper answered one request for the setup proof.
        case proof(SetupProof.Answer)
        /// The helper that showed the proof registered with this phone.
        case helperRegistered
        /// The setup code couldn't be typed into the installer's terminal, so the tab was closed.
        case codeRefused
        /// 60 s passed after the installer finished with no helper.
        case connectTimeout
        /// `helper_status.notices`, once the helper said: allowed, denied, undetermined, or nil.
        case notices(String?)
        /// Done on the "click Allow" card.
        case humanDone
        case passwordSent
        /// The guard refused, so the password wasn't sent.
        case passwordRefused
        case passwordOnComputer
        case passwordSkipped
        case connectionLost
        /// Reconnected: the installer's latest record and how it exited, read from the server.
        /// `gone` when its tab no longer exists.
        case caughtUp(record: SetupRecord?, exitCode: Int?, gone: Bool)
        case fail(SetupError)
        case cancel
        /// The tab on the computer is closed: there are no details to show any more.
        case tabClosed
    }

    let kind: Kind
    let computer: Computer
    private(set) var phase = Phase.preparing
    /// The row in progress while the installer runs.
    private(set) var step = Step.downloading
    /// Only when the installer reported one.
    private(set) var progress: Int?
    private(set) var version: String?
    private(set) var human: Human?
    private(set) var connectionLost = false
    /// The password couldn't be typed from here: the card says to type it on the computer.
    private(set) var passwordRefused = false
    /// A tab exists on the computer, so there are details to show.
    private(set) var hasTab = false

    private var token = ""
    private var exitedCleanly = false
    private var proofRequests = 0
    private var proven = false
    private var registered = false
    private var noticesKnown = false
    private var notices: String?
    private var allowDismissed = false
    private var passwordSent = false
    private var lastBlockedAt: String?

    init(kind: Kind, computer: Computer) {
        self.kind = kind
        self.computer = computer
    }

    /// Nothing more happens in this run.
    var isFinished: Bool {
        switch phase {
        case .connected, .failed, .cancelled: true
        default: false
        }
    }

    var error: SetupError? {
        if case .failed(let e) = phase { return e }
        return nil
    }

    /// The installer's `start` step is over: the helper it started is the one running.
    private var startFinished: Bool {
        exitedCleanly || ["notify", "linger", "done"].contains(token)
    }

    /// The installer is starting the helper it put in place.
    var isStarting: Bool { token == "start" }

    /// Time to ask the helper for the setup proof: it is running, hasn't shown the proof, and
    /// this run has requests left.
    var wantsProof: Bool {
        (phase == .running || phase == .connecting) && startFinished && !proven && proofRequests < SetupProof.requests
    }

    /// The helper that showed the proof holds its secret.
    var helperRegistered: Bool { proven && registered }

    /// The helper showed the proof and hasn't registered yet.
    var awaitsRegistration: Bool {
        (phase == .running || phase == .connecting) && proven && !registered
    }

    mutating func handle(_ event: Event) {
        if event == .tabClosed {
            hasTab = false
            return
        }
        if phase == .connected {
            // Connected is final. Only the "click Allow" card beside it still changes.
            switch event {
            case .notices, .humanDone: break
            default: return
            }
        } else if isFinished {
            return
        }
        switch event {
        case .release(let v):
            version = v
        case .started:
            hasTab = true
            if phase == .preparing { phase = .running }
        case .record(let record):
            apply(record)
        case .exited(let code):
            exited(code)
        case .proof(let answer):
            // An answer counts only for a request this state asked for.
            guard wantsProof else { return }
            proofRequests += 1
            switch answer {
            case .valid:
                proven = true
            case .wrong:
                phase = .failed(.identityChanged)
            case .missing:
                if proofRequests >= SetupProof.requests { phase = .failed(.identityChanged) }
            }
        case .helperRegistered:
            guard proven else { return }
            registered = true
            settle()
        case .codeRefused:
            // The tab is closed, so there are no details to show.
            hasTab = false
            phase = .failed(.release)
        case .connectTimeout:
            if phase == .connecting { phase = .failed(.notStarted) }
        case .notices(let value):
            noticesKnown = true
            notices = value
            refreshAllowCard()
        case .humanDone:
            allowDismissed = true
            if human == .allowNotifications { human = nil }
        case .passwordSent:
            passwordSent = true
            passwordRefused = false
        case .passwordRefused:
            passwordRefused = true
            if case .password = human { human = .passwordOnComputer }
        case .passwordOnComputer:
            if case .password = human { human = .passwordOnComputer }
        case .passwordSkipped:
            if human != .allowNotifications { human = nil }
        case .connectionLost:
            connectionLost = true
        case .caughtUp(let record, let exitCode, let gone):
            connectionLost = false
            if let record { apply(record) }
            if let exitCode {
                exited(exitCode)
            } else if gone, !exitedCleanly {
                phase = .failed(.interrupted)
            }
        case .fail(let error):
            phase = .failed(error)
        case .cancel:
            phase = .cancelled
        case .tabClosed:
            break
        }
    }

    private mutating func apply(_ record: SetupRecord) {
        guard phase == .running else { return }
        token = record.token
        switch record.token {
        case "download": advance(to: .downloading)
        case "verify": advance(to: .verifying)
        case "install", "start", "notify", "linger": advance(to: .installing)
        // Handing over the setup code is part of installing and has no row of its own. Rows only
        // move forward, so it moves the list only once the download is checked.
        case SetupCode.token: if step == .verifying { advance(to: .installing) }
        default: break
        }
        progress = record.state == "working" || record.state == "blocked" ? record.progress : nil
        if record.state == "blocked", record.kind == "auth" {
            // A second request after a password went in means that one wasn't taken.
            let again = passwordSent && record.updatedAt != lastBlockedAt
            lastBlockedAt = record.updatedAt
            if human != .passwordOnComputer || again { human = .password(wrong: again) }
            if again { passwordSent = false }
        } else {
            if human != .allowNotifications { human = nil }
            passwordRefused = false
        }
        refreshAllowCard()
    }

    private mutating func advance(to next: Step) {
        if next > step { step = next }
    }

    private mutating func exited(_ code: Int) {
        guard phase == .running || phase == .preparing else { return }
        if let error = SetupError(exitCode: code) {
            phase = .failed(error)
            return
        }
        exitedCleanly = true
        step = .connected
        progress = nil
        if human != .allowNotifications { human = nil }
        phase = .connecting
        refreshAllowCard()
        settle()
    }

    /// Connected only once the installer finished cleanly and the helper that showed the proof
    /// registered.
    private mutating func settle() {
        guard exitedCleanly, proven, registered, phase == .connecting else { return }
        phase = .connected
    }

    /// The Mac's "click Allow" card: from the moment the installer asked, while the helper says
    /// the question is open or doesn't say, until it is answered or Done is tapped.
    private mutating func refreshAllowCard() {
        guard computer == .mac, !allowDismissed else { return }
        let asked = token == "notify" || token == "done" || exitedCleanly
        let open = noticesKnown && (notices == nil || notices == "undetermined")
        if asked, open, human == nil {
            human = .allowNotifications
        } else if human == .allowNotifications, !open {
            human = nil
        }
    }

    // MARK: What the sheet says

    func title(name: String) -> String {
        kind == .install ? "Installing on \(name)" : "Reinstalling on \(name)"
    }

    enum Mark: Equatable { case done, current, pending }

    func mark(_ row: Step) -> Mark {
        switch phase {
        case .connected: return .done
        case .preparing: return row == .downloading ? .current : .pending
        default: return row < step ? .done : row == step ? .current : .pending
        }
    }

    /// The one secondary line, under the row in progress.
    func detail(_ row: Step, name: String) -> String? {
        let mark = mark(row)
        if row == .downloading, let version, mark != .pending, phase != .preparing { return "\(Brand.beaconName) \(version)" }
        guard mark == .current else { return nil }
        switch row {
        case .downloading: return phase == .preparing ? "Getting ready…" : nil
        case .verifying: return "Checking the download is the real \(Brand.beaconName)…"
        case .installing:
            switch token {
            case "start": return "Starting Beacon…"
            case "linger": return "Waiting for the password…"
            default: return "Installing Beacon on \(name)…"
            }
        case .connected: return "Waiting for Beacon on \(name)…"
        }
    }

    /// `notificationsAllowed` is false while iOS has notifications turned off for the app: the
    /// helper is installed all the same, and the screen says what is left to do.
    static func connectedMessage(name: String, notificationsAllowed: Bool = true) -> String {
        let done = "\(name) will notify this iPhone when an agent finishes or needs you."
        return notificationsAllowed ? done : done + " " + NotificationCopy.turnOnInSettings
    }
}

// MARK: - Layout

/// Where the steps and the installer's output go. From the window and the fold (`Arrangement`),
/// never the device.
enum SetupLayout: Equatable {
    /// Steps on the leading region, output on the trailing one, both always there.
    case sideBySide(steps: CGFloat)
    /// Steps only; the output is a page pushed over them.
    case single

    static func decide(size: CGSize, division: Division?) -> SetupLayout {
        let arrangement = Arrangement.decide(size: size, division: division)
        guard arrangement.inline else { return .single }
        return .sideBySide(steps: arrangement.crease ?? (size.width / 2).rounded())
    }
}

// MARK: - The tabs this app opened

/// The setup tabs this app created and has not seen closed, per server, so it only ever closes
/// its own. Kept in UserDefaults: a tab outlives the app when the app is killed while an
/// install runs, or while a failed one still shows its output. A tab leaves the list when the
/// server has closed it or no longer has it.
struct SetupSessions {
    struct Entry: Codable, Equatable {
        var sessionID: String
        var blockID: String
        /// Set when the tab is a window in one of the user's sessions (the server was at its
        /// session limit). Then only that window is closed, never the session.
        var windowID: String?
        /// When the tab was made. Nothing is decided by it.
        var createdAt: Date

        /// The same tab: a session, or a window in one, by the ids the server gave.
        func isSame(_ other: Entry) -> Bool {
            sessionID == other.sessionID && blockID == other.blockID && windowID == other.windowID
        }
    }

    private static let key = "helperSetup.sessions"

    let defaults: UserDefaults

    private var all: [String: [Entry]] {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return [:] }
            if let lists = try? JSONDecoder().decode([String: [Entry]].self, from: data) { return lists }
            // One tab per server, as it was kept before there was a list.
            return ((try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]).mapValues { [$0] }
        }
        nonmutating set {
            let kept = newValue.filter { !$0.value.isEmpty }
            if kept.isEmpty {
                defaults.removeObject(forKey: Self.key)
            } else {
                defaults.set(try? JSONEncoder().encode(kept), forKey: Self.key)
            }
        }
    }

    /// The server's tabs of this app's making, oldest first.
    func entries(_ server: UUID) -> [Entry] { all[server.uuidString] ?? [] }

    func contains(_ entry: Entry, for server: UUID) -> Bool { entries(server).contains { $0.isSame(entry) } }

    func record(_ entry: Entry, for server: UUID) {
        guard !contains(entry, for: server) else { return }
        all[server.uuidString] = entries(server) + [entry]
    }

    func forget(_ entry: Entry, for server: UUID) {
        all[server.uuidString] = entries(server).filter { !$0.isSame(entry) }
    }

    /// The sessions of this app's own making, which the sidebar leaves out.
    func hidden(_ server: UUID) -> Set<String> {
        Set(entries(server).filter { $0.windowID == nil }.map(\.sessionID))
    }

    /// The server's recorded tabs that nothing in this run of the app uses: all but the ones
    /// whose block is in `inUse`. They are left over from a run that ended, here or in an
    /// earlier life of the app.
    func leftOver(_ server: UUID, inUse: Set<String>) -> [Entry] {
        entries(server).filter { !inUse.contains($0.blockID) }
    }
}

/// What the app asks a server to close of a tab it made, decided from what the server says the
/// tab's session holds now. The ids in the app's list say which tab was the app's when it was
/// made; the server's answer says what is there today, and only what is still the app's closes.
enum SetupTabClose: Equatable {
    /// The session holds the app's block and nothing else: the whole session goes.
    case session
    /// The session holds more, and this window holds only the app's block: the window goes.
    case window(String)
    /// The app's block shares its window with other blocks: only the block goes.
    case block
    /// The session no longer holds the app's block: nothing is closed.
    case nothing

    /// `view` is the server's `session.view` of the entry's session, nil when the server has no
    /// such session or its answer was not a view of it. A session is destroyed only when the app
    /// made it for the tab and it holds one window with one block, the app's. A tab that is a
    /// window in one of the person's sessions never takes the session with it.
    static func decide(_ entry: SetupSessions.Entry, view: SessionView?) -> SetupTabClose {
        guard let view, view.sessionID == entry.sessionID,
              let window = view.windowContaining(block: entry.blockID) else { return .nothing }
        let alone = window.allBlocks.count == 1
        if entry.windowID == nil, alone, view.windows.count == 1 { return .session }
        return alone ? .window(window.id) : .block
    }
}

/// A server, as closing a setup tab needs it: one read of a session and one close. The app's
/// servers in the app (`HelperSetupCenter`); a stand-in in tests.
@MainActor
struct SetupTabServer {
    enum Read {
        /// The server's view of the session.
        case view(SessionView)
        /// The server answered that it has no such session, or with something that is no view.
        case unreadable
        /// No answer: the server can't be reached now.
        case noAnswer
    }

    /// `session.view` for a session on a server.
    var read: @MainActor (UUID, String) async -> Read
    /// Closes what `SetupTabClose` decided on. True when the server did it or no longer has it.
    var close: @MainActor (UUID, SetupTabClose, SetupSessions.Entry) async -> Bool
}

/// Closes the tabs this app made for the installer, and nothing else: a tab is closed by the
/// ids the server gave when it was made, only while it is in the app's list of them
/// (`SetupSessions`), and only after the server said its session still holds the tab's block
/// (`SetupTabClose`). A session that merely has the installer's name is never touched.
///
/// A tab whose script ended well is closed at once, with the sheet open or not. One whose
/// script failed stays, because "Show details" shows its terminal, until the person is done
/// with it. On every connection to a server the app closes each tab in its list for that
/// server that no run in this app session uses: the tab of a failed run when the app was killed
/// before the person was done with it, and a close the server did not take.
@MainActor
final class SetupSessionCloser {
    /// Why a tab might close now.
    enum Reason: Equatable {
        /// Its script ended with this exit code.
        case exited(code: Int)
        /// Done or Close in the sheet.
        case done
        /// Retry: the old tab closes before the new run opens its own.
        case retry
        /// Cancel in the computer's row, or Stop in the sheet.
        case cancel
        /// The sheet went away. `detailsShown`: the installer's output had been on screen.
        case dismissed(detailsShown: Bool)
    }

    /// Whether the tab closes for this reason.
    static func closes(_ reason: Reason) -> Bool {
        switch reason {
        case .exited(let code): code == 0
        case .done, .retry, .cancel: true
        case .dismissed(let detailsShown): detailsShown
        }
    }

    private let sessions: SetupSessions
    private let server: SetupTabServer
    /// Tabs whose close is under way, so each is asked for once.
    private var closing: [SetupSessions.Entry] = []

    init(sessions: SetupSessions, server: SetupTabServer) {
        self.sessions = sessions
        self.server = server
    }

    /// The app made this tab on the server.
    func made(_ entry: SetupSessions.Entry, on server: UUID) {
        sessions.record(entry, for: server)
    }

    /// The server's tabs of this app's making.
    func tabs(on server: UUID) -> [SetupSessions.Entry] { sessions.entries(server) }

    /// Closes the tab when `reason` is one that closes it. True when the tab is off the app's
    /// list: the server closed it, or no longer holds it.
    @discardableResult
    func handle(_ reason: Reason, _ entry: SetupSessions.Entry, on server: UUID) async -> Bool {
        guard Self.closes(reason) else { return false }
        return await shut(entry, on: server)
    }

    /// The server is connected: every tab in the app's list for it is closed, except the ones
    /// in use. `inUse` holds the blocks of the tabs this app session still works with: the
    /// install on this server that is running or whose failed run still offers its details, and
    /// a removal that is running. A tab the server did not close stays in the list for the next
    /// connection.
    func connected(_ server: UUID, inUse: Set<String>) async {
        for entry in sessions.leftOver(server, inUse: inUse) { await shut(entry, on: server) }
    }

    @discardableResult
    private func shut(_ entry: SetupSessions.Entry, on id: UUID) async -> Bool {
        // Only a tab in the list is this app's to close, and each is asked for once at a time.
        guard sessions.contains(entry, for: id), !closing.contains(where: entry.isSame) else { return false }
        closing.append(entry)
        defer { closing.removeAll(where: entry.isSame) }
        let view: SessionView?
        switch await server.read(id, entry.sessionID) {
        case .view(let v): view = v
        case .unreadable: view = nil
        // The tab stays in the list for the next connection.
        case .noAnswer: return false
        }
        let what = SetupTabClose.decide(entry, view: view)
        // The session no longer holds the tab: the entry leaves the list and nothing is closed.
        if what != .nothing {
            guard await server.close(id, what, entry) else { return false }
        }
        sessions.forget(entry, for: id)
        return true
    }
}
