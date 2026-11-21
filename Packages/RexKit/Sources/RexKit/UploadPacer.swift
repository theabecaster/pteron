import Foundation

/// How fast a file's bytes are handed to its socket, from how long the control connection takes to
/// answer a ping while they go.
///
/// A WebSocket's `send` returns once the system has taken the bytes, not once they have left, so a
/// loop of sends puts megabytes of a file in the phone's buffers within moments. On a slow uplink
/// those bytes then sit in one queue with everything else the phone sends: the control
/// connection's pings and calls, and the keys typed into a pane, wait behind them for as long as
/// the file takes. Measured through a 1 to 2 Mbit/s uplink, a 7.5 MB file held a control ping for
/// 2 to 10 s, and coming back to the app meanwhile made its 2.5 s wake pings fail: the terminal
/// stream and the control connection were taken for dead, made again behind the same queue (the
/// offline screen for 10 s), and the batch was sent again from the start.
///
/// So a file yields to other traffic, as a delay-based congestion control does (LEDBAT, RFC 6817).
/// Just before a message a ping goes out on the control connection (one at a time, at most every
/// `UploadPacer.probeEvery`), and its round trip, less the shortest one seen, is the queue in front
/// of everything else. Under half of `target` (`queueLimit`), and not growing, the rate doubles,
/// or grows by a quarter once a queue has formed, so it stays near what the link takes. Past
/// it, and not shrinking, it halves; a queue that is already draining is left to drain. Each
/// message is about `target` of the rate, so on a slow uplink a key or a call waits behind about
/// that much of the file. On a fast network the rate is soon past what the network takes and the
/// file goes at full speed.
///
/// The queue is also held under `maxQueuedBytes` (256 KiB): on a fast link 100 ms is megabytes,
/// and on an iPhone those bytes queue as packets inside the Tailscale network extension, which iOS
/// kills when it passes about 50 MB of memory; the tunnel then comes back 30 to 60 s later
/// (tailscale/tailscale#17967). The phone never hands the network a burst: one message at a time,
/// at most 64 KiB, at the paced rate.
///
/// The upload's own socket can't measure this, nor confirm bytes: Rex answers a ping on it only
/// once the file has ended (probed on revision 18), and sends nothing else until its close.
struct UploadRate: Equatable {
    /// The queueing the rate aims under.
    var target: Duration = .milliseconds(100)
    /// The most of the file the queue may hold, whatever the rate.
    var maxQueuedBytes: Double = 262_144
    /// Bytes per second. 32 KB/s still moves a photo in a few minutes on the worst link.
    var minRate: Double = 32_768
    var maxRate: Double = 1_073_741_824
    /// The smallest message: smaller ones cost more in headers than they save in waiting.
    var minMessage = 8_192
    /// Where a file starts: 5 Mbit/s, under most uplinks a phone has; a 64 KiB message per `target`.
    var rate: Double = 655_360
    /// The shortest round trip seen: the time with nothing queued.
    private(set) var base: Duration?
    /// The queue the last answer, or late ping, showed.
    private(set) var lastQueued: Duration = .zero
    /// A queue has formed: the rate grows slowly from now on.
    private(set) var congested = false

    /// A ping that left just before a message came back after `rtt`.
    mutating func answered(rtt: Duration) {
        let base = min(self.base ?? rtt, rtt)
        self.base = base
        let queued = rtt - base
        let limit = queueLimit
        if queued > limit {
            // Still over: halve, unless it is draining already (a tenth shorter than last time).
            if queued * 10 >= lastQueued * 9 { slower() }
        } else if queued - lastQueued > limit / 10 {
            // Under the limit but growing: the rate is past what the link takes. Hold.
            congested = true
        } else if queued * 2 < limit {
            rate = min(maxRate, rate * (congested ? 1.25 : 2))
        }
        lastQueued = queued
    }

    /// The ping out has waited `age` for its answer. True when that already shows a queue past
    /// `queueLimit` and longer than the last one: the rate has halved.
    mutating func late(_ age: Duration) -> Bool {
        let queued = age - (base ?? .zero)
        guard queued > queueLimit, queued > lastQueued else { return false }
        slower()
        lastQueued = queued
        return true
    }

    /// The queue the rate keeps under: `target`, or less where `maxQueuedBytes` take less at
    /// this rate.
    var queueLimit: Duration {
        min(target, .seconds(maxQueuedBytes / rate))
    }

    private mutating func slower() {
        congested = true
        rate = max(minRate, rate / 2)
    }

    /// How large the next message is, at most `max`: about `target` at this rate.
    func messageBytes(max: Int) -> Int {
        let want = Int(rate * Self.seconds(target))
        return Swift.min(max, Swift.max(minMessage, want))
    }

    /// How long `bytes` take at this rate.
    func time(for bytes: Int) -> Duration {
        .seconds(Double(bytes) / rate)
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Paces one upload by `UploadRate`: each message waits for its turn, and just before it goes a
/// ping goes out on the control connection, one at a time. A ping that is late already slows the
/// rate, without waiting for its answer, so the rate drops while a queue builds and not after.
///
/// On top of the rate, a window: at most `maxQueuedBytes` (256 KiB) handed to the socket beyond
/// what a control ping has vouched for. Rex never confirms an upload's bytes before its end, so
/// the control connection's ping stands in: its answer means what queued ahead of it on the
/// phone's way out, the tunnel's queue included, has left. The bytes handed out before it left
/// count as confirmed. With the window full the next message waits for that answer, so however
/// the rate overshoots, the network is never handed more than the window.
///
/// No connection, a failed ping, or no answer within `windowWait` tells nothing: the bytes count
/// as confirmed and the rate alone paces, so the upload never stalls on the control connection. A
/// ping that went unanswered that long is waited for once, not once per window.
@MainActor
final class UploadPacer {
    static let probeEvery: Duration = .milliseconds(50)
    static let windowWait: Duration = .seconds(5)

    private let link: any StreamLink
    private(set) var rate: UploadRate
    private let sleep: @MainActor (Duration) async -> Void
    private let clock = ContinuousClock()
    /// When the next message may go.
    private var next: ContinuousClock.Instant?
    /// When the ping that is out left; nil when none is out.
    private var probeStart: ContinuousClock.Instant?
    private var lastProbe: ContinuousClock.Instant?
    /// The ping out has already slowed the rate.
    private var counted = false
    /// The bytes handed to the socket, and those a ping has vouched for.
    private(set) var handedOut: Int64 = 0
    private(set) var confirmed: Int64 = 0
    /// The most ever handed out beyond what was confirmed.
    private(set) var peakUnconfirmed: Int64 = 0
    /// The ping out that went unanswered for `windowWait`: no window waits for it again.
    private var gaveUpOn: ContinuousClock.Instant?
    private var waiter: CheckedContinuation<Void, Never>?
    private var waits = 0

    /// Testing: hears each time a message starts to wait for a ping's answer (the window is full).
    private let onWait: (@MainActor () -> Void)?

    init(link: any StreamLink, rate: UploadRate, sleep: @escaping @MainActor (Duration) async -> Void,
         onWait: (@MainActor () -> Void)? = nil) {
        self.link = link
        self.rate = rate
        self.sleep = sleep
        self.onWait = onWait
    }

    /// Waits for the next message's turn and says how large it may be, at most `max`. The caller
    /// sends that many bytes next.
    func turn(upTo max: Int) async -> Int {
        if let next {
            let now = clock.now
            if next > now { await sleep(next - now) }
        }
        if let probeStart, !counted, rate.late(clock.now - probeStart) { counted = true }
        let bytes = rate.messageBytes(max: max)
        await waitForWindow(bytes)
        // After the waits, so the ping measures the queue this message joins.
        probe(force: false)
        handedOut += Int64(bytes)
        peakUnconfirmed = Swift.max(peakUnconfirmed, handedOut - confirmed)
        next = clock.now + rate.time(for: bytes)
        return bytes
    }

    private func waitForWindow(_ bytes: Int) async {
        let window = Int64(rate.maxQueuedBytes)
        while handedOut > confirmed, handedOut - confirmed + Int64(bytes) > window {
            probe(force: true)
            guard let out = probeStart, out != gaveUpOn else {
                // No connection to measure by, or its ping already went unanswered for
                // `windowWait`: the rate alone paces until an answer comes.
                confirmed = handedOut
                return
            }
            waits += 1
            let wait = waits, sleep = self.sleep
            var timedOut = false
            let timer = Task { [weak self] in
                await sleep(Self.windowWait)
                guard !Task.isCancelled, let self, self.waits == wait, self.waiter != nil else { return }
                timedOut = true
                self.resume()
            }
            await withCheckedContinuation { c in
                waiter = c
                onWait?()
            }
            timer.cancel()
            if timedOut {
                gaveUpOn = out
                confirmed = handedOut
                return
            }
        }
    }

    private func probe(force: Bool) {
        let now = clock.now
        guard probeStart == nil, link.isConnected else { return }
        if !force, let lastProbe, now - lastProbe < Self.probeEvery { return }
        probeStart = now
        lastProbe = now
        counted = false
        let at = handedOut
        let link = self.link, clock = self.clock
        Task { [weak self] in
            let answered = (try? await link.ping()) != nil
            guard let self, self.probeStart == now else { return }
            self.probeStart = nil
            // A failed ping vouches for nothing, but must not hold the file back either.
            self.confirmed = Swift.max(self.confirmed, at)
            // A late ping already slowed the rate; its answer doesn't count twice.
            if answered, !self.counted { self.rate.answered(rtt: clock.now - now) }
            self.resume()
        }
    }

    private func resume() {
        guard let w = waiter else { return }
        waiter = nil
        w.resume()
    }
}
