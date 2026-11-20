import RexKit
import SwiftUI
import UIKit

/// Holds the root's keyboard room while the palette is open, so opening and closing it resize
/// no pane: the field taking the keyboard from a terminal takes the key bar's 44 pt with it, and
/// opening with the keyboard down raises it. Each new value waits aside and is applied when
/// the hold ends: at the first keyboard change after the keyboard was handed back (or 300 ms),
/// or at once when the root changes width, which resizes the panes anyway. A channel that can be
/// measured again (`remeasure`) is, instead of taking the value kept aside: that value may be a
/// report from the hand-back, before the key bar was back above the keys.
@MainActor
final class PadHold {
    /// The root's keyboard pad, and under `-simulateDuo` the simulated keyboard's height.
    enum Channel: Hashable { case pad, sim }

    /// The hold ended: views that kept a value read the live one again.
    static let ended = Notification.Name("GoToPadHold.ended")
    static let releaseWait: TimeInterval = 0.3
    /// Keyboard changes this close after the first one count as the same change.
    static let settle: TimeInterval = 0.06

    private(set) var active = false
    private var releasing = false
    private var stored: [Channel: CGFloat] = [:]
    private var end: DispatchWorkItem?
    /// Writes a channel's value; set by the view that owns it.
    var apply: [Channel: (CGFloat) -> Void] = [:]
    /// Measures a channel afresh and writes it, in place of the value kept aside; set by the view
    /// that measures it (`KeyboardInsetReader`).
    var remeasure: [Channel: () -> Void] = [:]

    func begin() {
        end?.cancel()
        end = nil
        active = true
        releasing = false
    }

    /// A new value for a channel. True when the hold keeps it aside.
    func offer(_ c: Channel, _ v: CGFloat) -> Bool {
        guard active else { return false }
        stored[c] = v
        if releasing { schedule(after: Self.settle) }
        return true
    }

    /// The keyboard was handed back: end at its first change, or after `releaseWait`.
    func release() {
        guard active, !releasing else { return }
        releasing = true
        schedule(after: Self.releaseWait)
    }

    /// The root changed width: end now.
    func endNow() {
        guard active else { return }
        finish()
    }

    private func schedule(after delay: TimeInterval) {
        end?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        end = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finish() {
        end?.cancel()
        end = nil
        active = false
        releasing = false
        let values = stored
        stored = [:]
        for (c, v) in values where remeasure[c] == nil { apply[c]?(v) }
        for measure in remeasure.values { measure() }
        NotificationCenter.default.post(name: Self.ended, object: self)
    }
}

/// Opens, runs and closes the palette, and keeps what outlives one opening: the Lua and block
/// actions this phone ran (a question one of them asks shows here), the questions waiting
/// their turn, the keyboard to hand back and the hold on the root's keyboard room.
///
/// Closed it costs nothing: no observation, no index, no view.
@MainActor
final class GoToCenter {
    unowned let model: AppModel
    /// The panes' hosts, for the keyboard and for actions on the target pane. Set by `RootView`.
    weak var pool: TerminalHostPool? {
        didSet { pool?.onOwedSettled = { [weak self] in self?.padHold.release() } }
    }
    let padHold = PadHold()
    /// Where the tab's title bar ends on screen (global), while it shows: the panel opens 8 pt
    /// below it. Written by the title bar's layout, read only at open.
    var titleBarBottom: CGFloat?
    private(set) var origins = PaletteOrigins()
    private var queue = PromptQueue()
    /// Who held the target pane's keyboard at open, to give it back.
    private var record: (record: KeyboardRecord, key: TerminalHostPool.Key)?
    /// The "Running …" notice: its job, its run, when it first showed.
    private var running: (job: Notice.JobID?, run: Int, title: String, since: Date)?
    private var runningTask: Task<Void, Never>?
    private var promptTimer: Task<Void, Never>?
    private var replying = false

    /// How long a run waits before its notice shows, and how long the notice stays at most.
    static let runningDelay: Duration = .milliseconds(1500)
    static let runningCap: TimeInterval = 6

    init(model: AppModel) { self.model = model }

    // MARK: Servers

    func attach(_ s: ServerConnection) {
        s.prompts.onPrompt = { [weak self, weak s] r in
            guard let self, let s else { return false }
            return self.take(r, from: s)
        }
        s.prompts.onPromptEnded = { [weak self] id, _ in self?.promptGone(id) }
        s.prompts.onConnected = { [weak self, weak s] _ in
            guard let self, let s else { return }
            self.reconnected(s)
        }
    }

    // MARK: Opening and closing

    /// Opens the palette in `scope` on `target` (nil with no tab on screen). Open already, it
    /// switches scope and keeps the text. Never while the tent board shows.
    func open(_ scope: GoToScope, target: GoToTarget?, prompt: PalettePrompt? = nil) {
        guard !model.boardShown else { return }
        if let s = model.goTo {
            if let prompt { s.showPrompt(prompt) } else if s.prompt == nil { s.switchScope(scope) }
            return
        }
        let window = Self.keyWindow()
        // Before the field takes the keyboard: find's field, if it has it, keeps its fit hold.
        FitHoldDeferral.set(true, in: window)
        padHold.begin()
        record = nil
        if let t = target, let b = t.blockID {
            let key = TerminalHostPool.Key(server: t.serverID, session: t.sessionID, block: b)
            if let host = pool?.host(for: key) { record = (KeyboardRecord.capture(host), key) }
        }
        let s = GoToModel(scope: scope, target: target, center: self, anchor: target == nil ? nil : titleBarBottom)
        model.goTo = s
        s.start()
        if let prompt { s.showPrompt(prompt) }
    }

    /// A palette key with the palette open: the same scope closes it, another switches to it.
    /// A question on screen is closed only by its own buttons and Esc.
    func keyPressed(_ scope: GoToScope) {
        guard let s = model.goTo, s.prompt == nil else { return }
        if s.scope == scope { close() } else { s.switchScope(scope) }
    }

    /// Where the keyboard goes as the palette closes.
    enum HandBack {
        /// To whatever held it at open (the pick stays in that pane).
        case stay
        /// Owed to this pane, which is about to show.
        case other(TerminalHostPool.Key)
    }

    /// Closes the palette. Every way it closes comes here: one place ends the hold.
    func close(_ hand: HandBack = .stay) {
        guard let s = model.goTo else { return }
        s.finish()
        var owed = false
        switch hand {
        case .stay:
            // The terminal takes the keyboard from the field directly: no second frame change.
            if let r = record, let host = pool?.host(for: r.key) { host.retakeKeyboard(r.record) }
        case .other(let key):
            if let r = record, r.key != key, let quiet = Self.owedQuiet(r.record) {
                pool?.owe(key, quiet: quiet)
                owed = true
            } else if let r = record, let host = pool?.host(for: r.key) {
                host.retakeKeyboard(r.record)
            }
        }
        let window = s.field?.window ?? Self.keyWindow()
        if let f = s.field, f.isFirstResponder { _ = f.resignFirstResponder() }
        record = nil
        model.goTo = nil
        // After the hand-back: a find field that has the keyboard again keeps its hold.
        FitHoldDeferral.set(false, in: window)
        // An owed keyboard ends the hold once a pane takes it, or it runs out.
        if !owed { padHold.release() }
    }

    /// Whether a pane given the keyboard from `record` takes it quietly; nil when none was up.
    static func owedQuiet(_ record: KeyboardRecord) -> Bool? {
        switch record {
        case .shown, .ownFindField(accessory: true): false
        case .quiet, .ownFindField(accessory: false): true
        case .none: nil
        }
    }

    /// The pane the palette's target tab would show: as `WindowScreen` picks it.
    static func activeBlock(_ w: WindowInfo, focused: [String: String]) -> String? {
        if let f = focused[w.id], w.allBlocks.contains(where: { $0.id == f }) { return f }
        if let z = w.zoomedBlockID { return z }
        return w.focusedBlockID ?? w.orderedBlockIDs.first
    }

    /// The tab on screen as a target, for a question that opens the palette by itself.
    func currentTarget() -> GoToTarget? {
        guard let cur = model.current else { return nil }
        return GoToTarget(serverID: cur.server.id, sessionID: cur.view.sessionID, windowID: cur.window.id,
                          blockID: Self.activeBlock(cur.window, focused: model.focusedPane))
    }

    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    // MARK: Running a row

    /// Runs the row `id`: goes there, or runs the command. A dimmed row does nothing.
    func run(_ id: GoToItemID) {
        guard let s = model.goTo else { return }
        guard let run = s.runs[id] ?? s.typedRuns[id] ?? GoToRun.place(for: id, in: model) else {
            // A session that closed since the copy.
            remember(nil, removing: id)
            close()
            Notice.shared.show("That tab closed.")
            return
        }
        switch run {
        case .none:
            return
        case .place(let sel, let block):
            guard let server = model.server(sel.serverID), let v = server.views[sel.sessionID],
                  let w = v.window(sel.windowID), block.map({ w.block($0) != nil }) ?? true else {
                remember(nil, removing: id)
                close()
                Notice.shared.show(block == nil ? "That tab closed." : Messages.paneClosed)
                return
            }
            remember(id)
            let dest = TerminalHostPool.Key(server: server.id, session: sel.sessionID,
                                            block: block ?? Self.activeBlock(w, focused: model.focusedPane) ?? "")
            close(dest == record?.key ? .stay : .other(dest))
            if let block {
                model.openPane(server, session: sel.sessionID, window: sel.windowID, block: block)
            } else {
                model.openRequest = OpenRequest(selection: sel)
            }
        case .command(let c):
            remember(id)
            close()
            model.perform(c)
        case .files(let c):
            remember(id)
            let target = s.target
            close()
            // Once the field has let go of the keyboard and the pane has it back: the browser
            // then records who holds it, as it does from the attach menu.
            DispatchQueue.main.async { [weak self] in
                guard let t = target, let b = t.blockID,
                      let host = self?.pool?.host(for: TerminalHostPool.Key(server: t.serverID, session: t.sessionID, block: b))
                else { return }
                host.files?.run(c)
            }
        case .port(let serverID, let rowID):
            guard let server = model.server(serverID), let row = model.ports.row(server, id: rowID) else {
                remember(nil, removing: id)
                close()
                Notice.shared.show("Nothing listens on that port now.", style: .neutral)
                return
            }
            remember(id)
            close()
            // Once the pane has the keyboard back, so the page gives it back to the pane when it closes.
            DispatchQueue.main.async { [weak self] in self?.model.ports.open(server, row) }
        case .address(let serverID, let rowID, let address):
            guard let server = model.server(serverID), let row = model.ports.row(server, id: rowID) else {
                close()
                Notice.shared.show(PortAddress.nothing(address), style: .neutral)
                return
            }
            close()
            DispatchQueue.main.async { [weak self] in self?.model.ports.open(server, row, as: address) }
        case .server(let serverID, let name, let args, let title, let onTarget):
            remember(id)
            let target = s.target
            close()
            runServer(serverID, name: name, args: args, title: title, target: onTarget ? target : nil)
        }
    }

    private func remember(_ id: GoToItemID?, removing gone: GoToItemID? = nil) {
        var list = model.prefs.goToRecents
        if let gone { list = GoToRecents.remove(gone, from: list) }
        if let id { list = GoToRecents.record(id, at: Date(), in: list) }
        if list != model.prefs.goToRecents { model.prefs.goToRecents = list }
    }

    /// A Lua or block action: on the target pane, through its input queue (so it follows the
    /// keys typed before it); with no pane, on the server alone.
    private func runServer(_ serverID: UUID, name: String, args: JSONObject?, title: String, target: GoToTarget?) {
        guard let server = model.server(serverID) else { return }
        if let t = target, let b = t.blockID {
            guard let host = pool?.host(for: TerminalHostPool.Key(server: serverID, session: t.sessionID, block: b)) else {
                Notice.shared.show(Messages.paneClosed)
                return
            }
            let id = origins.started(server: serverID, serial: server.connectionSerial, action: name, title: title, at: Date())
            showRunning(id, title: title)
            host.runFromPalette(name, args: args, title: title, ended: { [weak self] _ in self?.runEnded(id) },
                                skipped: { n in if n > 0 { Notice.shared.show("Ran \(title). Some steps run only in the Rex app.", style: .neutral) } })
            return
        }
        guard server.control.state == .connected else {
            Notice.shared.show(Messages.didNotRun(title, computer: server.config.name))
            return
        }
        let id = origins.started(server: serverID, serial: server.connectionSerial, action: name, title: title, at: Date())
        showRunning(id, title: title)
        Task { [weak self] in
            do {
                let queued = try await server.runAction(name: name, args: args)
                self?.performQueued(queued, title: title)
            } catch let e as RexError where e.neverSent {
                Notice.shared.show(Messages.didNotRun(title, computer: server.config.name))
            } catch let e as RexError where e.code != "client" {
                Notice.shared.show(Messages.couldNot("run \(title)", e, computer: server.config.name))
            } catch {
                // Sent, and the answer was lost: nobody knows whether it ran.
            }
            self?.runEnded(id)
        }
    }

    /// The client actions a run with no pane asked for: the app's commands run; the rest
    /// need a pane or the Rex app.
    private func performQueued(_ queued: [JSONObject], title: String) {
        var skipped = 0
        for q in queued {
            guard let n = q.str("action"), case .command(let c)? = AppAction.resolve(n, q.obj("args")) else {
                skipped += 1
                continue
            }
            model.perform(c)
        }
        if skipped > 0 { Notice.shared.show("Ran \(title). Some steps run only in the Rex app.", style: .neutral) }
    }

    /// A key ran a Lua or block action: kept, so a question it asks shows in the palette.
    func keyRun(_ server: ServerConnection, action: String, title: String) -> @MainActor (Bool) -> Void {
        let id = origins.started(server: server.id, serial: server.connectionSerial, action: action, title: title, at: Date())
        return { [weak self] _ in self?.origins.ended(id) }
    }

    private func runEnded(_ id: Int) {
        origins.ended(id)
        if running?.run == id { hideRunning() }
    }

    // MARK: The running notice

    /// After 1.5 s without an answer, "Running Dev Layout…" on the notice job lane, for at most
    /// about 6 s. A later run's notice replaces it.
    private func showRunning(_ run: Int, title: String) {
        hideRunning()
        running = (nil, run, title, Date())
        runningTask = Task { [weak self] in
            try? await Task.sleep(for: Self.runningDelay)
            guard !Task.isCancelled else { return }
            self?.raiseRunning()
        }
    }

    private func raiseRunning() {
        guard var r = running, r.job == nil, origins.runs.contains(where: { $0.id == r.run && $0.inFlight }),
              queue.shown == nil else { return }
        let left = Self.runningCap - Date().timeIntervalSince(r.since)
        guard left > 0, let job = Notice.shared.tryBeginJob(text: "Running \(r.title)…") else { return }
        r.job = job
        running = r
        runningTask?.cancel()
        runningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled else { return }
            self?.hideRunning()
        }
    }

    /// Takes the notice down; the run itself goes on.
    private func pauseRunning() {
        guard let job = running?.job else { return }
        Notice.shared.endJob(job)
        running?.job = nil
    }

    private func hideRunning() {
        runningTask?.cancel()
        runningTask = nil
        if let job = running?.job { Notice.shared.endJob(job) }
        running = nil
    }

    // MARK: Questions from the phone's own runs (`rex.ui`, revision 17)

    /// Takes a prompt only when it belongs to a run of this phone that is still waiting
    /// (`PaletteOrigins.owner`); every other one goes back to the default decline.
    private func take(_ r: PromptRequest, from s: ServerConnection) -> Bool {
        guard s.capabilities.supports(17),
              let run = origins.owner(of: r, server: s.id, now: Date(), boardShown: model.boardShown),
              let p = PalettePrompt(r, serverID: s.id, runID: run.id, actionTitle: run.title) else { return false }
        if queue.add(p) { show(p) }
        armPromptTimer()
        return true
    }

    private func show(_ p: PalettePrompt) {
        // The question replaces the running notice.
        pauseRunning()
        open(.anything, target: model.goTo?.target ?? currentTarget(), prompt: p)
    }

    /// The prompt on screen was answered or ended: the next one waiting shows, else the
    /// palette closes and the run's notice may come back.
    private func promptGone(_ callID: String) {
        let wasShown = queue.shown?.callID == callID
        let next = queue.remove(callID, now: Date())
        armPromptTimer()
        guard wasShown else { return }
        if let next {
            show(next)
        } else if model.goTo?.prompt?.callID == callID {
            close()
            resumeRunning()
        }
    }

    private func resumeRunning() {
        guard running != nil else { return }
        raiseRunning()
    }

    /// Closes prompts whose `timeout_ms` has passed, shown or waiting.
    private func armPromptTimer() {
        promptTimer?.cancel()
        let deadlines = ([queue.shown].compactMap { $0 } + queue.waiting).map(\.deadline)
        guard let first = deadlines.min() else { return }
        promptTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(first.timeIntervalSinceNow, 0) + 0.01))
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            for p in [self.queue.shown].compactMap({ $0 }) + self.queue.waiting where p.deadline <= now {
                self.promptGone(p.callID)
            }
            self.armPromptTimer()
        }
    }

    /// A new connection: the old connection's prompts close without a reply.
    private func reconnected(_ s: ServerConnection) {
        let gone = queue.dropAll(server: s.id)
        guard !gone.isEmpty else { return }
        if let shown = model.goTo?.prompt, gone.contains(where: { $0.callID == shown.callID }) {
            if let next = queue.advance(now: Date()) { show(next) } else { close() }
        }
        armPromptTimer()
    }

    /// Sends the answer on the control connection, not the pane's input queue: the run's
    /// `client.action` holds that queue's one slot, and a reply never waits behind it. Rex
    /// refusing the answer (`bad_request`) leaves the question open; any other failure closes it.
    func answer(_ payload: JSONObject) {
        guard !replying, let p = model.goTo?.prompt, let server = model.server(p.serverID) else { return }
        replying = true
        Task { [weak self] in
            var keep = false
            do {
                _ = try await server.control.call("client.reply", payload)
                self?.origins.answered(p.runID)
            } catch let e as RexError where e.code == "bad_request" {
                keep = true
                Notice.shared.show("Rex didn't accept that answer. Check it and answer again.")
            } catch {}
            guard let self else { return }
            self.replying = false
            if !keep { self.promptGone(p.callID) }
        }
    }

    /// Cancel, Esc or a tap outside: ends the question everywhere.
    func cancelPrompt() {
        guard let p = model.goTo?.prompt else { return }
        answer(PalettePrompt.cancel(p.callID))
    }

    /// The tent board came up: the palette goes. A question on screen is left to the other
    /// apps (declined here, not cancelled).
    func boardShown() {
        guard let s = model.goTo else { return }
        if let p = s.prompt, let server = model.server(p.serverID) {
            server.control.post("client.reply", PromptRequest.decline(callID: p.callID))
            _ = queue.remove(p.callID, now: Date())
            for w in queue.waiting {
                model.server(w.serverID)?.control.post("client.reply", PromptRequest.decline(callID: w.callID))
                _ = queue.remove(w.callID, now: Date())
            }
        }
        close()
    }
}
