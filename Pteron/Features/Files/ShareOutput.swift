import Foundation
import GhosttyVt
import LinkPresentation
import RexKit
import SwiftUI
import UIKit

// Sharing a pane's output through the share sheet (docs/terminal.md, Share).
//
// Three scopes and two forms. The selection and the screen come from the pane's own terminal (the
// libghostty-vt formatter), so they work offline and on any server. All Output comes from the
// server (`terminal.format`, then `blob_read` with the same id), read in chunks sized to about
// 100 ms each, one request in flight, waiting while any pane on that server has typed input on its
// way. Nothing here runs until a Share item is chosen.

// MARK: - The HTML document

/// The styled share: one HTML document around the formatter's inline-styled fragment.
///
/// - The colors are always the phone's theme. Server HTML has no palette (`extra_palette` is
///   VT-only), so indexed colors would be undefined; the palette here is `!important`, so it also
///   beats the `<style>:root{…}` block the local formatter writes inside `<body>`. The wrapper's
///   inline default colors are overridden; inner runs keep their own, and RGB colors programs set
///   stay as they are.
/// - A Content Security Policy right after `<meta charset>` blocks scripts, `javascript:` URLs,
///   external loads, forms and `<base>`; links are also cleaned (`LinkSanitizer`).
/// - The font: the formatter's wrapper says `font-family: monospace` inline, which iOS draws in
///   Courier. The stylesheet's `!important` beats it. No `<pre>`: the wrapper already sets
///   `white-space: pre`.
/// - Inverse video: the formatter writes `filter: invert(100%)` on the run and no background, so
///   only the text would flip, to a color near the page's. The run gets the theme's background,
///   which the filter flips with it; a run with its own background keeps that (inline wins).
enum ShareHTML {
    static let tail = "</body></html>\n"

    static func head(title: String, theme: TermTheme) -> String {
        let bg = css(UIColor(hex: theme.background)), fg = css(UIColor(hex: theme.foreground))
        var palette = ""
        palette.reserveCapacity(256 * 36)
        for (i, c) in self.palette(theme).enumerated() { palette += "--vt-palette-\(i):\(c) !important;" }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
        <meta name="viewport" content="width=device-width">
        <title>\(escape(title))</title>
        <style>
        :root{\(palette)}
        html,body{margin:0;background:\(bg);color:\(fg)}
        body{padding:16px}
        body > div{background:\(bg) !important;color:\(fg) !important}
        div[style*="invert(100%)"]{background-color:\(bg)}
        div{font-family:ui-monospace,Menlo,monospace !important;font-size:12px;line-height:1.25}
        a{color:inherit}
        </style></head><body>
        """
    }

    /// The 256 colors as the pane draws them: the theme's 16, then Ghostty's defaults.
    static func palette(_ theme: TermTheme) -> [String] {
        var rgb = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 0, g: 0, b: 0), count: 256)
        rgb.withUnsafeMutableBufferPointer { ghostty_color_palette_default($0.baseAddress) }
        var out = rgb.map { String(format: "#%02x%02x%02x", $0.r, $0.g, $0.b) }
        for (i, hex) in theme.ansi.prefix(16).enumerated() { out[i] = css(UIColor(hex: hex)) }
        return out
    }

    /// `#rrggbb` from sRGB components clamped to 0...1, so an extended-range color can't make
    /// invalid CSS.
    static func css(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v.isFinite ? v : 0, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&": out += "&amp;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// A whole document for a fragment that is already in hand (the screen).
    static func document(title: String, theme: TermTheme, fragment: String) -> String {
        var s = LinkSanitizer()
        return head(title: title, theme: theme) + s.feed(fragment) + s.finish() + tail
    }
}

// MARK: - Links

/// Keeps a link's `href` only when it is `http:`, `https:` or `mailto:`, the way a browser would
/// read it: entities decoded once, tabs and line breaks removed anywhere, C0 controls and spaces
/// trimmed at the ends, case ignored. Anything else loses the attribute and keeps its text, so a
/// miss fails safe; the document's CSP is the backstop.
///
/// Streaming: chunks may split a tag anywhere. The formatter escapes `<` and `>` in text and in
/// attributes, so a `<` with no `>` after it starts a tag that isn't finished: it is held back
/// for the next chunk, and a held tag keeps its entities whole.
struct LinkSanitizer {
    private var carry: [UInt8] = []

    /// The clean part of `chunk` that is complete, holding back an unfinished tag.
    mutating func feed(_ chunk: String) -> String {
        var bytes = carry
        bytes.append(contentsOf: chunk.utf8)
        carry = []
        if let lt = bytes.lastIndex(of: UInt8(ascii: "<")), !bytes[lt...].contains(UInt8(ascii: ">")) {
            carry = Array(bytes[lt...])
            bytes.removeSubrange(lt...)
        }
        return String(decoding: Self.clean(bytes), as: UTF8.self)
    }

    /// The end of the output. A tag that never closed is dropped: a browser drops it too.
    mutating func finish() -> String {
        carry = []
        return ""
    }

    static func clean(_ bytes: [UInt8]) -> [UInt8] {
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
        guard bytes.contains(lt) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard let open = bytes[i...].firstIndex(of: lt) else {
                out.append(contentsOf: bytes[i...])
                break
            }
            out.append(contentsOf: bytes[i..<open])
            guard let close = bytes[open...].firstIndex(of: gt) else {
                out.append(contentsOf: bytes[open...])
                break
            }
            appendTag(bytes[open...close], to: &out)
            i = close + 1
        }
        return out
    }

    /// One tag, `<` to `>`, with every `href` that isn't allowed left out.
    private static func appendTag(_ tag: ArraySlice<UInt8>, to out: inout [UInt8]) {
        guard hasHref(tag) else { return out.append(contentsOf: tag) }
        let slash = UInt8(ascii: "/")
        var i = tag.startIndex + 1
        let end = tag.endIndex - 1  // the `>`
        // The tag's name. A browser ends it at a space or a `/`, as it does an attribute.
        if i < end, tag[i] == slash { i += 1 }
        while i < end, !isSpace(tag[i]), tag[i] != slash { i += 1 }
        out.append(contentsOf: tag[tag.startIndex..<i])
        while i < end {
            // Spaces before an attribute go with it, so a removed attribute leaves none behind.
            let lead = i
            while i < end, isSpace(tag[i]) || tag[i] == slash { i += 1 }
            let nameStart = i
            while i < end, !isSpace(tag[i]), tag[i] != UInt8(ascii: "="), tag[i] != slash { i += 1 }
            let name = tag[nameStart..<i]
            var j = i
            while j < end, isSpace(tag[j]) { j += 1 }
            var value: ArraySlice<UInt8>?
            if j < end, tag[j] == UInt8(ascii: "=") {
                j += 1
                while j < end, isSpace(tag[j]) { j += 1 }
                if j < end, tag[j] == UInt8(ascii: "\"") || tag[j] == UInt8(ascii: "'") {
                    let q = tag[j]
                    let vStart = j + 1
                    var k = vStart
                    while k < end, tag[k] != q { k += 1 }
                    value = tag[vStart..<k]
                    j = min(k + 1, end)
                } else {
                    let vStart = j
                    while j < end, !isSpace(tag[j]) { j += 1 }
                    value = tag[vStart..<j]
                }
                i = j
            }
            if name.isEmpty, i == nameStart {
                // Nothing parsable left (a stray `/`): keep the rest as it is.
                out.append(contentsOf: tag[lead..<end])
                break
            }
            if isHref(name), !keeps(value.map { String(decoding: $0, as: UTF8.self) } ?? "") { continue }
            out.append(contentsOf: tag[lead..<i])
        }
        out.append(tag[end])
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D }

    private static func hasHref(_ tag: ArraySlice<UInt8>) -> Bool {
        let h: [UInt8] = Array("href".utf8)
        guard tag.count >= 6 else { return false }
        var i = tag.startIndex
        while i + 4 <= tag.endIndex {
            if (0..<4).allSatisfy({ tag[i + $0] | 0x20 == h[$0] }) { return true }
            i += 1
        }
        return false
    }

    private static func isHref(_ name: ArraySlice<UInt8>) -> Bool {
        name.count == 4 && zip(name, "href".utf8).allSatisfy { $0 | 0x20 == $1 }
    }

    /// Whether an `href` value (as written in the tag) is a link to keep.
    static func keeps(_ raw: String) -> Bool {
        var s = String(String.UnicodeScalarView(decodeEntities(raw).unicodeScalars.filter { !["\t", "\n", "\r"].contains($0) }))
        let edge: (Unicode.Scalar) -> Bool = { $0.value <= 0x20 }
        while let f = s.unicodeScalars.first, edge(f) { s.unicodeScalars.removeFirst() }
        while let l = s.unicodeScalars.last, edge(l) { s.unicodeScalars.removeLast() }
        let lower = s.lowercased()
        return lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("mailto:")
    }

    /// Character references decoded once, as in an attribute value: numeric ones (with or without
    /// the `;`) and the five the formatter writes. Others stay as written, which can only make a
    /// value look less like an allowed scheme.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
        var out = String.UnicodeScalarView()
        let u = Array(s.unicodeScalars)
        var i = 0
        while i < u.count {
            guard u[i] == "&" else { out.append(u[i]); i += 1; continue }
            var j = i + 1
            if j < u.count, u[j] == "#" {
                j += 1
                let hex = j < u.count && (u[j] == "x" || u[j] == "X")
                if hex { j += 1 }
                let start = j
                var value: UInt32 = 0
                while j < u.count, let d = Self.digit(u[j], hex: hex) {
                    value = min(value &* (hex ? 16 : 10) &+ d, 0x110000)
                    j += 1
                }
                if j > start {
                    if j < u.count, u[j] == ";" { j += 1 }
                    out.append(Unicode.Scalar(value) ?? "\u{FFFD}")
                    i = j
                    continue
                }
            } else {
                var name = ""
                while j < u.count, u[j].properties.isAlphabetic || ("0"..."9").contains(u[j]) {
                    name.unicodeScalars.append(u[j])
                    j += 1
                }
                if j < u.count, u[j] == ";", let v = named[name] {
                    out.append(contentsOf: v.unicodeScalars)
                    i = j + 1
                    continue
                }
            }
            out.append(u[i])
            i += 1
        }
        return String(out)
    }

    private static func digit(_ c: Unicode.Scalar, hex: Bool) -> UInt32? {
        switch c {
        case "0"..."9": return c.value - 48
        case "a"..."f" where hex: return c.value - 87
        case "A"..."F" where hex: return c.value - 55
        default: return nil
        }
    }
}

// MARK: - Chunks

/// How much each All Output request asks for: about `target` seconds at the throughput the last
/// request had, between `floor` and `ceiling`. A keystroke's reply on the same connection waits
/// behind at most one such request.
struct ChunkSizer {
    static let floor = 64 * 1024
    static let ceiling = 256 * 1024
    static let target = 0.1

    private(set) var next = floor

    mutating func measured(bytes: Int, seconds: Double) {
        guard bytes > 0, seconds > 0 else { return }
        let size = Double(bytes) / seconds * Self.target
        next = Int(min(max(size, Double(Self.floor)), Double(Self.ceiling)))
    }
}

/// The newest `limit` bytes of plain text, cut at a line.
enum TextCap {
    static let limit = 32 << 20

    /// Where to start reading a text of `total` bytes.
    static func start(total: Int, limit: Int = limit) -> Int { max(0, total - limit) }

    /// The first chunk read from a cut: the server sends one U+FFFD for each byte of a character
    /// the cut went through (`replaced`), then whole characters. The text starts after the first
    /// line break, or, without one, at the first whole character. `dropped` counts the server's
    /// bytes left out.
    static func trimStart(_ chunk: String) -> (text: Substring, dropped: Int, replaced: Int) {
        var replaced = 0
        var rest = chunk[...]
        while replaced < 3, rest.unicodeScalars.first == "\u{FFFD}" {
            rest = rest.dropFirst()
            replaced += 1
        }
        if let nl = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: nl)...] }
        let dropped = chunk.utf8.count - 2 * replaced - rest.utf8.count
        return (rest, dropped, replaced)
    }

    static func marker(skipped bytes: Int) -> String {
        "[Earlier output not included: \(SendTarget.size(Int64(bytes)))]\n"
    }
}

// MARK: - Reading All Output

/// The calls a read needs; `ServerConnection` in the app, a fake in tests.
@MainActor
protocol OutputSource: AnyObject {
    /// Counts connections: a read stops when it changes (`ServerConnection.connectionSerial`).
    var connectionSerial: Int { get }
    /// The connection is up now.
    var outputConnected: Bool { get }
    func outputCall(_ method: String, session: String, block: String, args: JSONObject) async throws -> JSONObject
    /// Returns once no pane on this server has typed input on its way, or the connection is down.
    func inputIdle() async
}

enum OutputForm: Equatable, Sendable {
    case text, html
}

/// Why a read ended without the output.
enum OutputReadFailure: Error, Equatable {
    case cancelled
    /// The connection dropped or was made again under the read.
    case connection
    /// `not_found` twice: the result was evicted twice, or the pane closed.
    case notFound
    /// The server has no such method (`method_not_found`, `revision_too_low`).
    case unsupported(String)
    /// Styled output over `OutputReader.styledLimit`.
    case styledTooLarge
    /// Large output on an expensive network, and the user said no.
    case declined
    case refused
}

/// One All Output read: `terminal.format` with the first chunk, then `blob_read` with the same id
/// until the end, in adaptive chunks, one request in flight, each after the server's typed input
/// has gone out. A `not_found` (a concurrent `format` evicted the id, or it expired) starts over
/// once with a new `format`. A new connection ends the read: the id belongs to the old one.
@MainActor
final class OutputReader {
    static let format = "com.superlogical.terminal.format"
    static let blobRead = "com.superlogical.terminal.blob_read"
    /// Styled output above this is refused before it is read: inline-styled HTML that large
    /// stalls Quick Look and Safari on a phone.
    static let styledLimit = 8 << 20
    /// Above this, on an expensive network, `confirm` is asked first.
    static let expensiveLimit = Int(SendTarget.expensiveLimit)

    var textLimit = TextCap.limit
    var styledLimit = OutputReader.styledLimit
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private(set) var sizer = ChunkSizer()

    /// Start over: forget what was written.
    var reset: () -> Void = {}
    var write: (String) -> Void = { _ in }
    /// The read needs more than one chunk; then its progress, 0...1.
    var progress: (Double) -> Void = { _ in }
    /// Asked once, with the bytes to read, when they pass `expensiveLimit`. False stops the read.
    var confirm: (Int) async -> Bool = { _ in true }

    func read(_ form: OutputForm, session: String, block: String, from source: OutputSource) async throws(OutputReadFailure) {
        let serial = source.connectionSerial
        var tries = 0
        while true {
            do {
                try await readOnce(form, session: session, block: block, from: source, serial: serial)
                return
            } catch .notFound where tries == 0 {
                tries += 1
                sizer = ChunkSizer()
                reset()
            }
        }
    }

    private func readOnce(_ form: OutputForm, session: String, block: String, from source: OutputSource,
                          serial: Int) async throws(OutputReadFailure) {
        var args: JSONObject = form == .text ? ["format": "text", "trim": true, "unwrap": true] : ["format": "html"]
        args["max_bytes"] = sizer.next
        let firstBegan = clock()
        let first = try await call(Self.format, args, session, block, source, serial)
        let content = first.str("content") ?? ""
        sizer.measured(bytes: content.utf8.count, seconds: clock() - firstBegan)
        // A reply without an id holds the whole output (older servers send no `eof`).
        guard let id = first.int("id") else { return write(content) }
        var offset = content.utf8.count
        var total = first.int("total")
        var start = 0
        var asked = false
        var cut = false
        /// Applies a total once it is known. True if the read now starts at the cut.
        func apply(_ t: Int) async throws(OutputReadFailure) -> Bool {
            if form == .html, t > styledLimit { throw .styledTooLarge }
            let toRead = form == .text ? min(t, textLimit) : t
            if !asked, toRead > Self.expensiveLimit {
                asked = true
                guard await confirm(toRead) else { throw .declined }
                try check(source, serial)
            }
            guard form == .text, t > textLimit else { return false }
            start = TextCap.start(total: t, limit: textLimit)
            return true
        }
        if let t = total, try await apply(t) {
            cut = true
            offset = start
        } else {
            write(content)
        }
        var read = cut ? 0 : offset
        while true {
            let began = clock()
            let r = try await call(Self.blobRead, ["id": id, "offset": offset, "max_bytes": sizer.next], session, block, source, serial)
            let data = r.str("data") ?? ""
            let bytes = data.utf8.count
            sizer.measured(bytes: bytes, seconds: clock() - began)
            if total == nil, let t = r.int("total") {
                total = t
                if try await apply(t) {
                    // The cut is known only now: what was read from the start goes.
                    reset()
                    cut = true
                    offset = start
                    read = 0
                    continue
                }
            }
            var advance = bytes
            if cut {
                cut = false
                let (text, dropped, replaced) = TextCap.trimStart(data)
                advance = bytes - 2 * replaced
                write(TextCap.marker(skipped: offset + dropped))
                write(String(text))
            } else {
                write(data)
            }
            offset += advance
            read += advance
            if let t = total, t > start {
                progress(min(1, Double(offset - start) / Double(t - start)))
            } else {
                // No total at all: the limits apply to what was read.
                if form == .html, read > styledLimit { throw .styledTooLarge }
                if !asked, read > Self.expensiveLimit {
                    asked = true
                    guard await confirm(read) else { throw .declined }
                    try check(source, serial)
                }
                if form == .text, read >= textLimit { return }
            }
            if r.bool("eof") == true || data.isEmpty { return }
            if let t = total, offset >= t { return }
        }
    }

    /// One request, after the server's typed input has gone out, checked against the connection
    /// it started on.
    private func call(_ method: String, _ args: JSONObject, _ session: String, _ block: String,
                      _ source: OutputSource, _ serial: Int) async throws(OutputReadFailure) -> JSONObject {
        try check(source, serial)
        await source.inputIdle()
        try check(source, serial)
        let reply: JSONObject
        do {
            reply = try await source.outputCall(method, session: session, block: block, args: args)
        } catch let e as RexError {
            try check(source, serial)
            switch e.code {
            case "method_not_found", "revision_too_low": throw .unsupported(method)
            case "not_found": throw .notFound
            case "client": throw .connection
            default: throw e.neverSent ? .connection : .refused
            }
        } catch {
            try check(source, serial)
            throw .connection
        }
        try check(source, serial)
        return reply
    }

    private func check(_ source: OutputSource, _ serial: Int) throws(OutputReadFailure) {
        if Task.isCancelled { throw .cancelled }
        // Down, the id dies with this connection; typed input waits for the next one.
        if source.connectionSerial != serial || !source.outputConnected { throw .connection }
    }
}

// MARK: - The file

/// A share's file, written off the main thread: each chunk goes to `queue`, which runs the link
/// sanitizer (HTML), the UTF-8 conversion and the write. At most a chunk or two wait there.
final class ShareFile: @unchecked Sendable {
    // `@unchecked`: `handle`, `sanitizer`, `bytes` and `failed` are only touched on `queue`.
    let url: URL
    private let html: (head: String, tail: String)?
    private let queue = DispatchQueue(label: "dev.abrahamgonzalez.rexduo.share-file")
    private var handle: FileHandle?
    private var sanitizer = LinkSanitizer()
    private var bytes = 0
    private var failed = false

    /// `html`: the document's head and tail around the fragments.
    init(url: URL, html: (head: String, tail: String)? = nil) {
        self.url = url
        self.html = html
        queue.async { self.open() }
    }

    private func open() {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        if handle == nil { failed = true }
        bytes = 0
        sanitizer = LinkSanitizer()
        if let html { put(html.head) }
    }

    private func put(_ s: String) {
        guard !failed, let handle, !s.isEmpty else { return }
        let data = Data(s.utf8)
        do {
            try handle.write(contentsOf: data)
            bytes += data.count
        } catch {
            failed = true
        }
    }

    func write(_ s: String) {
        queue.async {
            self.put(self.html == nil ? s : self.sanitizer.feed(s))
        }
    }

    /// Starts the file over.
    func reset() {
        queue.async {
            try? self.handle?.close()
            self.handle = nil
            self.open()
        }
    }

    /// Writes what is left and closes the file. The file's size, or nil if a write failed.
    func finish() async -> Int? {
        await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
            queue.async {
                if let html = self.html {
                    self.put(self.sanitizer.finish())
                    self.put(html.tail)
                }
                try? self.handle?.close()
                self.handle = nil
                c.resume(returning: self.failed ? nil : self.bytes)
            }
        }
    }

    /// Stops writing: what comes after is dropped.
    func abandon() {
        queue.async {
            try? self.handle?.close()
            self.handle = nil
            self.failed = true
        }
    }
}

// MARK: - Where the sheet points

/// Where the share sheet comes from. It is a popover wherever the system makes it one (an iPad,
/// `-simulateDuo`), and a popover needs a source, so one is always set.
enum ShareAnchor: Equatable {
    /// The selection's edit menu: at the menu's target, in the engine view.
    case selection(CGRect?)
    /// The pane menu in the title bar, above the pane's top-trailing corner.
    case titleBar
    /// The pane menu in the system's vertical bar, on that edge.
    case bar(HorizontalEdge)

    struct Placement: Equatable {
        var view: UIView
        var rect: CGRect
        var arrows: UIPopoverArrowDirection
    }

    /// The source for a pane (`host`, its engine view `term`) in `window`.
    @MainActor
    func place(host: UIView, term: UIView, window: UIView) -> Placement {
        switch self {
        case .selection(let rect):
            if let rect, !rect.isNull, !rect.isEmpty || rect.origin != .zero { return Placement(view: term, rect: rect, arrows: .any) }
            return Placement(view: host, rect: host.bounds, arrows: .any)
        case .titleBar:
            let f = host.convert(host.bounds, to: window)
            let rtl = window.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let x = rtl ? f.minX : f.maxX - 44
            return Placement(view: window, rect: CGRect(x: x, y: f.minY - 1, width: 44, height: 1), arrows: .any)
        case .bar(let edge):
            let rtl = window.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let left = (edge == .leading) != rtl
            let b = window.bounds
            return Placement(view: window, rect: CGRect(x: left ? b.minX : b.maxX - 1, y: b.midY, width: 1, height: 1),
                             arrows: left ? .left : .right)
        }
    }
}

// MARK: - The item

/// What the share sheet gets: text, or a file, with the tab's title as subject and header. Not
/// main-actor bound: the sheet may ask from its own threads, and everything here is immutable.
final class ShareItem: NSObject, UIActivityItemSource {
    enum Payload: Sendable {
        case text(String)
        case file(URL)
    }

    let payload: Payload
    let subject: String

    init(_ payload: Payload, subject: String) {
        self.payload = payload
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        switch payload {
        case .text: return ""
        case .file(let url): return url
        }
    }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        switch payload {
        case .text(let s): return s
        case .file(let url): return url
        }
    }

    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String {
        subject
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let m = LPLinkMetadata()
        m.title = subject
        if case .file(let url) = payload { m.originalURL = url }
        if let icon = UIImage(systemName: "terminal") { m.iconProvider = NSItemProvider(object: icon) }
        return m
    }
}

// MARK: - One pane's shares

/// Sharing from one pane: the selection (edit menu) and Share ▸ in the pane menu.
@MainActor
final class PaneShare {
    enum Scope: Equatable { case screen, allOutput }

    /// Up to this many UTF-8 bytes, plain text is shared as text; above, as a `.txt` file.
    static let textLimit = 256 * 1024

    let server: ServerConnection
    let sessionID: String
    let blockID: String
    weak var host: TerminalHost?

    init(server: ServerConnection, sessionID: String, blockID: String) {
        self.server = server
        self.sessionID = sessionID
        self.blockID = blockID
    }

    /// The tab's title as the title bar shows it, else "Terminal".
    var title: String {
        guard let w = server.views[sessionID]?.windowContaining(block: blockID) else { return "Terminal" }
        let t = WindowTitle.of(w, server: server).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Terminal" : t
    }

    /// The pane still exists on its server.
    var paneExists: Bool { server.views[sessionID]?.windowContaining(block: blockID) != nil }

    /// `<Tab title> <yyyy-MM-dd HH.mm>.<ext>`, sanitized.
    static func fileName(title: String, date: Date = Date(), ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let base = UploadName.sanitize(title, fallback: "Terminal")
        return UploadName.sanitize("\(base) \(f.string(from: date)).\(ext)", fallback: "Terminal.\(ext)")
    }

    // MARK: Selection

    /// The selection as plain text. Formatted at once, as Copy takes it, so a tap that clears or
    /// moves the selection before a later turn can't change what is shared; the selection is
    /// cleared once the sheet is up (`presented`).
    func shareSelection(at rect: CGRect?, presented: @escaping @MainActor () -> Void) {
        guard let host else { return }
        let text = host.term.core.format(scope: .selection, emit: .plain)
        guard let text, !text.isEmpty else { return Notice.shared.show("Nothing to share.", style: .neutral) }
        let subject = title
        Task { @MainActor in
            await self.present(plain: text, subject: subject, anchor: .selection(rect), presented: presented)
        }
    }

    // MARK: Pane menu

    func share(_ scope: Scope, styled: Bool, anchor: ShareAnchor) {
        switch scope {
        case .screen: shareScreen(styled: styled, anchor: anchor)
        case .allOutput: shareAllOutput(styled: styled, anchor: anchor)
        }
    }

    private func shareScreen(styled: Bool, anchor: ShareAnchor) {
        guard let host else { return }
        let core = host.term.core
        let theme = host.theme
        let subject = title
        Task { @MainActor in
            let (plain, html, head) = await Task.detached(priority: .userInitiated) { () -> (String?, String?, String?) in
                let plain = core.format(scope: .viewport, emit: .plain)
                guard styled, plain?.isEmpty == false else { return (plain, nil, nil) }
                return (plain, core.format(scope: .viewport, emit: .html), ShareHTML.head(title: subject, theme: theme))
            }.value
            guard let plain, !plain.isEmpty else { return Notice.shared.show("Nothing to share.", style: .neutral) }
            if styled {
                guard let html, let head else { return Notice.shared.show("Couldn't share the screen.") }
                await self.present(file: html, ext: "html", html: (head, ShareHTML.tail), subject: subject, anchor: anchor)
            } else {
                await self.present(plain: plain, subject: subject, anchor: anchor)
            }
        }
    }

    private func shareAllOutput(styled: Bool, anchor: ShareAnchor) {
        guard server.phase == .online else {
            return Notice.shared.show(Messages.offline(server.config.name), style: .neutral)
        }
        let job = OutputShare(pane: self, styled: styled, anchor: anchor)
        job.start()
    }

    // MARK: Presenting

    private func present(plain text: String, subject: String, anchor: ShareAnchor,
                         presented: (@MainActor () -> Void)? = nil) async {
        if text.utf8.count <= Self.textLimit {
            present(ShareItem(.text(text), subject: subject), folder: nil, anchor: anchor, presented: presented)
        } else {
            await present(file: text, ext: "txt", subject: subject, anchor: anchor, presented: presented)
        }
    }

    /// Writes `contents` to a file of its own through `ShareFile`, off the main thread (with
    /// `html`, as a document around it, links cleaned), then shows the sheet.
    func present(file contents: String, ext: String, html: (head: String, tail: String)? = nil, subject: String,
                 anchor: ShareAnchor, presented: (@MainActor () -> Void)? = nil) async {
        guard let folder = try? FileStaging.folder(in: FileStaging.shared) else {
            return Notice.shared.show("Couldn't share the output.")
        }
        let url = folder.appendingPathComponent(Self.fileName(title: subject, ext: ext))
        let file = ShareFile(url: url, html: html)
        file.write(contents)
        guard await file.finish() != nil else {
            FileStaging.remove(folder)
            return Notice.shared.show("Couldn't share the output.")
        }
        present(ShareItem(.file(url), subject: subject), folder: folder, anchor: anchor, presented: presented)
    }

    /// Shows the share sheet over the topmost controller. The folder goes when the sheet does.
    func present(_ item: ShareItem, folder: URL?, anchor: ShareAnchor, presented: (@MainActor () -> Void)? = nil) {
        guard let host, let window = host.window, var top = window.rootViewController else {
            if let folder { FileStaging.remove(folder) }
            return
        }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            if let folder { FileStaging.remove(folder) }
        }
        let place = anchor.place(host: host, term: host.term, window: window)
        #if DEBUG
        ShareTest.log(item)
        #endif
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = place.view
            pop.sourceRect = place.rect
            pop.permittedArrowDirections = place.arrows
        }
        top.present(sheet, animated: true) { presented?() }
    }
}

// MARK: - One All Output share

/// An All Output read from start to sheet: it waits for the notice's job lane, reads inside a
/// background task, writes a file in its own folder and presents the sheet. Cancel, a lost
/// connection, a failure or the end of background time delete the folder and clear the lane.
@MainActor
final class OutputShare {
    private weak var pane: PaneShare?
    private let server: ServerConnection
    private let sessionID: String
    private let blockID: String
    private let styled: Bool
    private let anchor: ShareAnchor
    private let subject: String
    private let theme: TermTheme?
    private(set) var task: Task<Void, Never>?
    private var expired = false
    /// While the read runs.
    private(set) var background: BackgroundTask?
    /// The share's own folder under `FileStaging.shared`, while it exists.
    private(set) var folder: URL?
    /// Calls for the read; the pane's server unless a test puts a fake here.
    var source: OutputSource
    let reader = OutputReader()
    /// Shows the sheet; the pane's `present` unless a test looks instead.
    var present: ((ShareItem, URL?) -> Void)?

    init(pane: PaneShare, styled: Bool, anchor: ShareAnchor) {
        self.pane = pane
        server = pane.server
        sessionID = pane.sessionID
        blockID = pane.blockID
        self.styled = styled
        self.anchor = anchor
        subject = pane.title
        theme = pane.host?.theme
        source = pane.server
    }

    func start() {
        task = Task { @MainActor in await self.run() }
    }

    func cancel() { task?.cancel() }

    /// The background time ran out: the read stops, the folder goes, and no sheet follows.
    func backgroundExpired() {
        expired = true
        cancel()
    }

    private static func percent(_ f: Double) -> String { "Reading the output · \(Int(f * 100))%" }

    private func discard() {
        if let folder { FileStaging.remove(folder) }
        folder = nil
    }

    private func run() async {
        guard let job = await Notice.shared.beginJob(text: Self.percent(0), cancel: { [weak self] in self?.cancel() }) else { return }
        background = BackgroundTask(name: "Share output") { [weak self] in self?.backgroundExpired() }
        defer {
            Notice.shared.endJob(job)
            background?.end()
            background = nil
        }
        let url: URL
        do {
            let dir = try FileStaging.folder(in: FileStaging.shared)
            folder = dir
            url = dir.appendingPathComponent(PaneShare.fileName(title: subject, ext: styled ? "html" : "txt"))
        } catch {
            return Notice.shared.show("Couldn't share the output.")
        }
        let html = styled ? (head: ShareHTML.head(title: subject, theme: theme ?? ThemeStore.fallback), tail: ShareHTML.tail) : nil
        let file = ShareFile(url: url, html: html)
        reader.reset = { file.reset() }
        reader.write = { file.write($0) }
        reader.progress = { Notice.shared.progress(job, fraction: $0, text: Self.percent($0)) }
        reader.confirm = { [weak self] bytes in await self?.confirm(bytes) ?? false }
        do {
            try await server.formatChunks(sessionID, blockID, form: styled ? .html : .text, reader: reader, from: source)
        } catch {
            file.abandon()
            _ = await file.finish()
            discard()
            return failed(expired ? .cancelled : error)
        }
        let size = await file.finish()
        guard !Task.isCancelled else { return discard() }
        guard let size else {
            discard()
            return Notice.shared.show("Couldn't read the output.", action: retry)
        }
        guard size > (html.map { $0.head.utf8.count + $0.tail.utf8.count } ?? 0) else {
            discard()
            return Notice.shared.show("Nothing to share.", style: .neutral)
        }
        Notice.shared.endJob(job)
        background?.end()
        // Finished in the background: the sheet waits for the return, if the pane is still there.
        if UIApplication.shared.applicationState == .background {
            await Self.becameActive()
            guard paneExists, !expired, !Task.isCancelled else { return discard() }
        }
        let item: ShareItem
        if !styled, size <= PaneShare.textLimit, let text = try? String(contentsOf: url, encoding: .utf8) {
            discard()
            item = ShareItem(.text(text), subject: subject)
        } else {
            item = ShareItem(.file(url), subject: subject)
        }
        if let present {
            present(item, folder)
        } else if let pane {
            pane.present(item, folder: folder, anchor: anchor)
        } else {
            discard()
        }
        // The sheet owns the folder now: it goes when the sheet does.
        folder = nil
    }

    private var paneExists: Bool { server.views[sessionID]?.windowContaining(block: blockID) != nil }

    private var retry: Notice.Action {
        Notice.Action(title: "Try Again") { [weak pane, styled, anchor] in pane?.share(.allOutput, styled: styled, anchor: anchor) }
    }

    private func failed(_ error: OutputReadFailure) {
        switch error {
        case .cancelled, .declined:
            break
        case .styledTooLarge:
            Notice.shared.show("Too much output to share with colors.", style: .neutral,
                               action: Notice.Action(title: "Share as Plain Text") { [weak pane, anchor] in
                                   pane?.share(.allOutput, styled: false, anchor: anchor)
                               })
        case .unsupported(let method):
            // The creator list vouched for it, the server didn't: the rows go for this connection.
            let host = server.views[sessionID]?.windowContaining(block: blockID)?.block(blockID)?.hostID
            server.capabilities.record(method: method, host: host, .absent, serial: server.connectionSerial)
            Notice.shared.show("Couldn't read the output.")
        case .connection, .notFound, .refused:
            if paneExists {
                Notice.shared.show("Couldn't read the output.", action: retry)
            } else {
                Notice.shared.show(Messages.paneClosed, style: .neutral)
            }
        }
    }

    /// On an expensive network, asks before reading `bytes`.
    private func confirm(_ bytes: Int) async -> Bool {
        guard await FileStaging.networkIsExpensive() else { return true }
        guard let view = pane?.host else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            TerminalPrompt.ask(over: view, title: "Download \(SendTarget.size(Int64(bytes))) on cellular?",
                               message: "All of the pane's output, to share.", confirm: "Download") { c.resume(returning: $0) }
        }
    }

    private static func becameActive() async {
        let center = NotificationCenter.default
        for await _ in center.notifications(named: UIApplication.didBecomeActiveNotification) { return }
    }
}
