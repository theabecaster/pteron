import Foundation

// The tar archives an fs block sends and takes (`com.superlogical.fs`, docs/rex-protocol.md, The
// fs block). Rex reads and writes them with Go's archive/tar: it sends PAX archives (a PAX header
// before each entry, with the path and a fractional mtime) and takes ustar, PAX and GNU ones.
// The writer here writes ustar, with a PAX header only for what ustar can't hold (a long name or
// link, a size of 8 GiB or more). The reader takes ustar, PAX and GNU long names.

/// One entry of an archive.
public struct TarEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file
        case directory
        /// A symbolic link to this target, as written.
        case symlink(String)
        /// Anything else (a hard link, a device, a FIFO): read past, never written.
        case other
    }

    /// The path inside the archive: components joined by `/`, no leading or trailing `/`.
    public var path: String
    public var kind: Kind
    /// The bytes that follow the header: a file's size, 0 for the others.
    public var size: Int64
    /// The permission bits.
    public var mode: Int
    /// Seconds since 1970.
    public var mtime: Int64

    public init(path: String, kind: Kind, size: Int64 = 0, mode: Int? = nil, mtime: Int64 = 0) {
        self.path = path
        self.kind = kind
        self.size = kind == .file ? size : 0
        self.mode = mode ?? (kind == .directory ? 0o755 : 0o644)
        self.mtime = mtime
    }
}

/// The byte layout of a tar archive: 512-byte blocks, a header block (or more) before each
/// entry, its bytes padded to a whole block, and two zero blocks at the end.
public enum TarFormat {
    public static let block = 512
    /// The two zero blocks that end an archive.
    public static let endBytes = 1024
    /// The longest PAX or GNU long-name record the reader keeps: a name is at most a few KB, so
    /// anything larger is a broken or hostile archive, and memory stays bounded.
    public static let maxMetaBytes = 1 << 20

    /// The padding after `size` bytes of content.
    public static func padding(_ size: Int64) -> Int {
        let r = Int(size % Int64(block))
        return r == 0 ? 0 : block - r
    }

    /// The header block, or blocks, before an entry.
    public static func header(_ e: TarEntry) -> Data {
        var name = e.path
        if e.kind == .directory { name += "/" }
        var pax: [(String, String)] = []
        let nameBytes = Array(name.utf8)
        if nameBytes.count > 100 { pax.append(("path", name)) }
        var link = ""
        if case .symlink(let target) = e.kind {
            link = target
            if link.utf8.count > 100 { pax.append(("linkpath", link)) }
        }
        let sizeFits = e.size < 0o77777777777
        if !sizeFits { pax.append(("size", String(e.size))) }
        var out = Data()
        if !pax.isEmpty {
            let records = paxRecords(pax)
            out.append(block(name: "PaxHeaders/" + String(decoding: cut(nameBytes, 80), as: UTF8.self), mode: 0o644,
                             size: Int64(records.count), mtime: e.mtime, type: UInt8(ascii: "x"), link: []))
            out.append(records)
            out.append(Data(count: padding(Int64(records.count))))
        }
        let type: UInt8
        switch e.kind {
        case .file: type = UInt8(ascii: "0")
        case .directory: type = UInt8(ascii: "5")
        case .symlink: type = UInt8(ascii: "2")
        case .other: type = UInt8(ascii: "0")
        }
        out.append(block(name: String(decoding: cut(nameBytes, 100), as: UTF8.self), mode: e.mode,
                         size: sizeFits ? e.size : 0, mtime: e.mtime, type: type, link: cut(Array(link.utf8), 100)))
        return out
    }

    /// The archive's length for these entries, end blocks included.
    public static func archiveSize(_ entries: [TarEntry]) -> Int64 {
        entries.reduce(Int64(endBytes)) { $0 + Int64(header($1).count) + $1.size + Int64(padding($1.size)) }
    }

    /// The first `max` bytes, never ending inside a UTF-8 character.
    static func cut(_ bytes: [UInt8], _ max: Int) -> [UInt8] {
        guard bytes.count > max else { return bytes }
        var end = max
        while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return Array(bytes[..<end])
    }

    /// PAX records: `<length> <key>=<value>\n`, where the length counts the whole record.
    static func paxRecords(_ pairs: [(String, String)]) -> Data {
        var out = Data()
        for (k, v) in pairs {
            let body = " \(k)=\(v)\n"
            let n = body.utf8.count
            var len = n + String(n).count
            if String(len).count != String(n).count { len = n + String(len).count }
            out.append(contentsOf: Array("\(len)\(body)".utf8))
        }
        return out
    }

    private static func block(name: String, mode: Int, size: Int64, mtime: Int64, type: UInt8, link: [UInt8]) -> Data {
        var b = [UInt8](repeating: 0, count: block)
        func put(_ bytes: [UInt8], at offset: Int, max: Int) {
            for (i, c) in bytes.prefix(max).enumerated() { b[offset + i] = c }
        }
        func octal(_ v: Int64, at offset: Int, width: Int) {
            let s = String(v, radix: 8)
            let padded = String(repeating: "0", count: max(0, width - 1 - s.count)) + s
            put(Array(padded.utf8), at: offset, max: width - 1)
        }
        put(Array(name.utf8), at: 0, max: 100)
        octal(Int64(mode & 0o7777), at: 100, width: 8)
        octal(0, at: 108, width: 8)
        octal(0, at: 116, width: 8)
        octal(size, at: 124, width: 12)
        octal(max(0, mtime), at: 136, width: 12)
        b[156] = type
        put(link, at: 157, max: 100)
        put(Array("ustar\u{0}00".utf8), at: 257, max: 8)
        // The checksum: the sum of the block with its own field read as spaces.
        for i in 148..<156 { b[i] = 0x20 }
        let sum = b.reduce(0) { $0 + Int($1) }
        let s = String(sum, radix: 8)
        put(Array((String(repeating: "0", count: max(0, 6 - s.count)) + s).utf8), at: 148, max: 6)
        b[154] = 0
        b[155] = 0x20
        return Data(b)
    }
}

/// Paths inside an archive that are safe to write under a folder of this device: relative, with
/// no `..`, no NUL and no empty result. `.` and empty components are dropped.
public enum TarPath {
    /// The components to write, or nil for a path that would leave the folder.
    public static func components(_ path: String) -> [String]? {
        guard !path.hasPrefix("/"), !path.contains("\u{0}") else { return nil }
        var out: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            out.append(String(part))
        }
        return out.isEmpty ? nil : out
    }

    /// A path for `download_begin`, which reads each path as a pattern (`*`, `?`, `[...]`, as
    /// Go's filepath.Match does): every pattern character, and the backslash, is escaped, so the
    /// server matches the path the user picked and nothing else.
    public static func literal(_ path: String) -> String {
        var out = ""
        for ch in path {
            if ch == "\\" || ch == "*" || ch == "?" || ch == "[" { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/// Reads an archive as it arrives, in pieces of any size, and hands each entry and its bytes on.
/// Only a header and a PAX or GNU long-name record are ever held, each bounded; an entry's bytes
/// pass straight through.
public struct TarReader {
    public enum Failure: Error, Equatable {
        /// A header block whose checksum doesn't match: not an archive, or a broken one.
        case badHeader
        /// A PAX or GNU record larger than `TarFormat.maxMetaBytes`.
        case oversizedRecord
        /// The data ended inside an entry.
        case truncated
    }

    public typealias Sink = (Event) throws -> Void

    public enum Event {
        case begin(TarEntry)
        /// Bytes of the entry begun last.
        case bytes(Data)
        case end
    }

    private enum State {
        case header
        /// Bytes of an entry, then its padding.
        case content(left: Int64, pad: Int, hand: Bool)
        /// A PAX (`x`, `g`) or GNU (`L`, `K`) record.
        case meta(type: UInt8, left: Int64, pad: Int)
        case done
    }

    private var state = State.header
    private var buffer = Data()
    private var meta = Data()
    private var pax: [String: String] = [:]
    private var longName: String?
    private var longLink: String?
    private var zeroBlocks = 0
    private let sink: Sink
    /// The end-of-archive blocks have arrived.
    public private(set) var finished = false

    public init(sink: @escaping Sink) { self.sink = sink }

    public mutating func feed(_ data: Data) throws {
        var rest = data[data.startIndex...]
        while !rest.isEmpty {
            switch state {
            case .done:
                return
            case .header:
                let need = TarFormat.block - buffer.count
                let take = rest.prefix(need)
                buffer.append(take)
                rest = rest.dropFirst(take.count)
                if buffer.count == TarFormat.block {
                    let block = buffer
                    buffer = Data()
                    try header(block)
                }
            case .content(let left, let pad, let hand):
                if left > 0 {
                    let n = Int(min(Int64(rest.count), left))
                    if hand { try sink(.bytes(Data(rest.prefix(n)))) }
                    rest = rest.dropFirst(n)
                    let now = left - Int64(n)
                    state = .content(left: now, pad: pad, hand: hand)
                    if now == 0, hand { try sink(.end) }
                    if now == 0, pad == 0 { state = .header }
                } else {
                    let n = min(rest.count, pad)
                    rest = rest.dropFirst(n)
                    state = pad - n == 0 ? .header : .content(left: 0, pad: pad - n, hand: hand)
                }
            case .meta(let type, let left, let pad):
                if left > 0 {
                    let n = Int(min(Int64(rest.count), left))
                    meta.append(rest.prefix(n))
                    rest = rest.dropFirst(n)
                    state = .meta(type: type, left: left - Int64(n), pad: pad)
                } else {
                    let n = min(rest.count, pad)
                    rest = rest.dropFirst(n)
                    state = .meta(type: type, left: 0, pad: pad - n)
                }
                if case .meta(_, 0, 0) = state {
                    finishMeta(type)
                    state = .header
                }
            }
        }
    }

    /// The data is over: an archive that ends between entries is whole, even without its end
    /// blocks (Go's writer always sends them).
    public func finish() throws {
        switch state {
        case .header where buffer.isEmpty, .done: return
        default: throw Failure.truncated
        }
    }

    private mutating func header(_ b: Data) throws {
        let bytes = [UInt8](b)
        if bytes.allSatisfy({ $0 == 0 }) {
            zeroBlocks += 1
            if zeroBlocks == 2 {
                finished = true
                state = .done
            }
            return
        }
        zeroBlocks = 0
        guard Self.checksumMatches(bytes) else { throw Failure.badHeader }
        let type = bytes[156]
        guard let size = Self.number(bytes[124..<136]), size >= 0 else { throw Failure.badHeader }
        switch type {
        case UInt8(ascii: "x"), UInt8(ascii: "g"), UInt8(ascii: "L"), UInt8(ascii: "K"):
            guard size <= TarFormat.maxMetaBytes else { throw Failure.oversizedRecord }
            meta = Data()
            state = .meta(type: type, left: size, pad: TarFormat.padding(size))
            if size == 0 { finishMeta(type); state = .header }
            return
        default:
            break
        }
        var name = Self.string(bytes[0..<100])
        let magic = Self.string(bytes[257..<263])
        if magic.hasPrefix("ustar") {
            let prefix = Self.string(bytes[345..<500])
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        var link = Self.string(bytes[157..<257])
        if let n = longName { name = n }
        if let l = longLink { link = l }
        if let p = pax["path"] { name = p }
        if let l = pax["linkpath"] { link = l }
        var length = size
        if let s = pax["size"], let n = Int64(s), n >= 0 { length = n }
        let mtime = pax["mtime"].flatMap { Double($0) }.map { Int64($0) } ?? Self.number(bytes[136..<148]) ?? 0
        let mode = Int(Self.number(bytes[100..<108]) ?? 0o644)
        pax = [:]
        longName = nil
        longLink = nil
        let kind: TarEntry.Kind
        switch type {
        case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
            kind = name.hasSuffix("/") ? .directory : .file
        case UInt8(ascii: "5"): kind = .directory
        case UInt8(ascii: "2"): kind = .symlink(link)
        default: kind = .other
        }
        if name.hasSuffix("/") { name.removeLast() }
        // A directory, a link or anything else carries no bytes worth keeping; skip whatever it has.
        let carries = kind == .file
        try sink(.begin(TarEntry(path: name, kind: kind, size: length, mode: mode & 0o7777, mtime: mtime)))
        if length == 0 {
            if carries { try sink(.end) }
            state = .header
        } else {
            state = .content(left: length, pad: TarFormat.padding(length), hand: carries)
        }
    }

    private mutating func finishMeta(_ type: UInt8) {
        switch type {
        case UInt8(ascii: "x"):
            pax.merge(Self.records(meta)) { $1 }
        case UInt8(ascii: "L"):
            longName = Self.string(meta[meta.startIndex...])
        case UInt8(ascii: "K"):
            longLink = Self.string(meta[meta.startIndex...])
        default:
            // A global header (`g`) sets defaults for every later entry. Go never writes one,
            // and a path in it would name every entry the same: read past it.
            break
        }
        meta = Data()
    }

    /// `<length> <key>=<value>\n` records. A record that doesn't parse ends the reading.
    static func records(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        var i = data.startIndex
        while i < data.endIndex {
            guard let space = data[i...].firstIndex(of: 0x20),
                  let len = Int(String(decoding: data[i..<space], as: UTF8.self)), len > 0,
                  i + len <= data.endIndex else { break }
            let record = data[(space + 1)..<(i + len)]
            let body = record.last == 0x0A ? record.dropLast() : record
            if let eq = body.firstIndex(of: UInt8(ascii: "=")) {
                out[String(decoding: body[body.startIndex..<eq], as: UTF8.self)] = String(decoding: body[(eq + 1)...], as: UTF8.self)
            }
            i += len
        }
        return out
    }

    static func checksumMatches(_ b: [UInt8]) -> Bool {
        guard let want = number(b[148..<156]) else { return false }
        var unsigned = 0
        var signed = 0
        for (i, c) in b.enumerated() {
            let v = (148..<156).contains(i) ? 0x20 : c
            unsigned += Int(v)
            signed += Int(Int8(bitPattern: v))
        }
        return Int64(unsigned) == want || Int64(signed) == want
    }

    /// An octal field, or GNU's base-256 form (the high bit of the first byte set).
    static func number(_ field: ArraySlice<UInt8>) -> Int64? {
        if let first = field.first, first & 0x80 != 0 {
            var v: Int64 = Int64(first & 0x7F)
            for c in field.dropFirst() {
                guard v < (Int64.max >> 8) else { return nil }
                v = (v << 8) | Int64(c)
            }
            return v
        }
        let digits = field.prefix { $0 != 0 }.filter { $0 != 0x20 }
        if digits.isEmpty { return 0 }
        var v: Int64 = 0
        for c in digits {
            guard c >= 0x30, c <= 0x37, v < (Int64.max >> 3) else { return nil }
            v = v * 8 + Int64(c - 0x30)
        }
        return v
    }

    static func string<S: Collection>(_ field: S) -> String where S.Element == UInt8 {
        String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }
}
