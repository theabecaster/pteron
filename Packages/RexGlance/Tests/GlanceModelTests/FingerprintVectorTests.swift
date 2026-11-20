import Foundation
import Testing
@testable import GlanceModel

/// The wait's fingerprint is made twice: by the app (`ActionGuard.fingerprint`) and by Beacon
/// (`policy::fingerprint` in Relay/src), which puts it into a question's push. An action on
/// that push is typed only when the two are equal, so both are tested against one list of
/// cases with the expected values, `Relay/fixtures/fingerprints.json`.
@Suite struct FingerprintVectorTests {
    struct Vector {
        var name: String
        var state: String
        var kind: String?
        var message: String?
        var fp: String
    }

    static func vectors() throws -> [Vector] {
        var root = URL(fileURLWithPath: #filePath)
        // Packages/RexGlance/Tests/GlanceModelTests/<this file>
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Relay/fixtures/fingerprints.json"))
        let list = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try list.map { entry in
            Vector(name: try #require(entry["name"] as? String), state: try #require(entry["state"] as? String),
                   kind: entry["kind"] as? String, message: entry["message"] as? String, fp: try #require(entry["fp"] as? String))
        }
    }

    @Test func everySharedCaseGivesTheExpectedFingerprint() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count >= 20)
        var seen = Set<String>()
        for v in vectors {
            let fp = ActionGuard.fingerprint(state: v.state, kind: v.kind, message: v.message)
            #expect(fp == v.fp, "\(v.name)")
            #expect(fp.count == 16 && fp.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(v.name)")
            #expect(seen.insert(fp).inserted, "\(v.name) gives another case's fingerprint")
            #expect(ActionGuard.Current(record: "r", state: v.state, kind: v.kind, message: v.message).fingerprint == v.fp, "\(v.name)")
        }
    }

    @Test func theListHoldsTheCasesThatMatter() throws {
        let vectors = try Self.vectors().filter { $0.state == "blocked" }
        func has(_ kind: String?, _ message: String?) -> Bool { vectors.contains { $0.kind == kind && $0.message == message } }
        // Missing against empty, each way.
        #expect(has(nil, nil) && has("", "") && has(nil, "") && has("", nil))
        // Text Beacon trims for the push's words, long text, line breaks and wide characters.
        #expect(vectors.contains { $0.message.map { $0 != $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? false })
        #expect(vectors.contains { ($0.message?.utf8.count ?? 0) > 1000 })
        #expect(vectors.contains { $0.message?.contains("\r\n") ?? false })
        #expect(vectors.contains { $0.message?.unicodeScalars.contains { $0.value > 0xffff } ?? false })
        // An accent written two ways is two waits: nothing is normalized.
        let composed = try #require(vectors.first { $0.message == "Caf\u{e9}?" && $0.message?.unicodeScalars.count == 5 })
        let decomposed = try #require(vectors.first { $0.message?.unicodeScalars.count == 6 && $0.message?.unicodeScalars.contains("\u{301}") == true })
        #expect(composed.fp != decomposed.fp)
    }
}
