import Foundation

/// A string folded once for matching: case, diacritics and width fold away, so `ÉCOLE`, `école`
/// and `ｅcole` all read `ecole`. Kept as scalars with a map back to the display string's
/// characters, so a match always covers whole characters (an `é` is never half matched).
struct FoldedText: Sendable, Equatable {
    /// The folded scalars, in order.
    var scalars: [UInt32]
    /// Whether each folded scalar starts a word of the display string: the first character, one
    /// after a space, `/`, `-`, `_` or `.`, or an uppercase letter after a lowercase one.
    var wordStarts: [Bool]
    /// For each folded scalar, the offset of the display character it came from.
    var offsets: [Int]

    var count: Int { scalars.count }

    /// `ascii: false` takes the full path even for ASCII text (tests compare the two).
    init(_ display: String, ascii: Bool = true) {
        scalars = []
        wordStarts = []
        offsets = []
        if ascii, display.utf8.allSatisfy({ $0 < 0x80 }) {
            asciiFold(display)
        } else {
            fullFold(display)
        }
    }

    /// The fast path: an ASCII string folds to its lowercase bytes, one per character.
    private mutating func asciiFold(_ s: String) {
        let bytes = Array(s.utf8)
        scalars.reserveCapacity(bytes.count)
        wordStarts.reserveCapacity(bytes.count)
        offsets.reserveCapacity(bytes.count)
        var prev: UInt8?
        for (i, b) in bytes.enumerated() {
            let upper = b >= 0x41 && b <= 0x5A
            scalars.append(UInt32(upper ? b + 0x20 : b))
            let start: Bool
            if let p = prev {
                // The same rule as `startsWord`, on bytes.
                start = p == 0x20 || p == 0x2F || p == 0x2D || p == 0x5F || p == 0x2E || (upper && p >= 0x61 && p <= 0x7A)
            } else {
                start = true
            }
            wordStarts.append(start)
            offsets.append(i)
            prev = b
        }
    }

    private mutating func fullFold(_ display: String) {
        let s = display.precomposedStringWithCanonicalMapping
        var prev: Character?
        for (i, ch) in s.enumerated() {
            let start = Self.startsWord(prev: prev, ch)
            var first = true
            for u in Self.fold(String(ch)).unicodeScalars {
                scalars.append(u.value)
                wordStarts.append(first && start)
                offsets.append(i)
                first = false
            }
            prev = ch
        }
    }

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: options, locale: nil)
    }

    private static func startsWord(prev: Character?, _ ch: Character) -> Bool {
        guard let prev else { return true }
        if " /-_.".contains(prev) { return true }
        return prev.isLowercase && ch.isUppercase
    }

    /// A query's words, folded the same way. Empty words are left out.
    static func query(_ q: String) -> [[UInt32]] {
        q.split(whereSeparator: \.isWhitespace).map { word in
            let w = String(word)
            if w.utf8.allSatisfy({ $0 < 0x80 }) {
                return w.utf8.map { b in UInt32((b >= 0x41 && b <= 0x5A) ? b + 0x20 : b) }
            }
            return fold(w).unicodeScalars.map(\.value)
        }.filter { !$0.isEmpty }
    }
}

/// Scores one query word against one folded field: every scalar of the word in order, best
/// placed. Word starts +16, a scalar right after the last one +8, the field's start +24, −1 for
/// each scalar skipped (at most 8 per gap), −0.5 for each scalar the field is longer than the
/// word (at most 20 in all).
///
/// Reuses its buffers between calls, so one matcher serves a whole search.
struct FuzzyMatcher {
    static let wordStart = 16.0
    static let consecutive = 8.0
    static let prefix = 24.0
    static let gapCap = 8
    static let lengthCap = 20.0

    private var best: [Double] = []
    private var from: [Int32] = []

    /// True when every scalar of `q` appears in `t`, in order.
    static func contains(_ q: [UInt32], in t: FoldedText) -> Bool {
        guard !q.isEmpty else { return true }
        var i = 0
        for s in t.scalars where s == q[i] {
            i += 1
            if i == q.count { return true }
        }
        return false
    }

    /// The score, or nil when the word isn't in the field. `ranges`: also the matched display
    /// characters, as ranges of character offsets.
    mutating func score(_ q: [UInt32], in t: FoldedText, ranges: Bool = false) -> (score: Double, ranges: [Range<Int>])? {
        let m = q.count, n = t.count
        guard m > 0, m <= n, Self.contains(q, in: t) else { return nil }
        let size = m * n
        if best.count < size {
            best = [Double](repeating: 0, count: size)
            from = [Int32](repeating: 0, count: size)
        }
        let none = -Double.infinity
        let scalars = t.scalars, starts = t.wordStarts
        return best.withUnsafeMutableBufferPointer { best in
            from.withUnsafeMutableBufferPointer { from -> (score: Double, ranges: [Range<Int>])? in
                // Row 0: the word's first scalar at j.
                for j in 0..<n {
                    guard scalars[j] == q[0] else { best[j] = none; continue }
                    var s = starts[j] ? Self.wordStart : 0
                    if j == 0 { s += Self.prefix }
                    s -= Double(min(j, Self.gapCap))
                    best[j] = s
                    from[j] = -1
                }
                for i in 1..<m {
                    let row = i * n, prev = (i - 1) * n
                    // The best of the previous row far enough back that the gap penalty is capped.
                    var far = none, farAt: Int32 = -1
                    for j in 0..<n {
                        // k == j - gapCap - 1 joins the capped region now.
                        let k = j - Self.gapCap - 1
                        if k >= 0, best[prev + k] > far { far = best[prev + k]; farAt = Int32(k) }
                        guard scalars[j] == q[i] else { best[row + j] = none; continue }
                        var top = none, at: Int32 = -1
                        if far > none { top = far - Double(Self.gapCap); at = farAt }
                        let lo = max(0, j - Self.gapCap)
                        if lo < j {
                            for k in lo..<j where best[prev + k] > none {
                                let gap = j - k - 1
                                let v = best[prev + k] + (gap == 0 ? Self.consecutive : -Double(gap))
                                if v > top { top = v; at = Int32(k) }
                            }
                        }
                        guard top > none else { best[row + j] = none; continue }
                        best[row + j] = top + (starts[j] ? Self.wordStart : 0)
                        from[row + j] = at
                    }
                }
                let last = (m - 1) * n
                var top = none, end = -1
                for j in 0..<n where best[last + j] > top { top = best[last + j]; end = j }
                guard end >= 0 else { return nil }
                let score = top - min(Double(n - m) * 0.5, Self.lengthCap)
                guard ranges else { return (score, []) }
                var picked: [Int] = []
                var j = end
                for i in stride(from: m - 1, through: 0, by: -1) {
                    picked.append(t.offsets[j])
                    j = Int(from[i * n + j])
                    if j < 0 { break }
                }
                return (score, Self.ranges(picked.reversed()))
            }
        }
    }

    /// Sorted character offsets as ranges, a character that several scalars came from once.
    static func ranges(_ offsets: some Sequence<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for o in offsets {
            if let last = out.last, o < last.upperBound { continue }
            if let last = out.last, last.upperBound == o {
                out[out.count - 1] = last.lowerBound..<(o + 1)
            } else {
                out.append(o..<(o + 1))
            }
        }
        return out
    }
}
