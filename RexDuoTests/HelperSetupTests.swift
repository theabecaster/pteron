import CryptoKit
import Foundation
import GlanceModel
import Testing
import RexKit
@testable import RexDuo

/// The installer's one source, next to the helper it installs.
private let installerInRepository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Relay/setup.sh")

/// Installing the helper from the phone: the installer's arguments, the setup code and the proof
/// the helper gives for it, when a password may be typed, and what the sheet shows for what happens.
@MainActor
struct HelperSetupTests {
    private static let hash = String(repeating: "0f", count: 32)
    private static let key = "Yn851QvA2ZzvkX/TkpqQcsiIOqUd2wi0jAFRbh+0OP0="
    private static let otherKey = "p6Uwh2Qc232RxSymb4uFSkx/A/4Czn+/+QTz16RbLGE="

    private var fields: SetupArgs.Fields {
        SetupArgs.Fields(version: "0.4.0", floor: "0.3.0",
                         macHash: Self.hash, macSize: "8123456", linuxX64Hash: Self.hash, linuxX64Size: "5000000",
                         linuxArm64Hash: Self.hash, linuxArm64Size: "4900000",
                         keys: Self.key + "," + Self.otherKey, linger: "ask")
    }

    private static let paths: [(String, WritableKeyPath<SetupArgs.Fields, String>)] = [
        ("version", \.version), ("floor", \.floor), ("macHash", \.macHash), ("macSize", \.macSize),
        ("linuxX64Hash", \.linuxX64Hash), ("linuxX64Size", \.linuxX64Size), ("linuxArm64Hash", \.linuxArm64Hash),
        ("linuxArm64Size", \.linuxArm64Size), ("keys", \.keys), ("linger", \.linger),
    ]

    /// The contract's patterns, written out a second time so the test doesn't lean on the code
    /// it checks. Index 0 is the mode.
    private static let patterns: [String] = {
        let hex = "^[0-9a-f]{64}$", part = "(0|[1-9][0-9]{0,3})", size = "^[1-9][0-9]{0,7}$", key = "[A-Za-z0-9+/]{43}="
        let version = "^\(part)(\\.\(part)){2}$"
        return ["^2$", version, version, hex, size, hex, size, hex, size, "^\(key)(,\(key)){0,5}$", "^(ask|skip)$", "^-$"]
    }()

    private func matches(_ value: String, _ pattern: String) -> Bool {
        // `$` alone would let a final newline through; the whole string has to match.
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, options: [.anchored], range: range)?.range == range && !value.contains("\n")
    }

    private func release(keys: [String] = [HelperKeys.primary, HelperKeys.recovery]) -> VerifiedRelease {
        VerifiedRelease(version: ReleaseVersion("0.4.0")!, minVersion: ReleaseVersion("0.3.0")!, assets: [
            .mac: ReleaseAsset(sha256: Self.hash, size: 10), .linuxX64: ReleaseAsset(sha256: Self.hash, size: 11),
            .linuxArm64: ReleaseAsset(sha256: Self.hash, size: 12),
        ], expiresAt: .distantFuture, keys: keys)
    }

    // MARK: Arguments

    @Test func thereAreExactlyTwelveArgumentsInTheScriptsOrder() throws {
        let args = try #require(SetupArgs(fields))
        #expect(args.values.count == 12)
        #expect(SetupArgs.count == 12)
        #expect(Self.patterns.count == 12)
        #expect(args.values == ["2", "0.4.0", "0.3.0", Self.hash, "8123456", Self.hash, "5000000", Self.hash, "4900000",
                                Self.key + "," + Self.otherKey, "ask", "-"])
        for (value, pattern) in zip(args.values, Self.patterns) { #expect(matches(value, pattern)) }
        let command = args.command(script: "echo hi\n")
        #expect(command.count == 16)
        #expect(Array(command.prefix(4)) == ["/bin/sh", "-c", "echo hi\n", "rexduo-setup"])
        #expect(Array(command.dropFirst(4)) == args.values)
    }

    @Test func eachFieldHasItsPattern() {
        let hex = [String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "A", count: 64),
                   String(repeating: "g", count: 64), "", String(repeating: "a", count: 63) + " "]
        let versions = ["0.4", "0.4.0.0", "0.4.x", "12345.0.0", ".4.0", "0..0", "0.4.0-beta", "v0.4.0", "", "00.4.0", "0.04.0", "0.4.00",
                        "01.2.3", "1.2.03"]
        let sizes = ["", "123456789", "12a", "-1", "1.0", " 1", "１２", "0", "012", "00"]
        let k = Self.key
        let keys = [String(k.dropLast()), k + "=", String(k.dropLast()) + "A", k.replacingOccurrences(of: "/", with: "_"),
                    k.replacingOccurrences(of: "+", with: "-"), "", ",", k + ",", "," + k, k + ",," + k, k + " " + k, k + ", " + k,
                    k + k, k + ";" + k, k + "\n", Array(repeating: k, count: 7).joined(separator: ",")]
        let cases: [(WritableKeyPath<SetupArgs.Fields, String>, [String])] = [
            (\.macHash, hex), (\.linuxX64Hash, hex), (\.linuxArm64Hash, hex),
            (\.version, versions), (\.floor, versions),
            (\.macSize, sizes), (\.linuxX64Size, sizes), (\.linuxArm64Size, sizes),
            (\.keys, keys),
            (\.linger, ["", "yes", "ASK", "ask ", "skip\n", "-"]),
        ]
        for (path, bad) in cases {
            for value in bad {
                var f = fields
                f[keyPath: path] = value
                #expect(SetupArgs(f) == nil, "\(value)")
            }
        }
        var f = fields
        f.linger = "skip"
        f.version = "9999.9999.9999"
        f.floor = "0.0.0"
        f.macSize = "99999999"
        f.linuxX64Size = "1"
        #expect(SetupArgs(f) != nil)
        // One key, and six, are both a key list.
        for count in 1...6 {
            f.keys = Array(repeating: k, count: count).joined(separator: ",")
            #expect(SetupArgs(f)?.values[9] == f.keys)
        }
    }

    /// Whatever text ends up in a field, the result is no arguments at all or twelve values
    /// that each match their pattern. Nothing is cleaned up to make a value fit.
    @Test func textOutsideAPatternNeverBecomesAnArgument() {
        let pieces = ["'", "\"", "$(id)", "`id`", "\n", "\r", " ", "\t", ";", "&&", "|", ">", "\\", "$HOME", "${IFS}", "-", "--", "=",
                      "é", "１", "٣", "\u{0}", "\u{200B}", "\u{202E}", "🙂", "../", "%0a", "\u{1B}[31m", ",", ",,"]
        let whole = ["", " ", "'; rm -rf ~ #", "$(curl example.com|sh)", "`reboot`", "0.4.0\n0.4.1", "ask skip", "0.4.0;id", "1 2",
                     String(repeating: "a", count: 100_000), String(repeating: "9", count: 4096), "\u{FEFF}0.4.0", "0.4.0\u{0}", "-", "2"]
        var generator = SystemRandomNumberGenerator()
        var built = 0
        for round in 0..<4000 {
            var f = fields
            let (name, path) = Self.paths[round % Self.paths.count]
            let original = f[keyPath: path]
            let value: String
            switch round % 4 {
            case 0:
                value = whole.randomElement(using: &generator)!
            case 1:
                // A valid value with something put into it.
                var chars = Array(original)
                chars.insert(contentsOf: pieces.randomElement(using: &generator)!, at: Int.random(in: 0...chars.count, using: &generator))
                value = String(chars)
            case 2:
                // A valid value with one character replaced.
                var chars = Array(original)
                let at = Int.random(in: 0..<chars.count, using: &generator)
                chars.replaceSubrange(at...at, with: pieces.randomElement(using: &generator)!)
                value = String(chars)
            default:
                value = original + pieces.randomElement(using: &generator)!
            }
            f[keyPath: path] = value
            guard let args = SetupArgs(f) else { continue }
            built += 1
            #expect(args.values.count == 12)
            for (argument, pattern) in zip(args.values, Self.patterns) {
                #expect(matches(argument, pattern), "\(name): \(argument.debugDescription)")
            }
        }
        // A replaced or added character can land on another valid one ("-" never does), so a few
        // rounds do build arguments; all of those were checked above.
        #expect(built < 4000)
    }

    @Test func aReleaseListCannotCarryTextIntoTheArguments() {
        // The fields the arguments are made of are read strictly from the list first.
        for bad in ["0.4.0;id", "0.4.0\n", "$(id)", "0.4.0 ", "`x`"] { #expect(ReleaseVersion(bad) == nil) }
        var bad = release()
        bad.assets[.linuxArm64] = ReleaseAsset(sha256: "$(id)" + String(repeating: "a", count: 59), size: 12)
        #expect(SetupArgs(release: bad, linger: .skip) == nil)
        let good = release()
        #expect(SetupArgs(release: release(keys: ["key"]), linger: .skip) == nil)
        #expect(SetupArgs(release: release(keys: []), linger: .skip) == nil)
        #expect(SetupArgs(release: release(keys: [Self.key, Self.key + "," + Self.otherKey + ";id"]), linger: .skip) == nil)
        let args = SetupArgs(release: good, linger: .ask)
        #expect(args?.values.count == 12)
        #expect(args?.values[1] == "0.4.0")
        #expect(args?.values[2] == HelperRelease.floor.description)
        #expect(args?.values[9] == HelperKeys.primary + "," + HelperKeys.recovery)
        #expect(args?.values[10] == "ask" && args?.values[11] == "-")
        #expect(SetupArgs(release: good, linger: .skip)?.values[10] == "skip")
        // A build missing from the release: no arguments.
        var missing = good
        missing.assets[.mac] = nil
        #expect(SetupArgs(release: missing, linger: .ask) == nil)
        // A size the list form allows but the argument doesn't.
        var empty = good
        empty.assets[.mac] = ReleaseAsset(sha256: Self.hash, size: 0)
        #expect(SetupArgs(release: empty, linger: .ask) == nil)
        // A version the list form allows but the argument doesn't.
        var long = good
        long.version = ReleaseVersion("12345.0.0")!
        #expect(SetupArgs(release: long, linger: .ask) == nil)
    }

    /// Argument 10: the key that signed the release list, then the other keys the phone trusts.
    @Test func theKeyListStartsWithTheSignerAndHoldsSixAtMost() throws {
        let keys = (1...8).map { Data(repeating: UInt8($0), count: 32) }
        let text = keys.map { $0.base64EncodedString() }
        // The signer moves to the front; the others keep their order.
        #expect(HelperRelease.installerKeys(signer: keys[0], trusted: Array(keys[0..<3])) == Array(text[0..<3]))
        #expect(HelperRelease.installerKeys(signer: keys[2], trusted: Array(keys[0..<4])) == [text[2], text[0], text[1], text[3]])
        #expect(HelperRelease.installerKeys(signer: keys[0], trusted: [keys[0]]) == [text[0]])
        // Two built in and four handed over are six. More than six never come out.
        #expect(HelperRelease.installerKeys(signer: keys[5], trusted: Array(keys[0..<6])) == [text[5]] + Array(text[0..<5]))
        let most = HelperRelease.installerKeys(signer: keys[7], trusted: keys)
        #expect(most == [text[7]] + Array(text[0..<5]))
        #expect(HelperRelease.installerKeyLimit == 6)
        #expect(ReleaseTrust(builtin: HelperKeys.builtin, handed: Array(keys[0..<6])).keys.count == 6)

        let args = try #require(SetupArgs(release: release(keys: HelperRelease.installerKeys(signer: keys[3], trusted: Array(keys[0..<6]))),
                                          linger: .skip))
        #expect(args.values[9] == ([text[3]] + [text[0], text[1], text[2], text[4], text[5]]).joined(separator: ","))
        #expect(matches(args.values[9], Self.patterns[9]))
        // Seven keys are not an argument.
        #expect(SetupArgs(release: release(keys: Array(text[0..<7])), linger: .skip) == nil)
    }

    // MARK: The setup code

    @Test func aSetupCodeIs32RandomBytesInHex() {
        let a = SetupCode.make(), b = SetupCode.make()
        #expect(a != b)
        #expect(HelperRelease.isHex64(a) && HelperRelease.isHex64(b))
        #expect(SetupProof.bytes(hex: a)?.count == 32)
        #expect(SetupCode.input(a) == a + "\r")
        #expect(SetupCode.input(a).utf8.count == 65)
    }

    @Test func theCodeIsTypedOnceWhenTheInstallerAsksForIt() {
        let asking = SetupRecord(state: "working", token: "code")
        #expect(SetupCode.isRequest(asking, answered: false))
        #expect(!SetupCode.isRequest(asking, answered: true))
        for token in ["download", "verify", "install", "start", "notify", "linger", "done", "fail:ARGS", "", "Code", "code "] {
            #expect(!SetupCode.isRequest(SetupRecord(state: "working", token: token), answered: false), "\(token)")
        }
        for state in ["blocked", "done", "error", "idle"] {
            #expect(!SetupCode.isRequest(SetupRecord(state: state, token: "code"), answered: false), "\(state)")
        }
    }

    @Test func theCodeIsTypedOnlyWithEchoOffAndTheInstallersShellInFront() {
        func program(_ pid: Int, _ path: String?) -> JSONObject {
            var p: JSONObject = ["pid": pid, "user_id": 501, "name": "sh"]
            if let path { p["path"] = path }
            return p
        }
        func process(front: JSONObject?, ancestors: [JSONObject]? = nil, child: JSONObject? = program(100, "/bin/bash")) -> JSONObject {
            var o: JSONObject = ["last_exit": NSNull()]
            if let child { o["child"] = child }
            if let front { o["foreground"] = front }
            if let ancestors { o["ancestors"] = ancestors }
            return o
        }
        let quiet: JSONObject = ["echo": false, "canonical": true, "signals": true]
        let loud: JSONObject = ["echo": true, "canonical": true, "signals": true]
        // The block's own program in front, whatever shell the system's /bin/sh is.
        let own = process(front: program(100, "/bin/bash"))
        #expect(SetupCode.allows(inputMode: quiet, process: own))
        #expect(SetupCode.allows(inputMode: quiet, process: process(front: program(7, "/usr/bin/dash"), child: program(7, "/usr/bin/dash"))))
        #expect(SetupCode.allows(inputMode: quiet, process: process(front: program(100, nil), child: program(100, nil))))
        // A part of the script in a shell of its own, started by the block's program.
        let inner = process(front: program(120, "/bin/bash"), ancestors: [program(100, "/bin/bash")])
        #expect(SetupCode.allows(inputMode: quiet, process: inner))
        let deeper = process(front: program(130, "/bin/bash"), ancestors: [program(120, "/bin/bash"), program(100, "/bin/bash")])
        #expect(SetupCode.allows(inputMode: quiet, process: deeper))

        // Echo on: what is typed would show on the screen.
        #expect(!SetupCode.allows(inputMode: loud, process: own))
        #expect(!SetupCode.allows(inputMode: loud, process: inner))
        #expect(!SetupCode.allows(inputMode: nil, process: own))
        #expect(!SetupCode.allows(inputMode: [:], process: own))

        // Another program in front.
        for path in ["/usr/bin/curl", "/usr/bin/sudo", "/usr/bin/ssh", "/bin/cat", "/usr/bin/pkttyagent", "/bin/zsh", "/tmp/bash", ""] {
            let other = process(front: program(120, path), ancestors: [program(100, "/bin/bash")])
            #expect(!SetupCode.allows(inputMode: quiet, process: other), "\(path)")
        }
        // The same shell, but not started by the block's program alone.
        #expect(!SetupCode.allows(inputMode: quiet, process: process(front: program(120, "/bin/bash"))))
        #expect(!SetupCode.allows(inputMode: quiet, process: process(front: program(120, "/bin/bash"), ancestors: [])))
        #expect(!SetupCode.allows(inputMode: quiet, process: process(front: program(120, "/bin/bash"), ancestors: [program(99, "/bin/bash")])))
        #expect(!SetupCode.allows(inputMode: quiet, process: process(front: program(130, "/bin/bash"),
                                                                      ancestors: [program(120, "/usr/bin/env"), program(100, "/bin/bash")])))
        #expect(!SetupCode.allows(inputMode: quiet, process: process(front: program(120, nil), ancestors: [program(100, nil)],
                                                                      child: program(100, nil))))
        // A reply that doesn't say.
        #expect(!SetupCode.allows(inputMode: quiet, process: process(front: nil)))
        #expect(!SetupCode.allows(inputMode: quiet, process: process(front: program(100, "/bin/bash"), child: nil)))
        #expect(!SetupCode.allows(inputMode: quiet, process: process(front: ["name": "sh"])))
        #expect(!SetupCode.allows(inputMode: quiet, process: nil))
    }

    /// The code reaches the computer through the terminal only: nothing a block is created with
    /// holds it, whole or in part.
    @Test func theSetupCodeIsInNothingTheBlockIsCreatedWith() throws {
        let code = SetupCode.make()
        let args = try #require(SetupArgs(release: release(), linger: .ask))
        let script = SetupScript.bundled() ?? "script"
        let command = args.command(script: script)
        let payloads = [SetupBlock.session(command: command, theme: ThemeStore.fallback),
                        SetupBlock.window(in: "session:1", command: command, theme: ThemeStore.fallback)]
        let characters = Array(code)
        let pieces = (0...(characters.count - 12)).map { String(characters[$0..<($0 + 12)]) }
        #expect(pieces.count == 53)
        for payload in payloads {
            let text = try #require(String(data: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8))
            #expect(text.contains("rexduo-setup"))
            #expect(!text.contains(code))
            for piece in pieces { #expect(!text.contains(piece)) }
            let options = try #require((payload.arr("initial_windows").first ?? payload).obj("layout")?.obj("block")?.obj("options"))
            #expect(Set(options.keys) == ["shell", "command", "size", "theme", "exit"])
            #expect(options["initial_input"] == nil && options["env"] == nil)
            #expect((options["command"] as? [String])?.count == 16)
        }
        // The arguments take no code: none of their fields is one.
        #expect(!args.values.contains { HelperRelease.isHex64($0) && $0 != Self.hash })
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: installerInRepository.path), "Relay/setup.sh is not in the source tree yet"))
    func theBundledInstallerIsTheRepositoryFileByteForByte() throws {
        let source = try Data(contentsOf: installerInRepository)
        let url = try #require(Bundle.main.url(forResource: "setup", withExtension: "sh"))
        #expect(try Data(contentsOf: url) == source)
        // The app runs no copy over `maxBytes`. The installer is held well under it, on the
        // same line as Beacon's own test of the file, so it is trimmed long before that.
        #expect(source.count < 62_000, "setup.sh is \(source.count) bytes; trim it under 62,000")
        #expect(SetupScript.maxBytes == 64 << 10)
        #expect(SetupScript.bundled() == String(data: source, encoding: .utf8))
    }

    // MARK: The block

    @Test func theInstallerRunsAsACommandInATabOfItsOwn() throws {
        let args = try #require(SetupArgs(fields))
        let command = args.command(script: "script")
        let theme = ThemeStore.fallback
        let payload = SetupBlock.session(command: command, theme: theme)
        #expect(payload.str("label") == "\(Brand.beaconName) setup")
        let window = try #require(payload.arr("initial_windows").first)
        #expect(window.str("window_label") == "\(Brand.beaconName) setup")
        let block = try #require(window.obj("layout")?.obj("block"))
        #expect(block.str("flavor") == "com.superlogical.terminal.shell")
        #expect(block.str("label") == "rexduo-setup")
        let options = try #require(block.obj("options"))
        #expect(options.str("shell") == "none")
        #expect(options["command"] as? [String] == command)
        #expect(options.obj("exit")?.bool("on_completion") == false)
        #expect(options.obj("size")?.int("columns") == 80 && options.obj("size")?.int("rows") == 24)
        #expect(options["initial_input"] == nil)
        #expect(options.obj("theme")?.str("background") == theme.background)

        let inSession = SetupBlock.window(in: "session:1", command: command, theme: theme)
        #expect(inSession.str("session_id") == "session:1")
        #expect(inSession.bool("focus") == false)
        #expect(inSession.obj("layout")?.obj("block")?.obj("options")?["command"] as? [String] == command)
    }

    @Test func onlyAServerThatTakesACommandRunsTheInstaller() {
        func creators(_ properties: [String: Any]) -> JSONObject {
            ["creators": [["name": "com.superlogical.terminal", "flavors": [
                ["flavor": "com.superlogical.terminal.shell", "options_schema": ["type": "object", "properties": properties]],
            ]]]]
        }
        let full = creators(["command": ["type": "array"], "shell": ["type": "string"], "cwd": ["type": "string"]])
        #expect(SetupBlock.supported(version: ["api_revision": 14], creators: full))
        #expect(SetupBlock.supported(version: ["api_revision": 15], creators: full))
        #expect(SetupBlock.supported(version: ["api_revision": 13], creators: full))
        #expect(!SetupBlock.supported(version: ["api_revision": 12], creators: full))
        #expect(!SetupBlock.supported(version: [:], creators: full))
        #expect(!SetupBlock.supported(version: ["api_revision": 14], creators: creators(["cwd": ["type": "string"]])))
        #expect(!SetupBlock.supported(version: ["api_revision": 14], creators: creators(["command": ["type": "array"]])))
        #expect(!SetupBlock.supported(version: ["api_revision": 14], creators: [:]))
    }

    // MARK: Proof

    @Test func theSetupProofMatchesTheHelpersVector() {
        let code = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
        let challenge = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let proof = "4Cn9RKo/LEB9ftm6bCl+5ddooucq97kzOtl8tIHNkvo="
        #expect(String(decoding: SetupProof.message(challenge: challenge, helper: "client:helper", requester: "client:phone"), as: UTF8.self)
            == "rexduo-setup-v1\n\(challenge)\nclient:helper\nclient:phone")
        func verify(proof p: String? = proof, code n: String = code, challenge c: String = challenge, helper: String = "client:helper",
                    requester: String = "client:phone") -> Bool {
            SetupProof.verify(proof: p, code: n, challenge: c, helper: helper, requester: requester)
        }
        #expect(verify())
        #expect(!verify(proof: nil))
        #expect(!verify(proof: ""))
        #expect(!verify(proof: "4Cn9RKo/LEB9ftm6bCl+5ddooucq97kzOtl8tIHNkvs="))
        #expect(!verify(code: String(repeating: "00", count: 32)))
        #expect(!verify(code: "0011"))
        #expect(!verify(code: code.uppercased()))
        #expect(!verify(challenge: challenge + "A"))
        #expect(!verify(helper: "client:other"))
        #expect(!verify(requester: "client:other"))

        func answer(_ p: String?, code n: String = code) -> SetupProof.Answer {
            SetupProof.answer(proof: p, code: n, challenge: challenge, helper: "client:helper", requester: "client:phone")
        }
        #expect(answer(proof) == .valid)
        #expect(answer(nil) == .missing)
        #expect(answer("") == .wrong)
        #expect(answer("4Cn9RKo/LEB9ftm6bCl+5ddooucq97kzOtl8tIHNkvs=") == .wrong)
        #expect(answer(proof, code: String(repeating: "ab", count: 32)) == .wrong)
        #expect(SetupProof.requests == 3)
    }

    // MARK: The seal

    private static let sealCode = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    private static let sealSecret = "S3cr3tS3cr3tS3cr3tS3cr3tS3cr3tS3cr3tS3cr3t0"
    private static let seal = "uFBNieeZhse8TXl8fRQiixoD7UCeYMg3k+hrGw9CICM="

    @Test func theSetupSealMatchesTheHelpersVector() {
        #expect(String(decoding: SetupSeal.message(secret: Self.sealSecret, device: "a1b2c3d4"), as: UTF8.self)
            == "rexduo-setup-register-v1\n\(Self.sealSecret)\na1b2c3d4")
        #expect(SetupSeal.make(code: Self.sealCode, secret: Self.sealSecret, device: "a1b2c3d4") == Self.seal)
    }

    @Test func theSetupSealIsForOneCodeSecretAndDevice() throws {
        func make(code: String = Self.sealCode, secret: String = Self.sealSecret, device: String = "a1b2c3d4") -> String? {
            SetupSeal.make(code: code, secret: secret, device: device)
        }
        let others = [make(secret: Self.sealSecret + "1"), make(secret: ""), make(device: "a1b2c3d5"), make(device: ""),
                      make(code: String(repeating: "ab", count: 32)), make(code: String(repeating: "00", count: 32))]
        for other in others {
            let seal = try #require(other)
            #expect(seal != Self.seal)
            #expect(Data(base64Encoded: seal)?.count == 32)
        }
        #expect(Set(others.compactMap { $0 }).count == others.count)
    }

    @Test func aCodeThatIsNot64HexGivesNoSeal() {
        let code = Self.sealCode
        for bad in ["", "0011", String(code.dropLast()), String(code.dropLast(2)), code + "00", code.uppercased(),
                    String(code.dropLast()) + "g", String(code.dropLast()) + " ", code + "\n"] {
            #expect(SetupSeal.make(code: bad, secret: Self.sealSecret, device: "a1b2c3d4") == nil, "\(bad.debugDescription)")
        }
    }

    @Test func onlyASetupRunsProvenHelperGetsTheSealInRegisterPush() {
        func arguments(_ setup: HelperAdmission.Setup, code: String?) -> JSONObject {
            PushRegistration.arguments(gateway: "https://gateway.example", secret: Self.sealSecret, environment: "sandbox",
                                       deviceName: "iPhone", deviceID: "a1b2c3d4", setup: setup, code: code)
        }
        let usual: Set<String> = ["gateway", "push_secret", "environment", "device_name", "device_id"]
        let sealed = arguments(.proven(sameKey: true), code: Self.sealCode)
        #expect(Set(sealed.keys) == usual.union(["setup_seal"]))
        #expect(sealed.str("setup_seal") == Self.seal)
        #expect(sealed.str("gateway") == "https://gateway.example" && sealed.str("push_secret") == Self.sealSecret)
        #expect(sealed.str("environment") == "sandbox" && sealed.str("device_name") == "iPhone" && sealed.str("device_id") == "a1b2c3d4")

        // Outside a setup run, before the proof, for another helper than the proven one, or
        // without the run's code: the usual five.
        let plain = [arguments(.none, code: nil), arguments(.none, code: Self.sealCode), arguments(.unproven, code: Self.sealCode),
                     arguments(.proven(sameKey: false), code: Self.sealCode), arguments(.proven(sameKey: true), code: nil),
                     arguments(.proven(sameKey: true), code: "0011"),
                     PushRegistration.arguments(gateway: "https://gateway.example", secret: Self.sealSecret, environment: "sandbox",
                                                deviceName: "iPhone", deviceID: "a1b2c3d4")]
        for args in plain {
            #expect(Set(args.keys) == usual)
            #expect(args["setup_seal"] == nil)
        }
    }

    /// Which helper a registration gives a secret to. Rows: the pinned key against the offered one.
    @Test func aHelperIsPinnedOnFirstUseOnlyOutsideAnInstall() {
        typealias A = HelperAdmission
        func decide(_ pin: HelperIdentity.Pin, _ setup: A.Setup, held: Bool = false) -> A {
            A.decide(pin: pin, setup: setup, heldBack: held)
        }
        // No install: the usual rules.
        #expect(decide(.first, .none) == .register(.first))
        #expect(decide(.same, .none) == .register(.keep))
        #expect(decide(.changed, .none) == .changed)
        // An install sent its code and no helper showed the proof: nobody is pinned or registered.
        for pin in [HelperIdentity.Pin.first, .same, .changed] {
            #expect(decide(pin, .unproven) == .wait)
            #expect(decide(pin, .unproven, held: true) == .wait)
            // Nor is another helper than the one that showed it.
            #expect(decide(pin, .proven(sameKey: false)) == .wait)
        }
        // The helper that showed the proof becomes the pin, also in place of another.
        #expect(decide(.first, .proven(sameKey: true)) == .register(.first))
        #expect(decide(.same, .proven(sameKey: true)) == .register(.keep))
        #expect(decide(.changed, .proven(sameKey: true)) == .register(.replace))
        #expect(decide(.first, .proven(sameKey: true), held: true) == .register(.first))
        // After an install that ended without a proof, the helper there waits for "Trust".
        #expect(decide(.first, .none, held: true) == .changed)
        #expect(decide(.changed, .none, held: true) == .changed)
        #expect(decide(.same, .none, held: true) == .register(.keep))
    }

    // MARK: The password

    @Test func aPasswordIsTypedOnlyWithEchoOffAndThePromptInFront() {
        func process(_ path: String?) -> JSONObject {
            var fg: JSONObject = ["pid": 10, "name": "x"]
            if let path { fg["path"] = path }
            return ["foreground": fg, "last_exit": NSNull()]
        }
        let quiet: JSONObject = ["echo": false, "canonical": true, "signals": true]
        let loud: JSONObject = ["echo": true, "canonical": true, "signals": true]
        for path in ["/usr/bin/pkttyagent", "/usr/bin/loginctl", "/bin/loginctl"] {
            #expect(PasswordGuard.allows(inputMode: quiet, process: process(path)))
            // Echo on: what is typed would show on the screen.
            #expect(!PasswordGuard.allows(inputMode: loud, process: process(path)))
        }
        for path in ["/bin/sh", "/usr/bin/sudo", "/usr/local/bin/loginctl", "/usr/bin/pkttyagent2", "loginctl", "/bin/bash", "/usr/bin/ssh", ""] {
            #expect(!PasswordGuard.allows(inputMode: quiet, process: process(path)), "\(path)")
        }
        #expect(!PasswordGuard.allows(inputMode: quiet, process: process(nil)))
        #expect(!PasswordGuard.allows(inputMode: quiet, process: ["last_exit": NSNull()]))
        #expect(!PasswordGuard.allows(inputMode: quiet, process: nil))
        #expect(!PasswordGuard.allows(inputMode: nil, process: process("/usr/bin/loginctl")))
        #expect(!PasswordGuard.allows(inputMode: [:], process: process("/usr/bin/loginctl")))
        #expect(PasswordGuard.programs.count == 3)
    }

    // MARK: State

    private func state(_ kind: SetupState.Kind = .install, _ computer: SetupState.Computer = .mac, started: Bool = true) -> SetupState {
        var s = SetupState(kind: kind, computer: computer)
        if started {
            s.handle(.release(version: "0.4.0"))
            s.handle(.started)
        }
        return s
    }

    private func record(_ token: String, _ state: String = "working", progress: Int? = nil, kind: String? = nil, at: String = "t1") -> SetupState.Event {
        .record(SetupRecord(state: state, token: token, progress: progress, kind: kind, updatedAt: at))
    }

    @Test func theStepsFollowTheInstallersTokens() {
        var s = SetupState(kind: .install, computer: .mac)
        #expect(s.phase == .preparing)
        #expect(s.mark(.downloading) == .current && s.mark(.verifying) == .pending)
        #expect(!s.hasTab)
        s.handle(.release(version: "0.4.0"))
        s.handle(.started)
        #expect(s.phase == .running && s.hasTab)
        s.handle(record("download", progress: 30))
        #expect(s.step == .downloading && s.progress == 30)
        #expect(s.detail(.downloading, name: "studio") == "\(Brand.beaconName) 0.4.0")
        s.handle(record("verify"))
        #expect(s.step == .verifying && s.progress == nil)
        #expect(s.mark(.downloading) == .done && s.mark(.verifying) == .current && s.mark(.installing) == .pending)
        #expect(s.detail(.verifying, name: "studio") == "Checking the download is the real \(Brand.beaconName)…")
        // A token the app doesn't know changes nothing, and steps never go back.
        s.handle(record("defragment"))
        s.handle(record("download"))
        #expect(s.step == .verifying)
        for token in ["install", "start", "notify"] {
            s.handle(record(token))
            #expect(s.step == .installing)
        }
        // Handing over the setup code is part of Installing, and has no row.
        #expect(SetupState.Step.allCases.count == 4)
        var code = state()
        code.handle(record("download"))
        code.handle(record("verify"))
        code.handle(record("code"))
        #expect(code.step == .installing && code.human == nil)
        #expect(code.detail(.installing, name: "studio") == "Installing Beacon on studio…")
        // Asked for before the download, it leaves the rows where they are.
        var first = state()
        first.handle(record("code"))
        #expect(first.step == .downloading && first.mark(.verifying) == .pending)
        first.handle(record("download", progress: 10))
        #expect(first.step == .downloading && first.progress == 10)
        #expect(s.title(name: "studio") == "Installing on studio")
        #expect(state(.repair).title(name: "studio") == "Reinstalling on studio")
        #expect(state(.reinstall).title(name: "studio") == "Reinstalling on studio")
    }

    /// What the terminal says is never enough: Connected needs the helper's proof and its
    /// registration.
    @Test func aDoneRecordWithoutAProofNeverReachesConnected() {
        var s = state()
        for token in ["download", "verify", "code", "install", "start", "notify", "done"] { s.handle(record(token)) }
        s.handle(record("done", "done"))
        #expect(s.phase == .running)
        s.handle(.exited(code: 0))
        #expect(s.phase == .connecting)
        #expect(s.mark(.connected) == .current)
        #expect(s.wantsProof)
        // More reports, an answered prompt, a reconnect, a registration nobody proved: still not
        // connected.
        s.handle(record("done", "done", at: "t2"))
        s.handle(.notices("allowed"))
        s.handle(.humanDone)
        s.handle(.caughtUp(record: SetupRecord(state: "done", token: "done"), exitCode: 0, gone: false))
        s.handle(.helperRegistered)
        #expect(s.phase == .connecting && !s.helperRegistered)
        s.handle(.connectTimeout)
        #expect(s.phase == .failed(.notStarted))
        // And once failed, a late proof and registration don't turn it around.
        s.handle(.proof(.valid))
        s.handle(.helperRegistered)
        #expect(s.phase == .failed(.notStarted))

        // A helper that answers without a proof, three times: the run ends, and nothing was
        // reported as registered.
        var silent = state()
        silent.handle(record("done", "done"))
        silent.handle(.exited(code: 0))
        silent.handle(.proof(.missing))
        silent.handle(.helperRegistered)
        silent.handle(.proof(.missing))
        #expect(silent.phase == .connecting && silent.wantsProof)
        silent.handle(.proof(.missing))
        #expect(silent.phase == .failed(.identityChanged))
        #expect(!silent.helperRegistered && !silent.wantsProof)
    }

    @Test func connectedNeedsACleanExitAProofAndARegisteredHelper() {
        // The proof and the registration while the installer still waits for the password.
        var early = state(.install, .linux)
        early.handle(record("start"))
        #expect(!early.wantsProof)
        early.handle(record("linger", "blocked", kind: "auth"))
        #expect(early.wantsProof)
        early.handle(.proof(.valid))
        #expect(!early.wantsProof && early.awaitsRegistration)
        early.handle(.helperRegistered)
        #expect(early.phase == .running && early.helperRegistered && !early.awaitsRegistration)
        early.handle(.exited(code: 0))
        #expect(early.phase == .connected)
        #expect(SetupState.Step.allCases.allSatisfy { early.mark($0) == .done })

        // The exit first.
        var late = state()
        late.handle(.exited(code: 0))
        late.handle(.proof(.valid))
        #expect(late.phase == .connecting)
        late.handle(.helperRegistered)
        #expect(late.phase == .connected)

        // Every kind of run needs the proof.
        for kind in [SetupState.Kind.install, .repair, .reinstall] {
            var s = state(kind)
            s.handle(.exited(code: 0))
            s.handle(.helperRegistered)
            #expect(s.phase == .connecting, "\(kind)")
        }

        var failed = state()
        failed.handle(record("notify"))
        failed.handle(.proof(.valid))
        failed.handle(.helperRegistered)
        failed.handle(.exited(code: 14))
        #expect(failed.phase == .failed(.verify))
        #expect(SetupState.connectedMessage(name: "studio") == "studio will notify this iPhone when an agent finishes or needs you.")
    }

    /// The proof is asked for once the installer's `start` step is over, and not before.
    @Test func theProofIsAskedForAfterTheStartStep() {
        var s = SetupState(kind: .install, computer: .mac)
        #expect(!s.wantsProof)
        s.handle(.release(version: "0.4.0"))
        s.handle(.started)
        for token in ["download", "verify", "code", "install", "start"] {
            s.handle(record(token))
            #expect(!s.wantsProof, "\(token)")
            // An answer nobody asked for counts for nothing.
            s.handle(.proof(.valid))
            s.handle(.proof(.wrong))
            #expect(s.phase == .running && !s.awaitsRegistration)
        }
        for token in ["notify", "linger", "done"] {
            var after = s
            after.handle(record(token))
            #expect(after.wantsProof, "\(token)")
        }
        s.handle(.exited(code: 0))
        #expect(s.wantsProof)
        // Not after the run is over.
        var stopped = s
        stopped.handle(.cancel)
        #expect(!stopped.wantsProof)
        var broken = state()
        broken.handle(record("done", "done"))
        broken.handle(.exited(code: 17))
        #expect(!broken.wantsProof)
    }

    @Test func aWrongProofEndsTheRunAsAChangedHelper() {
        var s = state()
        s.handle(.exited(code: 0))
        s.handle(.proof(.wrong))
        #expect(s.phase == .failed(.identityChanged))
        #expect(!s.wantsProof && !s.awaitsRegistration && !s.helperRegistered)
        // Nothing after it counts.
        s.handle(.proof(.valid))
        s.handle(.helperRegistered)
        #expect(s.phase == .failed(.identityChanged))
        #expect(SetupError.identityChanged.message(name: "studio")
            == "\(Brand.beaconName) on studio has changed. Only trust Beacon if you reinstalled it on studio.")
        #expect(SetupError.identityChanged.actions(hasTab: true) == [.showDetails, .close])

        // Also after an answer without one, and while the installer still runs.
        var second = state()
        second.handle(record("notify"))
        second.handle(.proof(.missing))
        second.handle(.proof(.wrong))
        #expect(second.phase == .failed(.identityChanged))
    }

    @Test func aProofOnTheSecondOrThirdRequestSucceeds() {
        for missing in 0...2 {
            var s = state()
            s.handle(.exited(code: 0))
            for _ in 0..<missing {
                s.handle(.proof(.missing))
                #expect(s.phase == .connecting && s.wantsProof)
            }
            s.handle(.proof(.valid))
            #expect(!s.wantsProof && s.awaitsRegistration)
            s.handle(.helperRegistered)
            #expect(s.phase == .connected, "\(missing)")
        }
    }

    @Test func aFourthRequestForTheProofIsNeverMade() {
        var s = state()
        s.handle(.exited(code: 0))
        var requests = 0
        // The runner asks only while the state wants a proof.
        while s.wantsProof, requests < 10 {
            requests += 1
            s.handle(.proof(.missing))
        }
        #expect(requests == 3)
        #expect(s.phase == .failed(.identityChanged))
        // A fourth answer changes nothing.
        s.handle(.proof(.valid))
        s.handle(.helperRegistered)
        #expect(s.phase == .failed(.identityChanged) && !s.wantsProof)

        // After a valid proof nothing more is asked either.
        var proven = state()
        proven.handle(.exited(code: 0))
        proven.handle(.proof(.missing))
        proven.handle(.proof(.valid))
        #expect(!proven.wantsProof)
        proven.handle(.proof(.wrong))
        proven.handle(.helperRegistered)
        #expect(proven.phase == .connected)
    }

    @Test func aCodeThatCannotBeTypedEndsTheRunWithNothingToShow() {
        var s = state()
        s.handle(record("code"))
        #expect(s.hasTab)
        s.handle(.codeRefused)
        #expect(s.phase == .failed(.release) && !s.hasTab)
        #expect(s.error?.message(name: "studio") == "\(Brand.appName) can't get Beacon right now. Try again later.")
        #expect(s.error?.actions(hasTab: s.hasTab) == [.tryAgain, .close])
        s.handle(.exited(code: 0))
        s.handle(.proof(.valid))
        #expect(s.phase == .failed(.release))
    }

    @Test func exitCodesMapToTheirSentences() {
        let table: [(Int, SetupError, String)] = [
            (10, .release, "\(Brand.appName) can't get Beacon right now. Try again later."),
            (11, .unsupportedComputer, "\(Brand.beaconName) isn't available for this computer yet."),
            (12, .noDownloader, "studio needs curl to download \(Brand.beaconName). Install curl on studio, then try again."),
            (13, .network, "studio couldn't download \(Brand.beaconName). Check the internet connection on studio, then try again."),
            (14, .verify, "The download didn't pass its security check, so nothing was installed. Try again later."),
            (15, .write, "studio couldn't save \(Brand.beaconName). Free up space on studio, then try again."),
            (16, .busy, "Another install is already running on studio."),
            (17, .notStarted, "\(Brand.beaconName) is installed but didn't start."),
            (18, .noGUI, "Log in on studio, then try again."),
            (19, .noSystemd, "studio doesn't start background services the usual way. Show Details says how to start \(Brand.beaconName)."),
            (20, .appManagement, "studio didn't let Rex replace the old \(Brand.beaconName). On studio, drag \(Brand.beaconName) from Applications to the Trash, then try again."),
            (21, .oldMacOS, "\(Brand.beaconName) needs macOS 14 or later."),
            (-1, .interrupted, "The install stopped before it finished."),
            (1, .interrupted, "The install stopped before it finished."),
            (137, .interrupted, "The install stopped before it finished."),
        ]
        for (code, error, sentence) in table {
            #expect(SetupError(exitCode: code) == error, "\(code)")
            #expect(error.message(name: "studio") == sentence)
            var s = state()
            s.handle(record("verify"))
            s.handle(.exited(code: code))
            #expect(s.phase == .failed(error))
            #expect(s.error == error)
        }
        #expect(SetupError(exitCode: 0) == nil)
        #expect(SetupError.connectionLost(name: "studio")
            == "Lost the connection to studio. The install keeps going on studio, and \(Brand.appName) catches up when it reconnects.")
        #expect(SetupError.notificationsOff.message(name: "studio") == "Notifications are off for \(Brand.appName).")
    }

    @Test func eachErrorOffersWhatHelps() {
        #expect(SetupError.network.actions(hasTab: true) == [.tryAgain, .showDetails, .close])
        #expect(SetupError.interrupted.actions(hasTab: true) == [.tryAgain, .showDetails, .close])
        #expect(SetupError.notStarted.actions(hasTab: true) == [.repair, .showDetails, .close])
        #expect(SetupError.busy.actions(hasTab: true) == [.showDetails, .close])
        #expect(SetupError.noSystemd.actions(hasTab: true) == [.showDetails, .close])
        // Nothing ran on the computer, so there is nothing to show.
        #expect(SetupError.release.actions(hasTab: false) == [.tryAgain, .close])
        #expect(SetupError.notificationsOff.actions(hasTab: false) == [.openSettings, .close])
        #expect(SetupError.manual.actions(hasTab: false) == [.close])
    }

    @Test func aDroppedConnectionIsPickedUpFromWhatTheServerSays() {
        var s = state()
        s.handle(record("download"))
        s.handle(.connectionLost)
        #expect(s.connectionLost && s.phase == .running)
        // The installer moved on meanwhile.
        s.handle(.caughtUp(record: SetupRecord(state: "working", token: "install"), exitCode: nil, gone: false))
        #expect(!s.connectionLost && s.step == .installing && s.phase == .running)

        // It finished meanwhile.
        s.handle(.connectionLost)
        s.handle(.caughtUp(record: SetupRecord(state: "done", token: "done"), exitCode: 0, gone: false))
        #expect(s.phase == .connecting && !s.connectionLost)

        // It failed meanwhile.
        var failed = state()
        failed.handle(.connectionLost)
        failed.handle(.caughtUp(record: SetupRecord(state: "error", token: "fail:E_NET"), exitCode: 13, gone: false))
        #expect(failed.phase == .failed(.network))

        // Its tab is gone and nothing says how it ended.
        var gone = state()
        gone.handle(.connectionLost)
        gone.handle(.caughtUp(record: nil, exitCode: nil, gone: true))
        #expect(gone.phase == .failed(.interrupted))
    }

    @Test func cancelEndsTheRunForGood() {
        var s = state()
        s.handle(record("download"))
        s.handle(.cancel)
        #expect(s.phase == .cancelled && s.isFinished)
        s.handle(record("verify"))
        s.handle(.exited(code: 0))
        s.handle(.proof(.valid))
        s.handle(.helperRegistered)
        #expect(s.phase == .cancelled)
        var early = SetupState(kind: .install, computer: .linux)
        early.handle(.cancel)
        early.handle(.started)
        #expect(early.phase == .cancelled && !early.hasTab)
    }

    @Test func thePasswordCardFollowsTheInstallersRequest() {
        var s = state(.install, .linux)
        s.handle(record("install"))
        #expect(s.human == nil)
        s.handle(record("linger", "blocked", kind: "auth"))
        #expect(s.human == .password(wrong: false))
        #expect(s.detail(.installing, name: "studio") == "Waiting for the password…")
        // The same report again changes nothing.
        s.handle(record("linger", "blocked", kind: "auth"))
        #expect(s.human == .password(wrong: false))
        // A password went in and the installer asks again: that one wasn't taken.
        s.handle(.passwordSent)
        s.handle(record("linger", "blocked", kind: "auth", at: "t2"))
        #expect(s.human == .password(wrong: true))
        // The next one is taken, and the installer moves on.
        s.handle(.passwordSent)
        s.handle(record("done", "done"))
        #expect(s.human == nil)

        var refused = state(.install, .linux)
        refused.handle(record("linger", "blocked", kind: "auth"))
        refused.handle(.passwordRefused)
        #expect(refused.human == .passwordOnComputer && refused.passwordRefused)
        refused.handle(.exited(code: 0))
        #expect(refused.human == nil && refused.phase == .connecting)

        var there = state(.install, .linux)
        there.handle(record("linger", "blocked", kind: "auth"))
        there.handle(.passwordOnComputer)
        #expect(there.human == .passwordOnComputer)
        there.handle(.passwordSkipped)
        #expect(there.human == nil)
        // A request for something else is not a password request.
        var other = state(.install, .linux)
        other.handle(record("linger", "blocked", kind: "question"))
        #expect(other.human == nil)
    }

    @Test func theAllowCardShowsOnAMacWhileTheQuestionIsOpen() {
        var s = state()
        s.handle(.notices("undetermined"))
        #expect(s.human == nil)
        s.handle(record("notify"))
        #expect(s.human == .allowNotifications)
        // It stays beside Connected, and goes when the question is answered.
        s.handle(.exited(code: 0))
        s.handle(.proof(.valid))
        s.handle(.helperRegistered)
        #expect(s.phase == .connected && s.human == .allowNotifications)
        s.handle(.notices("allowed"))
        #expect(s.human == nil && s.phase == .connected)

        var done = state()
        done.handle(.exited(code: 0))
        done.handle(.notices(nil))
        #expect(done.human == .allowNotifications)
        done.handle(.humanDone)
        done.handle(.notices("undetermined"))
        #expect(done.human == nil)

        var allowed = state()
        allowed.handle(.exited(code: 0))
        allowed.handle(.notices("allowed"))
        #expect(allowed.human == nil)

        var linux = state(.install, .linux)
        linux.handle(.exited(code: 0))
        linux.handle(.notices(nil))
        #expect(linux.human == nil)
    }

    @Test func onlyTheInstallersOwnRecordCounts() {
        #expect(SetupRecord(["id": "rexduo-setup", "app": "rexduo-setup", "state": "working", "title": "verify", "progress": 40,
                             "updated_at": "2027-01-01T00:00:00Z"])
            == SetupRecord(state: "working", token: "verify", progress: 40, updatedAt: "2027-01-01T00:00:00Z"))
        #expect(SetupRecord(["id": "claude", "app": "rexduo-setup", "state": "done", "title": "done"]) == nil)
        #expect(SetupRecord(["id": "rexduo-setup", "app": "other", "state": "done", "title": "done"]) == nil)
        #expect(SetupRecord(["state": "done", "title": "done"]) == nil)
        let found = SetupRecord.find(in: [["state": "idle"], ["id": "rexduo-setup", "app": "rexduo-setup", "state": "blocked", "kind": "auth",
                                                              "title": "linger"]])
        #expect(found?.kind == "auth" && found?.token == "linger")
    }

    // MARK: The offer

    @Test func theInstallIsOfferedForThePersonsOwnMacOrLinuxComputerWithoutAHelper() {
        func decide(_ platform: String?, helper: Bool = false, owner: String? = nil, viewer: String? = nil, running: Bool = false) -> HelperOffer {
            HelperOffer.decide(platform: platform, hasHelper: helper, owner: owner, viewer: viewer, running: running)
        }
        #expect(decide("darwin_arm64") == .install)
        #expect(decide("linux_amd64") == .install)
        #expect(decide("Linux_arm64") == .install)
        for other in ["windows_amd64", "freebsd_amd64", "darwin", "", nil] { #expect(decide(other) == .none) }
        #expect(decide("darwin_arm64", helper: true) == .none)
        #expect(decide("darwin_arm64", running: true) == .none)
        #expect(decide("linux_amd64", owner: "sam@x.com", viewer: "me@x.com") == .askOwner)
        #expect(decide("linux_amd64", owner: "Me@x.com", viewer: "me@x.com") == .install)
        // Only two known logins are compared.
        #expect(decide("linux_amd64", owner: "sam@x.com") == .install)
        #expect(decide("linux_amd64", viewer: "me@x.com") == .install)

        #expect(HelperOffer.decide(ServerIdentity(platform: .mac, hasHelper: false)) == .install)
        #expect(HelperOffer.decide(ServerIdentity(platform: .linux, owner: "a@x.com", viewer: "b@x.com", hasHelper: false)) == .askOwner)
        #expect(HelperOffer.decide(ServerIdentity(platform: .mac, hasHelper: true)) == .none)
        #expect(HelperOffer.decide(ServerIdentity(platform: .mac, hasHelper: nil)) == .none)
        #expect(HelperOffer.decide(ServerIdentity(platform: .other, hasHelper: false)) == .none)
        #expect(HelperOffer.decide(ServerIdentity(platform: nil, hasHelper: false)) == .none)
        #expect(HelperOffer.decide(nil) == .none)
    }

    @Test func theOfferSaysWhatThePlanSays() {
        #expect(HelperOfferCard.title("studio") == "Get notifications from studio?")
        #expect(HelperOfferCard.message("studio")
            == "\(Brand.beaconName) runs on studio and notifies this iPhone when an agent finishes or needs you, even while \(Brand.appName) is closed.")
        #expect(HelperOfferCard.footnote("studio") == "\(Brand.appName) opens a tab on studio to install Beacon. Nothing runs as an administrator.")
        #expect(HelperOfferCard.skippedLine("studio")
            == "You won't get notifications from studio while \(Brand.appName) is closed. You can install \(Brand.beaconName) anytime in Settings → Notifications.")
        #expect(PasswordCard.title == "Keep notifications coming after you log out?")
        #expect(PasswordCard.message(name: "studio", account: "sam")
            == "studio stops \(Brand.beaconName) when you log out, unless you allow Beacon to keep running. Allowing that takes the password for sam on studio.")
        #expect(PasswordCard.wrongLine == "That password didn't work. Try again, or choose Not Now.")
        #expect(PasswordCard.aside("studio") == "Your password goes straight to studio and isn't saved on this iPhone.")
    }

    @Test func skippingTheOfferIsRemembered() {
        let suite = "helper-setup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let prefs = Prefs(defaults: defaults)
        #expect(prefs.helperOfferSkipped.isEmpty)
        prefs.helperOfferSkipped.insert(id)
        #expect(Prefs(defaults: defaults).helperOfferSkipped == [id])
    }

    // MARK: Layout and tabs

    @Test func theOutputSitsBesideTheStepsOnlyWhereThereIsRoom() {
        #expect(SetupLayout.decide(size: CGSize(width: 466, height: 678), division: nil) == .single)
        #expect(SetupLayout.decide(size: CGSize(width: 402, height: 874), division: nil) == .single)
        #expect(SetupLayout.decide(size: CGSize(width: 475, height: 669), division: nil) == .single)
        #expect(SetupLayout.decide(size: CGSize(width: 874, height: 402), division: nil) == .sideBySide(steps: 437))
        let crease = Division(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: true)
        #expect(SetupLayout.decide(size: CGSize(width: 951, height: 669), division: crease) == .sideBySide(steps: 455.5))
        let flat = Division(frame: CGRect(x: 0, y: 475.5, width: 669, height: 0), isActive: false)
        #expect(SetupLayout.decide(size: CGSize(width: 669, height: 951), division: flat) == .sideBySide(steps: 335))
    }

    private func sessions() -> (SetupSessions, UserDefaults, String) {
        let suite = "helper-setup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SetupSessions(defaults: defaults), defaults, suite)
    }

    @Test func onlyTabsTheAppRecordedAreEverClosed() {
        let (sessions, defaults, suite) = sessions()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = UUID(), other = UUID()
        let made = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(sessions.entries(server).isEmpty)
        #expect(sessions.leftOver(server, inUse: []).isEmpty)
        #expect(sessions.hidden(server).isEmpty)

        let own = SetupSessions.Entry(sessionID: "session:setup", blockID: "block:1", windowID: nil, createdAt: made)
        sessions.record(own, for: server)
        sessions.record(own, for: server)
        #expect(SetupSessions(defaults: defaults).entries(server) == [own])
        #expect(sessions.hidden(server) == ["session:setup"])
        #expect(sessions.hidden(other).isEmpty)
        // Left over unless a run in this app session uses it, and only on its own computer.
        #expect(sessions.leftOver(server, inUse: []) == [own])
        #expect(sessions.leftOver(server, inUse: ["block:9"]) == [own])
        #expect(sessions.leftOver(server, inUse: ["block:1"]).isEmpty)
        #expect(sessions.leftOver(other, inUse: []).isEmpty)

        // The list keeps every tab that is still open: a second run's tab does not replace the first.
        let second = SetupSessions.Entry(sessionID: "session:setup2", blockID: "block:3", windowID: nil, createdAt: made)
        sessions.record(second, for: server)
        #expect(sessions.entries(server) == [own, second] && sessions.hidden(server) == ["session:setup", "session:setup2"])

        // A tab in one of the user's sessions: that session stays in the sidebar.
        let borrowed = SetupSessions.Entry(sessionID: "session:work", blockID: "block:2", windowID: "window:9", createdAt: made)
        sessions.record(borrowed, for: other)
        #expect(sessions.hidden(other).isEmpty)
        sessions.forget(own, for: server)
        sessions.forget(second, for: server)
        #expect(sessions.entries(server).isEmpty && sessions.entries(other) == [borrowed])
        sessions.forget(borrowed, for: other)
        #expect(defaults.data(forKey: "helperSetup.sessions") == nil)
    }

    @Test func aTabRecordedBeforeThereWasAListIsStillTheApps() throws {
        let (sessions, defaults, suite) = sessions()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = UUID()
        let own = SetupSessions.Entry(sessionID: "session:setup", blockID: "block:1", windowID: nil,
                                      createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        defaults.set(try JSONEncoder().encode([server.uuidString: own]), forKey: "helperSetup.sessions")
        #expect(sessions.entries(server) == [own] && sessions.contains(own, for: server))
    }

    // MARK: The setup session closes when it is done

    /// The control API's side of closing a tab: what each session holds, what was read, what
    /// was asked to close, and whether the server answers.
    @MainActor
    final class Server {
        /// What a session holds: its windows in order, each with its blocks.
        var sessions: [String: [(window: String, blocks: [String])]] = [:]
        /// Every session the closer read before a close, in order.
        var read: [String] = []
        /// The tabs something was asked to close of, in order.
        var asked: [SetupSessions.Entry] = []
        /// What the server closed, in order.
        var did: [SetupTabClose] = []
        /// The tabs the server closed.
        var closed: [SetupSessions.Entry] = []
        /// The server answers at all. Off: the connection is gone.
        var answers = true
        /// The server answers a read with something that is no view of the session.
        var garbles = false

        /// The session as the app's tab left it: one window with the tab's block, and for a tab
        /// in one of the person's sessions, the person's own window before it.
        func hold(_ tab: SetupSessions.Entry) {
            let own = (window: tab.windowID ?? "window:1", blocks: [tab.blockID])
            sessions[tab.sessionID] = tab.windowID == nil ? [own] : [(window: "window:mine", blocks: ["block:mine"]), own]
        }

        func view(_ session: String) -> SessionView? {
            guard let windows = sessions[session] else { return nil }
            return SessionView(["session_id": session, "windows": windows.map { w in
                ["window_id": w.window, "layers": [["layer_id": "layer", "blocks": w.blocks.map { ["block_id": $0] }] as JSONObject]] as JSONObject
            }])
        }
    }

    private func closer(_ sessions: SetupSessions, _ server: Server) -> SetupSessionCloser {
        // Each of the stock tabs is on the server as the app made it, unless the test set it up.
        for tab in Self.tabs where server.sessions[tab.sessionID] == nil { server.hold(tab) }
        return SetupSessionCloser(sessions: sessions, server: SetupTabServer(
            read: { _, session in
                guard server.answers else { return .noAnswer }
                server.read.append(session)
                if server.garbles { return .unreadable }
                return server.view(session).map { .view($0) } ?? .unreadable
            },
            close: { _, what, entry in
                server.asked.append(entry)
                guard server.answers else { return false }
                server.did.append(what)
                server.closed.append(entry)
                switch what {
                case .session: server.sessions[entry.sessionID] = nil
                case .window(let id): server.sessions[entry.sessionID]?.removeAll { $0.window == id }
                case .block:
                    if let i = server.sessions[entry.sessionID]?.firstIndex(where: { $0.blocks.contains(entry.blockID) }) {
                        server.sessions[entry.sessionID]?[i].blocks.removeAll { $0 == entry.blockID }
                    }
                case .nothing: break
                }
                return true
            }))
    }

    /// The tab an install or a removal makes: a session of its own, or, on a server at its
    /// session limit, a window in one of the person's sessions.
    private static let tabs = [
        SetupSessions.Entry(sessionID: "session:install", blockID: "block:1", windowID: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000)),
        SetupSessions.Entry(sessionID: "session:remove", blockID: "block:2", windowID: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000)),
        SetupSessions.Entry(sessionID: "session:work", blockID: "block:3", windowID: "window:9", createdAt: Date(timeIntervalSince1970: 1_800_000_000)),
    ]

    @Test func aScriptThatEndedWellClosesItsTabAtOnceAndOnlyOnce() async {
        // The same for an install's tab, a removal's, and a tab in one of the person's sessions.
        for tab in Self.tabs {
            let (sessions, defaults, suite) = sessions()
            defer { defaults.removePersistentDomain(forName: suite) }
            let server = Server(), id = UUID()
            let closer = closer(sessions, server)
            closer.made(tab, on: id)
            #expect(await closer.handle(.exited(code: 0), tab, on: id))
            #expect(server.closed == [tab] && sessions.entries(id).isEmpty)
            // Done in the sheet, the sheet going away, the next connection: nothing is left to close.
            await closer.handle(.done, tab, on: id)
            await closer.handle(.dismissed(detailsShown: true), tab, on: id)
            await closer.handle(.cancel, tab, on: id)
            await closer.connected(id, inUse: [])
            #expect(server.asked == [tab])
        }
    }

    @Test func aScriptThatFailedKeepsItsTabUntilThePersonIsDoneWithIt() async {
        for last in [SetupSessionCloser.Reason.done, .retry, .cancel, .dismissed(detailsShown: true)] {
            let (sessions, defaults, suite) = sessions()
            defer { defaults.removePersistentDomain(forName: suite) }
            let server = Server(), id = UUID(), tab = Self.tabs[0]
            let closer = closer(sessions, server)
            closer.made(tab, on: id)
            // Any exit code but 0, and the sheet closing before its details were looked at.
            for code in [1, 10, 15, 16, 21, -1] { #expect(await closer.handle(.exited(code: code), tab, on: id) == false) }
            #expect(await closer.handle(.dismissed(detailsShown: false), tab, on: id) == false)
            // The run still holds the tab for "Show details": a reconnect leaves it alone.
            await closer.connected(id, inUse: [tab.blockID])
            #expect(server.asked.isEmpty && sessions.entries(id) == [tab])

            #expect(await closer.handle(last, tab, on: id))
            await closer.handle(.done, tab, on: id)
            #expect(server.asked == [tab] && sessions.entries(id).isEmpty)
        }
        #expect(SetupSessionCloser.closes(.exited(code: 0)) && !SetupSessionCloser.closes(.exited(code: 15)))
        #expect(!SetupSessionCloser.closes(.dismissed(detailsShown: false)))
    }

    @Test func aSessionOfTheSameNameWithAnotherIDIsNeverClosed() async {
        let (sessions, defaults, suite) = sessions()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = Server(), id = UUID(), tab = Self.tabs[0]
        let closer = closer(sessions, server)
        closer.made(tab, on: id)
        // Another "Beacon setup" session on the computer: the app has no record of making it.
        let stranger = SetupSessions.Entry(sessionID: "session:other", blockID: "block:9", windowID: nil, createdAt: tab.createdAt)
        for reason in [SetupSessionCloser.Reason.exited(code: 0), .done, .retry, .cancel, .dismissed(detailsShown: true)] {
            #expect(await closer.handle(reason, stranger, on: id) == false)
        }
        // Nor the app's own tab on another computer.
        #expect(await closer.handle(.done, tab, on: UUID()) == false)
        #expect(server.asked.isEmpty && sessions.entries(id) == [tab])
        // On a connection the app's own tab closes, and the stranger is still not asked for:
        // the list holds ids, and nothing is ever looked up by name.
        await closer.connected(id, inUse: [])
        await closer.connected(UUID(), inUse: [])
        #expect(server.asked == [tab] && !server.asked.contains(where: stranger.isSame) && sessions.entries(id).isEmpty)
        #expect(SetupBlock.label == "\(Brand.beaconName) setup")
    }

    @Test func aTabLeftFromAnEarlierRunOfTheAppClosesOnTheNextConnection() async {
        // The app was killed while a failed install's tab was open: only the stored list knows of it.
        for tab in Self.tabs {
            let (sessions, defaults, suite) = sessions()
            defer { defaults.removePersistentDomain(forName: suite) }
            let server = Server(), id = UUID(), elsewhere = UUID()
            sessions.record(tab, for: id)
            sessions.record(Self.tabs[1], for: elsewhere)
            // The app starts again: a new closer over the same stored list.
            let closer = closer(SetupSessions(defaults: defaults), server)
            await closer.connected(id, inUse: [])
            #expect(server.asked == [tab] && server.closed == [tab] && sessions.entries(id).isEmpty)
            // Closed once: the next connections find nothing. Another computer's tab waits for its own.
            await closer.connected(id, inUse: [])
            await closer.connected(id, inUse: [])
            #expect(server.asked == [tab] && sessions.entries(elsewhere) == [Self.tabs[1]])
        }
    }

    @Test func aStoredTabTheComputerNoLongerHasLeavesTheListWithoutAnError() async {
        let (sessions, defaults, suite) = sessions()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = Server(), id = UUID(), tab = Self.tabs[0]
        sessions.record(tab, for: id)
        let closer = closer(sessions, server)
        // The computer restarted, or somebody closed the session there.
        server.sessions[tab.sessionID] = nil
        await closer.connected(id, inUse: [])
        #expect(server.read == [tab.sessionID] && server.asked.isEmpty && sessions.entries(id).isEmpty)
        await closer.connected(id, inUse: [])
        #expect(server.read == [tab.sessionID])
    }

    // MARK: A tab is read before it is closed

    @Test func aSessionThatHoldsOnlyTheAppsBlockIsDestroyed() async {
        let (sessions, defaults, suite) = sessions()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = Server(), id = UUID(), tab = Self.tabs[0]
        let closer = closer(sessions, server)
        closer.made(tab, on: id)
        #expect(await closer.handle(.done, tab, on: id))
        #expect(server.read == [tab.sessionID] && server.did == [.session] && server.sessions[tab.sessionID] == nil)
        #expect(sessions.entries(id).isEmpty)
    }

    @Test func aSessionIDThatNoLongerHoldsTheAppsBlockIsLeftAlone() async {
        // The same for every way a tab closes: the script ending well, Done, Retry, Cancel, the
        // sheet going away, and a tab left over on a connection.
        let reasons: [SetupSessionCloser.Reason?] = [.exited(code: 0), .done, .retry, .cancel, .dismissed(detailsShown: true), nil]
        for reason in reasons {
            for tab in Self.tabs {
                let (sessions, defaults, suite) = sessions()
                defer { defaults.removePersistentDomain(forName: suite) }
                let server = Server(), id = UUID()
                let closer = closer(sessions, server)
                closer.made(tab, on: id)
                // The id now names a session with other blocks in it, and the tab's block is not one.
                server.sessions[tab.sessionID] = [(window: tab.windowID ?? "window:1", blocks: ["block:theirs"]), (window: "window:2", blocks: ["block:other"])]
                if let reason { await closer.handle(reason, tab, on: id) } else { await closer.connected(id, inUse: []) }
                #expect(server.read == [tab.sessionID] && server.asked.isEmpty && server.did.isEmpty)
                #expect(server.sessions[tab.sessionID]?.count == 2 && sessions.entries(id).isEmpty)
            }
        }
    }

    @Test func aSessionThatHoldsMoreLosesOnlyTheAppsBlock() async {
        let (sessions, defaults, suite) = sessions()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), tab = Self.tabs[0]

        // Another block beside the app's, in the same window: only the app's block closes.
        var server = Server()
        var closer = closer(sessions, server)
        closer.made(tab, on: id)
        server.sessions[tab.sessionID] = [(window: "window:1", blocks: [tab.blockID, "block:other"])]
        #expect(await closer.handle(.cancel, tab, on: id))
        #expect(server.did == [.block] && server.sessions[tab.sessionID]?.first?.blocks == ["block:other"] && sessions.entries(id).isEmpty)

        // Another window beside the app's: the app's window closes, and the session stays.
        server = Server()
        closer = self.closer(sessions, server)
        closer.made(tab, on: id)
        server.sessions[tab.sessionID] = [(window: "window:1", blocks: [tab.blockID]), (window: "window:2", blocks: ["block:other"])]
        #expect(await closer.handle(.done, tab, on: id))
        #expect(server.did == [.window("window:1")] && server.sessions[tab.sessionID]?.map(\.window) == ["window:2"])

        // A tab in one of the person's sessions: its window, or its block when the window holds more.
        let borrowed = Self.tabs[2]
        server = Server()
        closer = self.closer(sessions, server)
        closer.made(borrowed, on: id)
        await closer.connected(id, inUse: [])
        #expect(server.did == [.window("window:9")] && server.sessions[borrowed.sessionID]?.map(\.window) == ["window:mine"])
        server = Server()
        closer = self.closer(sessions, server)
        closer.made(borrowed, on: id)
        server.sessions[borrowed.sessionID] = [(window: "window:9", blocks: ["block:mine", borrowed.blockID])]
        await closer.connected(id, inUse: [])
        #expect(server.did == [.block] && server.sessions[borrowed.sessionID]?.first?.blocks == ["block:mine"])
        // Left alone in its session, such a tab still closes as a window: the session is the person's.
        #expect(SetupTabClose.decide(borrowed, view: Server().view("none")) == .nothing)
        let alone = Server()
        alone.sessions[borrowed.sessionID] = [(window: "window:9", blocks: [borrowed.blockID])]
        #expect(SetupTabClose.decide(borrowed, view: alone.view(borrowed.sessionID)) == .window("window:9"))
    }

    @Test func aReadThatFailsClosesNothing() async {
        let (sessions, defaults, suite) = sessions()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = Server(), id = UUID(), tab = Self.tabs[0]
        let closer = closer(sessions, server)
        closer.made(tab, on: id)
        // No answer: nothing is closed, and the tab waits in the list for the next connection.
        server.answers = false
        #expect(await closer.handle(.done, tab, on: id) == false)
        #expect(server.asked.isEmpty && sessions.entries(id) == [tab])
        // An answer that is no view of the session: nothing is closed, and the entry is dropped.
        server.answers = true
        server.garbles = true
        #expect(await closer.handle(.done, tab, on: id))
        #expect(server.asked.isEmpty && server.sessions[tab.sessionID] != nil && sessions.entries(id).isEmpty)
        // A view of another session than the one asked for is no answer either.
        #expect(SetupTabClose.decide(tab, view: SessionView(["session_id": "session:other", "windows": []])) == .nothing)
        #expect(SetupTabClose.decide(tab, view: nil) == .nothing)
    }

    @Test func aRunInProgressKeepsItsTabThroughAReconnect() async {
        let (sessions, defaults, suite) = sessions()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = Server(), id = UUID(), old = Self.tabs[0], running = Self.tabs[1]
        // One tab left from an earlier run of the app, and one this app session's install runs in.
        sessions.record(old, for: id)
        let closer = closer(sessions, server)
        closer.made(running, on: id)
        await closer.connected(id, inUse: [running.blockID])
        await closer.connected(id, inUse: [running.blockID])
        #expect(server.asked == [old] && sessions.entries(id) == [running])
        // The run is over without having closed its tab: the next connection closes it.
        await closer.connected(id, inUse: [])
        #expect(server.asked == [old, running] && sessions.entries(id).isEmpty)
    }

    @Test func aCloseTheServerDidNotTakeIsTriedAgainOnTheNextConnection() async {
        let (sessions, defaults, suite) = sessions()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = Server(), id = UUID(), tab = Self.tabs[0]
        let closer = closer(sessions, server)
        closer.made(tab, on: id)
        // The connection dropped as the script ended.
        server.answers = false
        #expect(await closer.handle(.exited(code: 0), tab, on: id) == false)
        #expect(server.closed.isEmpty && sessions.entries(id) == [tab])

        // Connected again, and still no answer: it stays in the app's list.
        await closer.connected(id, inUse: [])
        #expect(server.closed.isEmpty && sessions.entries(id) == [tab])

        // The next connection takes it, and then nothing is left to ask for.
        server.answers = true
        await closer.connected(id, inUse: [])
        await closer.connected(id, inUse: [])
        #expect(server.asked == [tab] && server.closed == [tab] && sessions.entries(id).isEmpty)
    }

    @Test func theSheetOffersNoDetailsOnceTheTabIsClosed() {
        var state = SetupState(kind: .install, computer: .mac)
        state.handle(.started)
        #expect(state.hasTab)
        state.handle(.exited(code: 0))
        state.handle(.tabClosed)
        // The run goes on to the helper's proof without its tab.
        #expect(!state.hasTab && state.phase == .connecting)
        // A failed run's tab closes after the fact too.
        var failed = SetupState(kind: .install, computer: .mac)
        failed.handle(.started)
        failed.handle(.exited(code: 15))
        #expect(failed.hasTab && failed.error != nil)
        failed.handle(.tabClosed)
        #expect(!failed.hasTab && failed.error != nil)
    }
}
