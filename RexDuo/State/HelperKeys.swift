import Foundation

/// The keys Rex DUO Helper releases are signed with: the same two values as
/// `Relay/update-key.pub`, each the base64 of the 32 raw bytes of an ed25519 public key. A test
/// reads that file from the source tree and fails when the two differ, so a key is changed in
/// both places or in neither.
enum HelperKeys {
    /// Signs releases.
    static let primary = "Yn851QvA2ZzvkX/TkpqQcsiIOqUd2wi0jAFRbh+0OP0="
    /// Kept apart from the primary. It can sign a release list that hands over a new key.
    static let recovery = "p6Uwh2Qc232RxSymb4uFSkx/A/4Czn+/+QTz16RbLGE="

    /// Both, as raw bytes, the primary first.
    static var builtin: [Data] { [primary, recovery].compactMap(key) }

    /// A key as the file and the release list write it: 44 characters of base64 for 32 bytes.
    /// All zeros is a placeholder, which is no key.
    static func key(_ base64: String) -> Data? {
        guard base64.utf8.count == 44, let data = Data(base64Encoded: base64), data.count == 32,
              data.contains(where: { $0 != 0 }) else { return nil }
        return data
    }

    /// Reads `update-key.pub`: `#` lines are comments, every other line is a label (`primary` or
    /// `recovery`) and a key. Nil for a file with any other line, a repeated label or no primary.
    static func parse(_ text: String) -> (primary: String, recovery: String?)? {
        var primary: String?, recovery: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard words.count == 2, key(words[1]) != nil else { return nil }
            switch words[0] {
            case "primary" where primary == nil: primary = words[1]
            case "recovery" where recovery == nil: recovery = words[1]
            default: return nil
            }
        }
        return primary.map { ($0, recovery) }
    }
}
