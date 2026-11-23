import Foundation
import RexKit

/// The Lua and block actions this phone ran, so a question one of them asks (`rex.ui`) can be
/// told from a question another app's run asks. The server names only the action, never the
/// client, so the record is what decides. Pure, so it is tested.
struct PaletteOrigins {
    struct Run: Equatable {
        var id: Int
        var serverID: UUID
        /// The connection the run went out on (`ServerConnection.connectionSerial`).
        var serial: Int
        var action: String
        /// The title to show for it.
        var title: String
        var started: Date
        /// Its `client.action` hasn't answered yet.
        var inFlight = true
        /// This phone answered a prompt from this run (an action that asks twice).
        var answered = false
    }

    /// How long after a run starts a prompt counts as its own.
    static let window: TimeInterval = 10

    private(set) var runs: [Run] = []
    private var next = 0

    /// A run left this phone. Returns its id, for `ended`.
    mutating func started(server: UUID, serial: Int, action: String, title: String, at date: Date) -> Int {
        next += 1
        runs.append(Run(id: next, serverID: server, serial: serial, action: action, title: title, started: date))
        // Runs that answered and are out of the window can't own a prompt any more.
        runs.removeAll { !$0.inFlight && date.timeIntervalSince($0.started) > Self.window }
        if runs.count > 32 { runs.removeFirst(runs.count - 32) }
        return next
    }

    /// The run's `client.action` answered (or failed).
    mutating func ended(_ id: Int) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].inFlight = false
    }

    /// This phone answered a prompt of run `id`; the run may ask again.
    mutating func answered(_ id: Int) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].answered = true
    }

    /// The run a prompt belongs to, or nil to decline it: same server, same connection, same
    /// action, its `client.action` still waiting, and started within the window (or answered
    /// from here since). A prompt with no action, or of a kind the app can't show, or one that
    /// arrives while the tent board shows, is never the phone's.
    func owner(of p: PromptRequest, server: UUID, now: Date, boardShown: Bool) -> Run? {
        guard !boardShown, p.isKnownKind, let action = p.action else { return nil }
        return runs.last { r in
            r.serverID == server && r.serial == p.connectionSerial && r.action == action && r.inFlight
                && (r.answered || now.timeIntervalSince(r.started) <= Self.window)
        }
    }
}

/// One question on screen, read from its event: what the palette's prompt state draws.
struct PalettePrompt: Identifiable {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var subtitle: String?
        var detail: String?
        var symbol: String
    }

    enum Kind: Equatable {
        case input(placeholder: String?, value: String?)
        case pick(items: [Item], multiple: Bool, allowOther: Bool, selected: Set<String>)
    }

    var id: String { callID }
    var callID: String
    var serverID: UUID
    var serial: Int
    var runID: Int
    var title: String
    /// The action's title, as the keymap lists it: the heading's subtitle.
    var actionTitle: String
    var confirm: String?
    var kind: Kind
    /// When to stop showing it, from its arrival.
    var deadline: Date

    init?(_ r: PromptRequest, serverID: UUID, runID: Int, actionTitle: String) {
        let p = r.prompt
        let kind: Kind
        switch r.kind {
        case "input":
            kind = .input(placeholder: p.str("placeholder"), value: p.str("value"))
        case "pick":
            let multiple = p.bool("multiple") ?? false
            let items = p.arr("items").compactMap { o -> Item? in
                guard let id = o.str("id"), !id.isEmpty else { return nil }
                return Item(id: id, title: o.str("title") ?? id, subtitle: o.str("subtitle"), detail: o.str("detail"),
                            symbol: Self.symbol(o.str("icon")))
            }
            let selected = multiple ? Set(p.arr("items").filter { $0.bool("selected") == true }.compactMap { $0.str("id") }) : []
            kind = .pick(items: items, multiple: multiple, allowOther: !multiple && p.bool("allow_other") == true, selected: selected)
        default:
            return nil
        }
        callID = r.callID
        self.serverID = serverID
        serial = r.connectionSerial
        self.runID = runID
        title = p.str("title") ?? actionTitle
        self.actionTitle = actionTitle
        confirm = p.str("confirm").flatMap { $0.isEmpty ? nil : $0 }
        self.kind = kind
        deadline = r.receivedAt.addingTimeInterval(Double(max(r.timeoutMS, 0)) / 1000)
    }

    /// The SF Symbol for an item's `icon`, a generic one for a name this build doesn't know.
    static func symbol(_ icon: String?) -> String {
        switch icon {
        case "document": "doc"
        case "folder": "folder"
        case "branch": "arrow.triangle.branch"
        case "terminal": "terminal"
        case "code": "chevron.left.forwardslash.chevron.right"
        case "server": "server.rack"
        case "database": "cylinder"
        case "package": "shippingbox"
        case "globe": "globe"
        case "link": "link"
        case "person": "person"
        case "tag": "tag"
        case "clock": "clock"
        case "star": "star"
        case "gear": "gearshape"
        case "plus": "plus"
        default: "circle"
        }
    }

    // MARK: Replies (`client.reply`)

    static func reply(_ callID: String, result: JSONObject) -> JSONObject { ["call_id": callID, "result": result] }
    static func text(_ callID: String, _ text: String) -> JSONObject { reply(callID, result: ["text": text]) }
    static func ids(_ callID: String, _ ids: [String]) -> JSONObject { reply(callID, result: ["ids": ids]) }
    static func cancel(_ callID: String) -> JSONObject { reply(callID, result: ["cancelled": true]) }
}

/// Prompts taken while another shows wait their turn; each keeps its own deadline.
struct PromptQueue {
    private(set) var shown: PalettePrompt?
    private(set) var waiting: [PalettePrompt] = []

    /// True when it shows now.
    mutating func add(_ p: PalettePrompt) -> Bool {
        guard shown != nil else { shown = p; return true }
        waiting.append(p)
        return false
    }

    /// Takes a prompt away (answered, ended, timed out). Returns the one to show next, if the
    /// shown one went and another waits whose time hasn't run out.
    mutating func remove(_ callID: String, now: Date) -> PalettePrompt? {
        waiting.removeAll { $0.callID == callID }
        guard shown?.callID == callID else { return nil }
        shown = nil
        waiting.removeAll { $0.deadline <= now }
        guard !waiting.isEmpty else { return nil }
        shown = waiting.removeFirst()
        return shown
    }

    /// A new connection on `server`: its `call_id`s mean nothing now. Returns the prompts dropped.
    mutating func dropAll(server: UUID) -> [PalettePrompt] {
        var gone = waiting.filter { $0.serverID == server }
        waiting.removeAll { $0.serverID == server }
        if let s = shown, s.serverID == server { gone.insert(s, at: 0); shown = nil }
        return gone
    }

    /// After `dropAll` took the shown one: the next to show.
    mutating func advance(now: Date) -> PalettePrompt? {
        guard shown == nil else { return nil }
        waiting.removeAll { $0.deadline <= now }
        guard !waiting.isEmpty else { return nil }
        shown = waiting.removeFirst()
        return shown
    }
}
