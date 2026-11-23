#if DEBUG
import Foundation

/// `-simulateNotifications <name>` (debug builds): the Notifications screen in a named state,
/// with no server and nothing registered, for screenshots. Every row comes out of the same
/// functions the real screen uses, from facts picked here. The names are listed in
/// docs/debug-args.md; `PushRegistrar` publishes the result in place of its own rows.
struct NotificationSimulation: Equatable {
    var master: MasterStatus
    var rows: [ComputerRow]
    /// What the screen has up over its first computer when it opens.
    var presents: Presentation?

    /// A confirm or a sheet of the screen, with the computer state it belongs to. Menus are not
    /// here: iOS opens one only for a touch.
    enum Presentation: String, CaseIterable {
        case confirmRemove = "confirm-remove"
        case confirmTrust = "confirm-trust"
        case details
        case how

        /// The state of the first computer under it.
        var state: String {
            switch self {
            case .confirmRemove, .details: "healthy"
            case .confirmTrust: "changed"
            case .how: "needs-manual"
            }
        }
    }

    /// The release every simulated row is compared against, as the app's one check would give it.
    static let release = LatestRelease(version: ReleaseVersion("0.3.1")!, minVersion: ReleaseVersion("0.3.0")!)

    /// What "Show Details" shows in a simulated state.
    static let details = HelperDetails(version: "0.3.1", system: "macOS 26.1",
                                       lastNotification: .at(Date(timeIntervalSinceNow: -120)), devices: 3)

    /// The master switch's states, one per row of its table.
    static let masterStates: [(name: String, facts: MasterFacts)] = [
        ("master-off", MasterFacts(permission: .allowed, choice: false)),
        ("master-not-asked", MasterFacts(permission: .notAsked, choice: false)),
        ("master-on", MasterFacts(permission: .allowed, choice: true)),
        ("master-quiet", MasterFacts(permission: .quiet, choice: true)),
        ("master-denied", MasterFacts(permission: .denied, choice: true)),
        ("master-no-address", MasterFacts(permission: .allowed, choice: true, addressMissing: true)),
    ]

    /// A computer's states, one per row of its table, then the two results of a test. The closure
    /// gets the computer's name.
    static let computerStates: [(name: String, facts: @Sendable (String) -> ComputerFacts)] = [
        ("healthy", { ComputerFacts(name: $0) }),
        // On Beacon before the newest, by the simulated release list.
        ("update-available", { ComputerFacts(name: $0, version: "0.3.0") }),
        ("off", { ComputerFacts(name: $0, choice: false) }),
        ("offline", { ComputerFacts(name: $0, online: false) }),
        // Turned off while it could not be reached: its Beacon hears of it when it is back.
        ("turns-off", { ComputerFacts(name: $0, choice: false, online: false, pauseWaits: true) }),
        ("not-installed", { ComputerFacts(name: $0, helper: .notInstalled) }),
        ("needs-manual", { ComputerFacts(name: $0, helper: .notInstalled, setup: .manual) }),
        ("setting-up", { ComputerFacts(name: $0, helper: .notInstalled, setup: .working(.installing)) }),
        ("waiting", { ComputerFacts(name: $0, helper: .notInstalled, setup: .waitingForPerson) }),
        ("setup-failed", { ComputerFacts(name: $0, helper: .notInstalled, setup: .failed(.download)) }),
        ("too-old", { ComputerFacts(name: $0, tooOld: true) }),
        ("not-running", { ComputerFacts(name: $0, helper: .notRunning, link: .pending) }),
        // On and reachable, and its Beacon has not said which version it is yet: an empty
        // version stands for that here.
        ("connecting", { ComputerFacts(name: $0, version: "") }),
        ("reconnecting", { ComputerFacts(name: $0, link: .repairing) }),
        ("reconnect-failed", { ComputerFacts(name: $0, link: .failed) }),
        ("changed", { ComputerFacts(name: $0, changed: true, link: .pending) }),
        ("click-allow", { ComputerFacts(name: $0, setup: .clickAllow) }),
        // The notification service asked for an hour's wait.
        ("limit", { ComputerFacts(name: $0, link: .pending, limit: RateLimit(retryAt: limitAt.addingTimeInterval(3600), now: limitAt)) }),
        // The notification service holds as many computers for this phone as it takes.
        ("too-many", { ComputerFacts(name: $0, link: .pending, full: true) }),
        ("removing", { ComputerFacts(name: $0, removal: .removing) }),
        ("remove-failed", { ComputerFacts(name: $0, removal: .failed) }),
        ("updating", { ComputerFacts(name: $0, tooOld: true, updating: true) }),
        ("test-sent", { ComputerFacts(name: $0, test: .sent) }),
        ("test-failed", { ComputerFacts(name: $0, test: .failed("Wait a few seconds")) }),
    ]

    /// The moment the `limit` state's wait is counted from: noon in UTC, so an hour's wait
    /// reads the same on every run.
    static let limitAt = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400) + 12 * 3600)

    /// Fictional computers, one per state of `all`.
    static let computers = ["Studio", "Laptop", "Mini", "Workshop", "Garage", "Office", "Library", "Attic", "Den", "Loft",
                            "Cabin", "Porch", "Cellar", "Tower", "Annex", "Harbor", "Orchard", "Meadow", "Quarry", "Barn", "Forge", "Dock", "Shed",
                            "Gallery", "Pantry"]

    /// A long computer name over the longest status lines: `long-names` shows how the name
    /// wraps beside the menu and the switch, and how the lines wrap in a narrow window.
    static let longName = "Design Studio MacBook Pro"
    static let longLines: [@Sendable (String) -> ComputerFacts] = [
        { ComputerFacts(name: $0, helper: .notInstalled, setup: .failed(.notAllowed)) },
        { ComputerFacts(name: $0, helper: .notInstalled, setup: .failed(.check)) },
        { ComputerFacts(name: $0, helper: .notInstalled, setup: .waitingForPerson) },
        { ComputerFacts(name: $0, setup: .clickAllow) },
        { ComputerFacts(name: $0, changed: true, link: .pending) },
        { ComputerFacts(name: $0, test: .failed("Couldn't reach the notification service")) },
        { ComputerFacts(name: $0) },
    ]

    static var names: [String] {
        masterStates.map(\.name) + computerStates.map(\.name) + ["all", "long-names"] + Presentation.allCases.map(\.rawValue)
    }

    /// Nil for a name that isn't one of `names`.
    init?(name: String) {
        let on = MasterStatus.make(MasterFacts(permission: .allowed, choice: true))
        if name == "all" {
            self.init(master: on, rows: Self.computerStates.enumerated().map { index, state in
                Self.row(index, state.facts(Self.computers[index % Self.computers.count]))
            })
        } else if let state = Self.masterStates.first(where: { $0.name == name }) {
            // Two healthy computers, listed only where the switch lists computers.
            self.init(master: MasterStatus.make(state.facts), rows: (0..<2).map { Self.row($0, ComputerFacts(name: Self.computers[$0])) })
        } else if let state = Self.computerStates.first(where: { $0.name == name }) {
            self.init(master: on, rows: [Self.row(0, state.facts(Self.computers[0])), Self.row(1, ComputerFacts(name: Self.computers[1]))])
        } else if name == "long-names" {
            self.init(master: on, rows: Self.longLines.enumerated().map { Self.row($0, $1(Self.longName)) })
        } else if let shown = Presentation(rawValue: name), let under = Self(name: shown.state) {
            self.init(master: under.master, rows: under.rows, presents: shown)
        } else {
            return nil
        }
    }

    init(master: MasterStatus, rows: [ComputerRow], presents: Presentation? = nil) {
        self.master = master
        self.rows = rows
        self.presents = presents
    }

    /// The same id for the same place in the list on every launch.
    private static func row(_ index: Int, _ given: ComputerFacts) -> ComputerRow {
        // A helper that answers has said which version it is.
        var facts = given
        if facts.version == nil { facts.version = release.version.description }
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1)) ?? UUID()
        return ComputerRow(id: id, name: facts.name, status: ComputerStatus.make(facts.judged(against: release)))
    }
}
#endif
