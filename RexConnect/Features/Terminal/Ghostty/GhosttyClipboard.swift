import Foundation
import GhosttyVt
import UIKit

/// Clipboard writes from the program (OSC 52, and the other protocols libghostty-vt reports the
/// same way: iTerm2's OSC 1337 Copy and Kitty's OSC 5522) go to the iOS pasteboard.
///
/// The policy is the SwiftTerm engine's (`RexTerminalView.clipboardCopy`):
/// - Every destination (`c`, `p`, `s`) is the one iOS pasteboard.
/// - Only text that is valid UTF-8 is taken; anything else is dropped.
/// - An empty write empties the pasteboard's text.
/// - Nothing is shown and nothing is felt: a program copying is not the user copying.
/// - A read query (`OSC 52 ; c ; ?`) is never answered. No clipboard-read callback is installed,
///   and no write-pty callback either, so the terminal has no way to send a reply. The Rex
///   server's own terminal answers queries.
///
/// libghostty-vt decodes the base64 and applies its own size limit before the callback runs.
///
/// Threads: the callback runs inside `vt_write` on the feed queue with the terminal lock held,
/// so it only copies the text and leaves. A burst of writes becomes one hop to the main actor,
/// and the last write wins, as it would on the pasteboard.
///
/// `@unchecked Sendable`: every property is guarded by `lock`.
final class GhosttyClipboard: @unchecked Sendable {
    typealias Sink = @MainActor (String) -> Void

    private let lock = GhosttyLock()
    private var pending: String?
    private var scheduled = false
    private var sink: Sink = { UIPasteboard.general.string = $0 }
    private var delivered = 0

    /// Where the text goes. The pasteboard by default; tests put their own here.
    func setSink(_ sink: @escaping Sink) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    /// Hops to the main actor made so far. Tests use it to check that a burst is one hop.
    var deliveries: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    /// Takes the newest text. Any thread; never blocks on the main thread.
    func offer(_ text: String) {
        lock.lock()
        pending = text
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { DispatchQueue.main.async { self.flush() } }
    }

    @MainActor
    private func flush() {
        lock.lock()
        let text = pending
        let sink = sink
        pending = nil
        scheduled = false
        delivered += 1
        lock.unlock()
        if let text { sink(text) }
    }

    /// Handles one request inside the callback. `request` and everything it points to are only
    /// valid during the call.
    fileprivate func receive(_ request: UnsafePointer<GhosttyClipboardWrite>) {
        let write = request.pointee
        var result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
        if write.contents_len == 0 {
            // Upstream: no representations asks for the destination to be cleared.
            offer("")
        } else if let text = Self.text(write) {
            offer(text)
        } else {
            result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
        }
        // Upstream: answer before returning. OSC 52 has no acknowledgement and drops the reply;
        // one for OSC 5522 would go out through the write-pty callback, which isn't installed.
        var reply = GhosttyClipboardWriteReply()
        reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
        reply.result = result
        write.reply?(request, &reply)
    }

    /// The plain text among the representations, if it is valid UTF-8.
    private static func text(_ write: GhosttyClipboardWrite) -> String? {
        guard let contents = write.contents else { return nil }
        for i in 0..<write.contents_len {
            let content = contents[i]
            guard Self.isPlainText(content.mime) else { continue }
            guard let base = content.data.ptr, content.data.len > 0 else { return "" }
            return String(validating: UnsafeBufferPointer(start: base, count: content.data.len), as: UTF8.self)
        }
        return nil
    }

    private static func isPlainText(_ mime: GhosttyString) -> Bool {
        guard let base = mime.ptr else { return false }
        let name = String(decoding: UnsafeBufferPointer(start: base, count: mime.len), as: UTF8.self).lowercased()
        return name == "text/plain" || name.hasPrefix("text/plain;")
    }
}

extension GhosttyCore {
    /// Installs the clipboard-write callback. Called with exclusive access to `t`, whose userdata
    /// is this core.
    func installClipboard(_ t: GhosttyTerminal) {
        let write: GhosttyTerminalClipboardWriteFn = { _, userdata, request in
            guard let userdata, let request else { return }
            Unmanaged<GhosttyCore>.fromOpaque(userdata).takeUnretainedValue().clipboard.receive(request)
        }
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(write, to: UnsafeRawPointer.self))
    }
}
