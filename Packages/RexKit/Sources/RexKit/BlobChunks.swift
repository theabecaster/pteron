import Foundation

/// How much each `blob_read` of a screen read asks for: about `target` seconds at the rate the
/// last one had, between `floor` and `ceiling`.
///
/// One reply is one WebSocket message, and nothing counts as heard from the host until a whole
/// message is in: a pong waits behind it too. A reply of 900 KB on a slow link looked like
/// silence for longer than the watchdog and the pong deadline together, a live host was
/// dropped, and the reconnect ran the same read again. A reply of `floor` bytes arrives inside
/// those deadlines at the slowest rate the policy assumes (`ReconnectPolicy.slowestRate`), and
/// a keystroke's answer on the same connection waits behind at most one of them.
public struct BlobChunks: Sendable {
    public static let floor = 64 * 1024
    public static let ceiling = 256 * 1024
    public static let target = 0.1

    public private(set) var next = floor

    public init() {}

    public mutating func measured(bytes: Int, seconds: Double) {
        guard bytes > 0, seconds > 0 else { return }
        let size = Double(bytes) / seconds * Self.target
        next = Int(min(max(size, Double(Self.floor)), Double(Self.ceiling)))
    }

    /// Reads a blob from `offset` to its end, a chunk at a time, and returns it whole and in
    /// order. `chunk(offset, size)` is one `blob_read`: its reply's `data`, and `eof` at the end.
    /// A chunk that fails throws, and nothing read so far is returned: the caller has the whole
    /// blob or none of it. `now`: seconds on any monotonic clock.
    @MainActor
    public static func read(from start: Int, total: Int,
                            now: @MainActor () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 },
                            chunk: @MainActor (_ offset: Int, _ size: Int) async throws -> JSONObject) async throws -> String {
        var sizer = BlobChunks()
        var text = ""
        var offset = start
        // `data` can be shorter than asked (the size counts the encoded string), so the end is
        // the server's `eof` or an empty chunk; the count is only a bound.
        for _ in 0..<max(64, 4 * (max(0, total - start) / floor + 1)) {
            let began = now()
            let more = try await chunk(offset, sizer.next)
            let data = more.str("data") ?? ""
            text += data
            offset += data.utf8.count
            sizer.measured(bytes: data.utf8.count, seconds: now() - began)
            if more.bool("eof") == true || data.isEmpty { break }
        }
        return text
    }
}
