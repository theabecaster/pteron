import Foundation
import RexKit

/// A buffered progress report: `value` nil removes the bar.
struct PendingProgress: Equatable {
    var value: TermProgress?
}

/// A block's latest notice, for repeats.
struct NoticeText: Equatable {
    var text: String
    var at: ContinuousClock.Instant
}

/// What programs in panes signal besides agent status: progress bars (OSC 9;4) and desktop
/// notifications (OSC 9 / 777). Both arrive as terminal block events and are used only where the
/// server's terminal creator lists them, per host (Compatibility in docs/rex-protocol.md).
extension ServerConnection {
    static let terminalCreator = "com.superlogical.terminal"
    /// Progress reports apply at most this often. A bar needs no more, and status badges keep
    /// their own faster flush (`coalesce`).
    static let progressFlush: Double = 0.5
    /// A bar with no report for this long goes, as in Ghostty.
    static let progressStale: Duration = .seconds(15)
    /// How often stale bars are looked for, while some bar shows.
    static let progressSweepEvery: Duration = .seconds(5)
    /// A notice waits this long before it is judged, so an agent status sent right after it
    /// still counts.
    static let noticeWait: Duration = .seconds(1)

    /// Whether blocks on `host` send this terminal event, as the server's creator list says. An
    /// unknown or failed list says no: nothing new shows until the server vouches for it.
    func sendsEvent(_ name: String, host: String?) -> Bool {
        capabilities.event(name, creator: Self.terminalCreator, host: host) == .present
    }

    /// The listed blocks found in this server's views.
    func blocks(_ ids: Set<String>) -> [String: BlockInfo] {
        var out: [String: BlockInfo] = [:]
        for v in views.values {
            for w in v.windows {
                for b in w.allBlocks where ids.contains(b.id) { out[b.id] = b }
            }
        }
        return out
    }

    /// Forgets what alerts kept about a block that closed or whose session went.
    func forgetBlockAlerts(_ bid: String) {
        dropProgress(bid)
        statusRemovedAt[bid] = nil
        noticeTexts[bid] = nil
    }

    // MARK: Progress

    func receiveProgress(_ bid: String, _ payload: JSONObject) {
        guard let report = TermProgress.Report(payload) else { return }
        let current = pendingProgress[bid].map(\.value) ?? progress.value(bid)
        stageProgress(bid, report.applied(to: current))
    }

    /// Buffers a bar's new value for the next progress flush. An unchanged value only counts as
    /// a report, so a program that repeats itself writes nothing.
    func stageProgress(_ bid: String, _ next: TermProgress?) {
        let current = pendingProgress[bid].map(\.value) ?? progress.value(bid)
        if next == nil { progressSeen[bid] = nil } else { progressSeen[bid] = .now }
        guard next != current else { return }
        pendingProgress[bid] = PendingProgress(value: next)
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.progressFlush))
            self?.flushProgress()
        }
    }

    /// Applies buffered reports. A bar shows only for a block in the views whose host lists the
    /// event; the rest wait for the next report.
    func flushProgress() {
        progressFlushTask = nil
        guard !pendingProgress.isEmpty else { return }
        let pending = pendingProgress
        pendingProgress = [:]
        let found = blocks(Set(pending.compactMap { $0.value.value == nil ? nil : $0.key }))
        for (bid, p) in pending {
            if p.value != nil {
                guard let b = found[bid], sendsEvent("progress_report", host: b.hostID) else {
                    progressSeen[bid] = nil
                    continue
                }
            }
            progress.set(bid, p.value)
            #if DEBUG
            RenderCount.bump(.progressWrites)
            #endif
        }
        if !progress.setIDs.isEmpty { startProgressSweep() }
    }

    /// Clears bars that went quiet. Returns whether any bar still shows.
    @discardableResult
    func sweepProgress(now: ContinuousClock.Instant = .now) -> Bool {
        var left = false
        for bid in progress.setIDs {
            if let seen = progressSeen[bid], now - seen < Self.progressStale {
                left = true
            } else {
                progress.set(bid, nil)
                progressSeen[bid] = nil
            }
        }
        return left
    }

    private func startProgressSweep() {
        guard progressSweepTask == nil else { return }
        progressSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressSweepEvery)
                guard !Task.isCancelled, let self else { return }
                if !self.sweepProgress() {
                    self.progressSweepTask = nil
                    return
                }
            }
        }
    }

    /// A block's bar goes, now and from the buffer: it closed, exited, or its report was dropped.
    func dropProgress(_ bid: String) {
        pendingProgress[bid] = nil
        progressSeen[bid] = nil
        progress.remove(bid)
    }

    /// A sync: every bar with no report since `mark` goes. One reported since, equal reports
    /// included, is live and stays, as do reports still buffered.
    func clearProgressBoxes(notSeenSince mark: ContinuousClock.Instant) {
        let stale = Set(progress.ids.filter { bid in
            pendingProgress[bid] == nil && (progressSeen[bid].map { $0 < mark } ?? true)
        })
        guard !stale.isEmpty else { return }
        for bid in stale { progressSeen[bid] = nil }
        progress.removeAll { stale.contains($0) }
    }

    /// A new connection: nothing from the old one counts.
    func resetProgress() {
        progressFlushTask?.cancel()
        progressFlushTask = nil
        progressSweepTask?.cancel()
        progressSweepTask = nil
        pendingProgress = [:]
        progressSeen = [:]
        statusRemovedAt = [:]
        progress.removeAll()
    }

    // MARK: Notices

    func agentRecordRemoved(_ bid: String) {
        let now = ContinuousClock.now
        statusRemovedAt = statusRemovedAt.filter { now - $0.value < NoticeFilter.agentMemory }
        statusRemovedAt[bid] = now
    }

    /// `desktop_notification`: judged after `noticeWait`, on this connection only. A pane that
    /// floods is held back here, before any wait starts: the same text again within
    /// `ToastPolicy.noticeRepeat` is dropped, and at most `AgentNotifier.perPaneLimit` of a pane's
    /// notices wait at once.
    func receiveNotice(_ sid: String, _ bid: String, _ payload: JSONObject, now: ContinuousClock.Instant = .now) {
        let title = payload.str("title") ?? ""
        let body = payload.str("body") ?? ""
        guard AlertCopy.isNotice(title: title, body: body) else { return }
        let text = title + "\n" + body
        let repeatWindow = Duration.seconds(ToastPolicy.noticeRepeat)
        if let last = noticeTexts[bid], last.text == text, now - last.at < repeatWindow { return }
        if noticeTexts.count > 256 { noticeTexts = noticeTexts.filter { now - $0.value.at < repeatWindow } }
        noticeTexts[bid] = NoticeText(text: text, at: now)
        guard noticesInWait[bid, default: 0] < AgentNotifier.perPaneLimit else { return }
        noticesInWait[bid, default: 0] += 1
        let serial = connectionSerial
        Task { [weak self] in
            try? await Task.sleep(for: Self.noticeWait)
            guard let self else { return }
            let left = (self.noticesInWait[bid] ?? 1) - 1
            self.noticesInWait[bid] = left > 0 ? left : nil
            self.postNotice(serial: serial, sid, bid, title: title, body: body)
        }
    }

    /// Posts the notice unless an agent sent it, the block is gone, or the connection changed
    /// meanwhile (its filter would read another connection's state).
    func postNotice(serial: Int, _ sid: String, _ bid: String, title: String, body: String,
                    now: ContinuousClock.Instant = .now) {
        guard serial == connectionSerial, !hiddenSessions().contains(sid),
              let v = views[sid], let w = v.windowContaining(block: bid), let b = w.block(bid),
              sendsEvent("desktop_notification", host: b.hostID) else { return }
        guard !NoticeFilter.fromAgent(currentMeta(bid), recordRemovedAt: statusRemovedAt[bid], now: now) else { return }
        notifier.postNotice(AgentAlert(serverID: id, sessionID: sid, windowID: w.id, blockID: bid,
                                       title: AlertCopy.noticeTitle(title, tab: WindowTitle.of(w, server: self)),
                                       body: AlertCopy.noticeBody(body, place: label(for: sid, block: bid)),
                                       date: Date(), kind: .notice))
    }
}

/// Which desktop notifications are an agent's. Agents already alert through OSC 7501 (the waiting
/// toast); their OSC 9 reminders would say the same thing twice.
enum NoticeFilter {
    /// A pane that lost an OSC 7501 record counts as an agent's for this long.
    static let agentMemory: Duration = .seconds(10)

    /// The block runs an agent (by status app, foreground or title), has an OSC 7501 record, or
    /// lost one less than `agentMemory` ago.
    static func fromAgent(_ m: BlockMeta?, recordRemovedAt: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        if let m, m.agentKind != nil || !m.statuses.isEmpty { return true }
        if let t = recordRemovedAt, now - t < agentMemory { return true }
        return false
    }
}
