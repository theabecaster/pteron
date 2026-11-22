import SwiftUI
import UIKit
import RexKit

/// One live terminal pane.
struct PaneView: View {
    let server: ServerConnection
    let sessionID: String
    let blockID: String
    let active: Bool
    let onFocus: () -> Void
    /// Horizontal swipe on the terminal: +1 = next pane, -1 = previous pane.
    var onSwipe: ((Int) -> Void)? = nil
    /// App-level commands from this pane (hardware keyboard shortcuts, two-finger tap).
    /// Defaults to the environment's `AppModel.perform(_:)`.
    var onCommand: ((RexCommand) -> Void)? = nil
    /// The pane's size with the software keyboard down, when the layout knows it
    /// (`TerminalHost.setRestSize`).
    var restSize: CGSize? = nil
    /// The bottom a float sheet leaves below the screen (`TerminalHost.setSheetCover`).
    var sheetCover: CGFloat = 0

    @Environment(Prefs.self) private var prefs

    var body: some View {
        PaneHostView(server: server, sessionID: sessionID, blockID: blockID, active: active,
                     onFocus: onFocus, onSwipe: onSwipe, onCommand: onCommand, restSize: restSize, sheetCover: sheetCover)
    }
}

/// SwiftUI wrapper for the UIKit terminal host.
struct PaneHostView: UIViewRepresentable {
    let server: ServerConnection
    let sessionID: String
    let blockID: String
    let active: Bool
    let onFocus: () -> Void
    var onSwipe: ((Int) -> Void)?
    var onCommand: ((RexCommand) -> Void)?
    var restSize: CGSize?
    var sheetCover: CGFloat = 0

    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(TerminalHostPool.self) private var pool: TerminalHostPool?
    @Environment(\.verticalBarColumn) private var barColumn
    @Environment(\.division) private var division
    @Environment(\.rootOrigin) private var rootOrigin

    private var commandHandler: ((RexCommand) -> Void)? {
        if let onCommand { return onCommand }
        guard let model else { return nil }
        return { [weak model] in model?.perform($0) }
    }

    func makeUIView(context: Context) -> Container {
        let key = TerminalHostPool.Key(server: server.id, session: sessionID, block: blockID)
        // A fold or unfold rebuilt the layout: take over the pane's live host instead of starting over.
        if let pool, let host = pool.host(for: key) {
            let c = Container(host, key: key, pool: pool)
            pool.attach(c)
            apply(host)
            return c
        }
        let p = prefs
        let stream = TerminalStream(control: server.control, sessionID: sessionID, blockID: blockID,
                                    echoGate: server.echoGate, syncCalls: server.syncCalls)
        stream.showsNotices(computer: server.config.name, keymap: server.keymap)
        let host = TerminalHost(stream: stream, sizing: p.sizing, fontSize: p.fontSize, theme: prefs.theme(for: scheme))
        host.keymap = server.keymap
        // Read when the pane checks its fit (`TerminalHost.checkFit`), never per frame.
        host.blockOwner = { [weak server, sessionID, blockID] in
            server?.views[sessionID]?.windowContaining(block: blockID)?.block(blockID)?.owner
        }
        // Read for each key while predicted echo is on (a slow link), never otherwise.
        host.echoContext = { [weak server, blockID] in
            let meta = server?.meta[blockID]
            return (agent: meta?.agentKind != nil, foreground: meta?.foreground)
        }
        host.files = PaneFiles(server: server, sessionID: sessionID, blockID: blockID)
        host.share = PaneShare(server: server, sessionID: sessionID, blockID: blockID)
        host.ports = PanePorts(server: server, sessionID: sessionID, blockID: blockID)
        host.ports?.typed = { [weak model] text, browser in model?.ports.go(text, from: browser) }
        #if DEBUG
        host.ports?.testModel = model
        #endif
        host.ports?.shared = { [weak model, weak server, blockID] link in
            guard let model, let server else { return nil }
            return await model.ports.existingShare(server, block: blockID, link)
        }
        host.ports?.outside = { [weak model, weak server, blockID] port in
            guard let model, let server else { return nil }
            return model.ports.outside(server, block: blockID, port: port)
        }
        if let center = model?.palette {
            host.onServerRun = { [weak center, weak server] name, title in
                guard let center, let server else { return nil }
                return center.keyRun(server, action: name, title: title)
            }
        }
        apply(host)
        let c = Container(host, key: key, pool: pool)
        if let pool {
            pool.add(host, for: key)
            pool.attach(c)
        } else {
            c.adopt()
        }
        return c
    }

    func updateUIView(_ c: Container, context: Context) {
        // A newer PaneView shows this host now; this one is on its way out.
        guard c.owns else { return }
        apply(c.host)
    }

    private func apply(_ host: TerminalHost) {
        let p = prefs
        let theme = prefs.theme(for: scheme)
        if host.theme != theme { host.applyTheme(theme) }
        host.setFontSize(p.fontSize)
        host.setSizing(p.sizing)
        host.setRestSize(restSize)
        host.setSheetCover(sheetCover)
        host.onCommand = commandHandler
        host.isActive = active
        host.onFocus = onFocus
        host.onSwipe = onSwipe
        // After a reconnect the server is asked again whether it takes files.
        if server.phase == .online { host.refreshFiles() }
        let crease = division.flatMap { $0.isVertical ? $0.frame.offsetBy(dx: rootOrigin.x, dy: rootOrigin.y) : nil }
        host.setKeyBarSurroundings(barColumn: barColumn, crease: crease)
    }

    static func dismantleUIView(_ c: Container, coordinator: ()) {
        if let pool = c.pool {
            pool.detach(c)
        } else {
            c.host.scheduleStop()
        }
    }

    /// Each PaneView gets its own container; the host moves between containers. SwiftUI may build a
    /// view and drop it again while it swaps layouts, and may tear an old container down after a new
    /// one took the host; neither may take the host from the container on screen.
    final class Container: UIView {
        let host: TerminalHost
        let key: TerminalHostPool.Key
        weak var pool: TerminalHostPool?

        init(_ host: TerminalHost, key: TerminalHostPool.Key, pool: TerminalHostPool?) {
            self.host = host
            self.key = key
            self.pool = pool
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// This container shows the host now.
        var owns: Bool { host.superview === self }

        func adopt() {
            guard !owns else { return }
            // UIKit takes the keyboard from a view it moves; the host takes it back where it lands.
            host.noteKeyboardBeforeMove()
            host.frame = bounds
            addSubview(host)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { pool?.show(key) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if owns { host.frame = bounds }
        }
    }
}

/// The terminal hosts: one per pane on screen, and the few that left it last. A fold or an unfold
/// swaps the layout's view tree (navigation stack, pages); the new `PaneView` takes the pane's host
/// from here, so the stream, the screen, the scroll position and the keyboard carry over instead
/// of reconnecting. The newest container shows the host; when it goes, the host moves back to the
/// newest one left, and with none left it parks once it has been off screen for half a second
/// (`TerminalHost.scheduleStop`).
///
/// **The park.** A parked host keeps its screen and its place in the stream, and nothing that
/// costs: no socket, no drawables, no timer (`TerminalHost.park`). A pane the user comes back to
/// is then on screen in its first frame, and its stream resumes with only what it missed. The
/// pool keeps the `limits.count` panes parked last, within `limits.bytes` of terminal memory,
/// and lets the oldest go first (`ParkPolicy`). All of them go on a memory warning, when the app
/// comes back after `limits.backgroundLife`, and when their server is left or their session
/// closes (`keep`). Owned by `RootView`.
@MainActor
@Observable
final class TerminalHostPool {
    struct Key: Hashable {
        var server: UUID
        var session: String
        var block: String
    }

    private final class Weak {
        weak var c: PaneHostView.Container?
        init(_ c: PaneHostView.Container) { self.c = c }
    }

    @ObservationIgnored private var hosts: [Key: TerminalHost] = [:]
    @ObservationIgnored private var containers: [Key: [Weak]] = [:]
    /// The parked panes, oldest first.
    @ObservationIgnored private(set) var parked: [Key] = []
    /// The warm panes, oldest first: off screen with their streams running (`WarmPolicy`).
    @ObservationIgnored private(set) var warm: [Key] = []
    /// The network is cellular or a hotspot. `RootView` says; tests put their own here.
    @ObservationIgnored var expensiveNetwork: () -> Bool = { false }
    /// Low Power Mode and the thermal state. Tests put their own here.
    @ObservationIgnored var power: () -> (lowPower: Bool, hot: Bool) = {
        let p = ProcessInfo.processInfo
        return (p.isLowPowerModeEnabled, p.thermalState == .serious || p.thermalState == .critical)
    }
    /// How many panes may be warm right now.
    private var warmLimit: Int {
        let p = power()
        return WarmPolicy.limit(WarmPolicy.Facts(foreground: backgroundedAt == nil, lowPower: p.lowPower, hot: p.hot,
                                                 expensive: expensiveNetwork()))
    }
    @ObservationIgnored var limits = ParkLimits()
    /// The clock the time in the background is read from. Tests put their own here.
    @ObservationIgnored var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    @ObservationIgnored private var backgroundedAt: CFTimeInterval?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ body: @escaping @MainActor (TerminalHostPool) -> Void) {
            // Never removed: the pool lives as long as the app's root, and the closure holds it weakly.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            })
        }
        observe(UIApplication.didReceiveMemoryWarningNotification) { $0.evictParked() }
        observe(UIApplication.didEnterBackgroundNotification) {
            $0.backgroundedAt = $0.now()
            $0.settleWarm()
        }
        observe(.NSProcessInfoPowerStateDidChange) { $0.settleWarm() }
        observe(ProcessInfo.thermalStateDidChangeNotification) { $0.settleWarm() }
        observe(UIApplication.willEnterForegroundNotification) { $0.cameBack() }
    }

    /// Back in the foreground: after long enough away, the parked panes are let go.
    func cameBack() {
        guard let since = backgroundedAt else { return }
        backgroundedAt = nil
        if ParkPolicy.expired(awayFor: now() - since, limits: limits) { evictParked() }
    }

    /// Lets the panes off screen go, parked and warm: all of them, or those `stale` says have
    /// nowhere to come back to.
    func evictParked(where stale: (Key) -> Bool = { _ in true }) {
        for key in parked + warm where stale(key) { hosts[key]?.evict() }
    }

    /// A pane has been off screen for its settle time: it stays warm if the limit allows one
    /// more, and the warm panes over the limit park, oldest first.
    private func didLeave(_ key: Key) {
        guard let host = hosts[key] else { return }
        guard warmLimit > 0 else { return host.park() }
        warm.removeAll { $0 == key }
        warm.append(key)
        host.warm()
        settleWarm()
        trim()
    }

    /// Parks the warm panes over the limit, which may have fallen to none (the background, Low
    /// Power Mode, a hot phone) or to one (a cellular network). Also called when a network
    /// change may have lowered it.
    func settleWarm() {
        let limit = warmLimit
        while warm.count > limit, let oldest = warm.first {
            hosts[oldest]?.park()
            // `park` takes it off the list (`didPark`); a pane that is gone is taken off here.
            if warm.first == oldest { warm.removeFirst() }
        }
    }

    /// What the app shows changed: parked panes of a server the user left, of a server that is
    /// gone, and of a session that closed are let go (`ParkPolicy.isStale`).
    func keep(selected: UUID?, servers: Set<UUID>, sessions: [UUID: Set<String>]) {
        evictParked { key in
            ParkPolicy.isStale(server: key.server, session: key.session, selected: selected, servers: servers, sessions: sessions)
        }
    }

    private func didPark(_ key: Key) {
        warm.removeAll { $0 == key }
        parked.removeAll { $0 == key }
        parked.append(key)
        trim()
    }

    /// Keeps the panes off screen within `limits`, parked and warm together: the parked ones
    /// are the older.
    private func trim() {
        let sized = (parked + warm).map { (key: $0, bytes: hosts[$0]?.keptBytes ?? 0) }
        for old in ParkPolicy.evictions(sized, limits: limits) { hosts[old]?.evict() }
    }

    func host(for key: Key) -> TerminalHost? { hosts[key] }

    /// The pane is on screen again, as when its container joins a window. For tests of what a
    /// pane keeps across a park, which have no view hierarchy to put it back into.
    func bringBack(_ key: Key) { hosts[key]?.cameBackOnScreen() }

    /// Changes when a host comes or goes. Only views that look a host up while they draw read it
    /// (`AttachMenuItem`), so a new pane redraws them and nothing else.
    private(set) var hostsChanged = 0

    /// The vertical bar's Hide Keyboard item: the pane whose key bar it hides now. Only the tab's
    /// toolbar reads it, where the system has a vertical bar.
    let hideKeyboard = HideKeyboardItem()

    /// The agent board covers every pane (`TerminalHost.setCovered`), the ones made later too.
    @ObservationIgnored private(set) var covered = false
    /// A hardware key reached a pane. The hosts are told only while someone listens.
    @ObservationIgnored var onKeyPress: (() -> Void)? {
        didSet { for host in hosts.values { host.onKeyPress = onKeyPress } }
    }

    /// `softwareKeyboard`: the software keyboard is on screen as the cover comes.
    func setCovered(_ c: Bool, softwareKeyboard: Bool = false) {
        guard c != covered else { return }
        covered = c
        for host in hosts.values { host.setCovered(c, softwareKeyboard: softwareKeyboard) }
    }

    /// A keyboard the palette owes the pane it showed (`owe`): shown or quiet, until it expires.
    @ObservationIgnored private var owed: (key: Key, quiet: Bool, until: CFTimeInterval)?
    @ObservationIgnored private var owedExpiry: DispatchWorkItem?
    /// Told once when an owed keyboard was taken or ran out.
    @ObservationIgnored var onOwedSettled: (() -> Void)?
    static let owedLifetime: CFTimeInterval = 2

    /// The palette showed another pane while the keyboard was up: that pane's host takes it once
    /// it is active and on screen, also a host that is still to be made (another session or
    /// server). It runs out after `owedLifetime`, so a later pane switch never raises it unasked.
    func owe(_ key: Key, quiet: Bool) {
        owedExpiry?.cancel()
        owed = (key, quiet, CACurrentMediaTime() + Self.owedLifetime)
        let work = DispatchWorkItem { [weak self] in self?.settleOwed() }
        owedExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.owedLifetime, execute: work)
    }

    /// Whether `key`'s host takes a keyboard now, and quietly or not; at most once.
    func takeOwed(_ key: Key) -> Bool? {
        guard let o = owed, o.key == key, CACurrentMediaTime() < o.until else { return nil }
        settleOwed()
        return o.quiet
    }

    private func settleOwed() {
        guard owed != nil else { return }
        owed = nil
        owedExpiry?.cancel()
        owedExpiry = nil
        onOwedSettled?()
    }

    func add(_ host: TerminalHost, for key: Key) {
        hosts[key] = host
        hostsChanged &+= 1
        if covered { host.setCovered(true) }
        host.onKeyPress = onKeyPress
        host.takeOwedKeyboard = { [weak self] in self?.takeOwed(key) }
        host.onBarHidesKeyboard = { [weak self] shown in self?.hideKeyboard.set(key, shown: shown) }
        if host.barHidesKeyboard { hideKeyboard.set(key, shown: true) }
        host.canPark = true
        host.onParked = { [weak self, weak host] in
            guard let self, let host, self.hosts[key] === host else { return }
            self.didPark(key)
        }
        host.onLeft = { [weak self, weak host] in
            guard let self, let host, self.hosts[key] === host else { host?.park(); return }
            self.didLeave(key)
        }
        host.onUnparked = { [weak self, weak host] in
            guard let self, let host, self.hosts[key] === host else { return }
            self.parked.removeAll { $0 == key }
            self.warm.removeAll { $0 == key }
        }
        host.onStopped = { [weak self, weak host] in
            guard let self, let host, self.hosts[key] === host else { return }
            self.hosts[key] = nil
            self.hostsChanged &+= 1
            self.containers[key] = nil
            self.hideKeyboard.set(key, shown: false)
            self.parked.removeAll { $0 == key }
            self.warm.removeAll { $0 == key }
        }
    }

    @ObservationIgnored private var showing: Set<Key> = []
    @ObservationIgnored private var showAgain: Set<Key> = []

    /// A new container for the pane.
    func attach(_ c: PaneHostView.Container) {
        containers[c.key, default: []].removeAll { $0.c == nil || $0.c === c }
        containers[c.key, default: []].append(Weak(c))
        show(c.key)
    }

    /// A container went away. If it showed the host, the host goes back to one that is left.
    func detach(_ c: PaneHostView.Container) {
        containers[c.key]?.removeAll { $0.c == nil || $0.c === c }
        guard c.owns else { return }
        if Self.target(live(c.key)) != nil {
            show(c.key)
        } else {
            c.host.scheduleStop()
        }
    }

    private func live(_ key: Key) -> [PaneHostView.Container] { containers[key]?.compactMap(\.c) ?? [] }

    /// The container that shows the host: the newest one in a window, else the newest. SwiftUI
    /// builds containers it never puts on screen (to measure a transition, or for a layout it then
    /// drops) and doesn't always tear them down; one of those must not take the host from the
    /// container on screen, or the pane goes blank and loses the keyboard.
    static func target<C: UIView>(_ containers: [C]) -> C? {
        containers.last { $0.window != nil } ?? containers.last
    }

    /// Moves the pane's host to the container that should show it. Called for a new container and
    /// when one enters a window. Moving the host can make SwiftUI build more containers before the
    /// move returns; those wait for it to finish.
    func show(_ key: Key) {
        guard !showing.contains(key) else { showAgain.insert(key); return }
        showing.insert(key)
        defer { showing.remove(key) }
        repeat {
            showAgain.remove(key)
            Self.target(live(key))?.adopt()
        } while showAgain.contains(key)
    }
}

/// Tells the pool when parked panes have nowhere to come back to: the user left their server,
/// the server is gone, or their session closed. A view of no size that reads only the selection's
/// server and the session lists, so nothing else re-renders for it.
struct ParkWatcher: View {
    @Environment(AppModel.self) private var model
    let pool: TerminalHostPool

    private struct Facts: Equatable {
        var selected: UUID?
        var servers: Set<UUID>
        /// The sessions of each server that is online.
        var sessions: [UUID: Set<String>]
    }

    var body: some View {
        let facts = Facts(selected: model.selection?.serverID, servers: Set(model.servers.map(\.id)),
                          sessions: Dictionary(model.servers.filter { $0.phase == .online }.map { ($0.id, Set($0.sessions.map(\.id))) },
                                               uniquingKeysWith: { a, _ in a }))
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: facts) { _, now in
                pool.keep(selected: now.selected, servers: now.servers, sessions: now.sessions)
            }
            // On a cellular network or a hotspot one pane less stays warm.
            .onChange(of: model.network?.snapshot.expensive ?? false, initial: true) { _, expensive in
                pool.expensiveNetwork = { expensive }
                pool.settleWarm()
            }
    }
}

extension TerminalStream {
    /// Where a pane's stream says what it could not do: a failure in the error style, and input
    /// the catch-up fence dropped in the neutral one, since nothing failed. An action is named as
    /// the palette names it, never by its id.
    func showsNotices(computer: String, keymap: KeymapStore?) {
        let title: (String) -> String = { [weak keymap] id in
            let t = keymap?.title(forAction: id) ?? id
            return t == id ? "the action" : t
        }
        onActionFailed = { RexDuo.Notice.shared.show(Messages.stream($0, computer: computer, title: title)) }
        onFenceNotice = { RexDuo.Notice.shared.show(Messages.stream($0, computer: computer, title: title), style: .neutral) }
    }
}
