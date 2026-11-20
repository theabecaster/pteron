import Foundation
import GlanceModel
import RexKit

/// What sign-up needs from a computer's Rex connection: who is connected there and one call to
/// its helper. The app's servers in the app (`ServerHelpers`); a stand-in in tests.
@MainActor
protocol HelperChannel: AnyObject {
    /// Every computer in the app.
    var computers: [UUID] { get }
    /// Counts the computer's connections, so work done for one can be told from the next. Nil
    /// while the computer cannot be reached.
    func connection(_ computer: UUID) -> Int?
    /// The app's own Rex client id on that connection.
    func clientID(_ computer: UUID) -> String?
    func name(_ computer: UUID) -> String
    /// The computer's clients (`client.list`). Nil when the call failed.
    func clients(_ computer: UUID) async -> [JSONObject]?
    /// One action of the helper that is the client `relay`.
    func perform(_ computer: UUID, relay: String, action: String, args: JSONObject, timeout: Int) async -> Result<JSONObject, HelperFailure>
}

/// What the person wants for one computer, with what iOS allows.
enum PushIntent: Equatable, Sendable {
    /// Nothing is to be done there now: its Beacon is being removed.
    case leaveAlone
    /// The master switch or the computer's own is off: its helper sends this phone nothing.
    case paused
    /// On, and iOS has not allowed notifications or has given no address yet.
    case waiting
    /// On: the computer's helper holds a secret that reaches this phone at `token`.
    case on(token: String)
}

/// How long to wait before the next automatic try.
enum PushBackoff {
    /// The first wait; each one after it is twice as long.
    static let first: TimeInterval = 2
    static let longest: TimeInterval = 300
    /// Automatic tries for one computer in one stay of the app in front.
    static let tries = 6

    /// `failures` is how many tries in a row have failed (1 for the first). `fraction` (0 up to
    /// 1) spreads phones apart by up to half a wait more. A longer `Retry-After` wins.
    static func delay(failures: Int, retryAfter: TimeInterval?, fraction: Double) -> TimeInterval {
        let doubled = first * pow(2, Double(max(failures, 1) - 1))
        let spread = min(doubled * (1 + 0.5 * min(max(fraction, 0), 1)), longest)
        return max(spread, retryAfter ?? 0)
    }
}

/// Owns signing this phone up for notifications. It compares what the person wants
/// (`PushIntent`, per computer) with what is true and does the first missing step, with the
/// fewest writes:
///
/// 1. Off: the computer's helper is paused (`set_push_paused`), now or when it next connects.
///    Nothing else, and nothing at the gateway.
/// 2. On without the iOS permission or an address: nothing.
/// 3. The gateway holds this phone's device with the current APNs token, else one `PUT`.
/// 4. The computer has a secret the gateway confirmed, else one `PUT`.
/// 5. The computer's helper holds that secret and is not paused, else `register_push` or
///    `set_push_paused`.
///
/// The phone chooses the owner key, the device id and each secret, and writes them to the store
/// before the request that uses them, so a request sent again (after a lost answer, or by an app
/// that was closed in between) is the same request and makes nothing new. A switch only pauses
/// and resumes; a secret is deleted only when Beacon is removed, when a changed Beacon is
/// trusted, and when the computer is removed from the app.
///
/// Runs for one computer never overlap, and a trigger during a run asks for one more after it.
/// A failed try is made again by itself after `PushBackoff.delay`, `PushBackoff.tries` times;
/// then the computer waits for the person.
@MainActor
@Observable
final class PushReconciler {
    /// What we know of a computer's helper, for Settings.
    enum Helper: Equatable {
        case missing
        /// `pushEnabled` is false while the helper runs with `--dry-run`.
        case running(pushEnabled: Bool)
        /// A helper from before the gateway: it wants an APNs token, which the app does not give out.
        case outdated
        /// The helper proved another key than the one pinned for this computer, or an install
        /// there ended without the helper's setup proof. It gets nothing until the person
        /// trusts it in Settings.
        case identityChanged
        /// A sentence about what went wrong.
        case failed(String)
    }

    /// Who starts a run.
    enum Trigger: Equatable {
        /// The app: launch, return to the front, a connection, a network change, a new address.
        /// It does nothing for a computer whose tries are used up or whose next try is set.
        case automatic
        /// The person: a switch, Retry, Trust, an install. The tries start over.
        case person
        /// The next try after a failed one.
        case retry
    }

    /// What one request for a helper's setup proof came to.
    enum SetupReply: Equatable {
        /// Nothing was asked: no helper is connected yet, or the phone isn't ready to register.
        case notAsked
        /// The helper answered without a proof, or didn't answer.
        case missing
        /// The helper answered with a proof that isn't this run's, or couldn't prove its key.
        case wrong
        /// The helper showed the proof and does not hold its secret yet.
        case proven
        /// The helper showed the proof, its key is pinned and it holds its secret.
        case registered
    }

    /// The gateway turned a request away for now.
    struct Limit: Equatable {
        /// When it takes requests again, if it said.
        var retryAt: Date?
    }

    /// This phone, as helpers and the gateway know it.
    struct Phone {
        var deviceID: String
        var environment: String
        var deviceName: @MainActor () -> String
    }

    // MARK: What Settings shows

    private(set) var helpers: [UUID: Helper] = [:]
    /// Computers where a try failed and the next one is on its way.
    private(set) var retrying: Set<UUID> = []
    /// Computers whose automatic tries are used up. They wait for Retry.
    private(set) var stopped: Set<UUID> = []
    /// Computers whose helper said something is off (it lost the phone, or holds it paused)
    /// while the app puts it right.
    private(set) var mending: Set<UUID> = []
    /// Computers the gateway took no secret for because the phone's device holds as many as it
    /// may. They wait for Retry.
    private(set) var full: Set<UUID> = []
    private(set) var limit: Limit?
    /// Why the last request to the gateway failed. Cleared by the next one that works.
    private(set) var problem: GatewayError?

    // MARK: What it is given

    /// What the person wants for a computer. The registrar sets it.
    @ObservationIgnored var intent: @MainActor (UUID) -> PushIntent = { _ in .waiting }
    /// A computer's helper holds its secret: the registrar reads its status and tells it
    /// whether the app is in front. The second value is the version the helper gave in its
    /// answer to the registration (`helper_version`), nil when it only resumed or gave none.
    @ObservationIgnored var registered: @MainActor (UUID, String?) -> Void = { _, _ in }
    /// Whether a computer is the person's own: true only when its owner and this phone's login
    /// are both known and equal, false when both are known and differ, nil when it can't be
    /// told. It is the `presence` flag of the computer's secret at the gateway; nil sends none.
    /// Only true gives the computer's helper the phone's presence key (`register_push`).
    @ObservationIgnored var ownership: @MainActor (UUID) -> Bool? = { _ in nil }

    @ObservationIgnored private let gateway: PushGateway?
    @ObservationIgnored private let store: RegistrationStore
    @ObservationIgnored private let channel: HelperChannel
    @ObservationIgnored private let prefs: Prefs
    @ObservationIgnored private let phone: Phone
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async -> Void
    @ObservationIgnored private let random: PushRandom

    // MARK: Its own state

    @ObservationIgnored private var links: [UUID: Link] = [:]
    @ObservationIgnored private var running: Set<UUID> = []
    /// Computers that were triggered during their run, and by whom.
    @ObservationIgnored private var again: [UUID: Trigger] = [:]
    /// Failed tries in a row, per computer.
    @ObservationIgnored private var failures: [UUID: Int] = [:]
    /// The next try of a computer, while it waits.
    @ObservationIgnored private var pending: [UUID: Task<Void, Never>] = [:]
    /// The gateway asked for no request before this time (`Retry-After`).
    @ObservationIgnored private var notBefore: Date?
    /// The one request for the device that is under way; every computer shares its answer.
    @ObservationIgnored private var deviceRequest: Task<Result<GatewayRegistration, Stop>, Never>?
    /// Computers where an install of the helper has sent its setup code, with that code. While
    /// one is here, the computer's helper is registered only after it showed that run's proof.
    @ObservationIgnored private var setups: [UUID: String] = [:]
    /// The key of the helper that showed the proof during a computer's install.
    @ObservationIgnored private var provenKeys: [UUID: String] = [:]
    /// Computers whose install's proven helper holds its secret.
    @ObservationIgnored private var setupRegistered: Set<UUID> = []
    /// Computers where an install ended without a proof. Their helper waits for "Trust" even
    /// when no key is pinned. Kept while the app runs.
    @ObservationIgnored private var heldBack: Set<UUID> = []
    /// Stored entries of computers the app does not list (`PushOrphans`), from `computersLoaded`
    /// until each is taken over or retired. Nil before the computers are loaded.
    @ObservationIgnored private var orphans: Set<String>?
    /// Computers whose helper has shown its key on a connection since launch, or that have none.
    @ObservationIgnored private var examined: Set<UUID> = []
    /// The `presence` flag last sent with each computer's secret since launch, and whether the
    /// gateway took the request (`flagOwnership`).
    @ObservationIgnored private var flags: [UUID: SentFlag] = [:]
    /// The end of the orphans' wait, once a computer is listed.
    @ObservationIgnored private var orphanDeadline: Task<Void, Never>?

    /// One connection's view of a computer's helper. A new connection starts a fresh one. A
    /// class, so a run that is waiting on the network and a reply that arrives meanwhile change
    /// the same one.
    @MainActor
    private final class Link {
        let connection: Int
        /// The helper found on this connection.
        var relay: String?
        /// The secret this helper said it took, on this connection.
        var held: String?
        /// Whether the helper is paused for this phone, once it said.
        var paused: Bool?
        /// The helper knows `set_push_paused`. One that does not is paused by unregistering and
        /// resumed by registering with the same secret.
        var pauses = true
        /// The key a helper offered that differs from the pinned one, kept for "Trust".
        var offeredKey: String?
        /// How often the helper said it holds nothing for this phone after it took the secret.
        var lost = 0
        /// Whether the registration this helper took on this connection was one for a computer
        /// of the person's own, which carries the presence key. Nil before any.
        var keyed: Bool?

        init(connection: Int) { self.connection = connection }
    }

    private struct SentFlag: Equatable {
        var secretID: String
        var presence: Bool
        var taken: Bool
    }

    /// Why a step did not finish.
    private enum Stop: Error, Equatable {
        case gateway(GatewayError)
        /// The gateway asked for no request before this time. Nothing was sent.
        case wait(Date)
        /// The helper did not answer as expected, or its connection is gone.
        case helper
        /// The phone's device holds as many secrets as it may, so this computer got none.
        case full(UUID)
    }

    private enum Outcome: Equatable {
        /// Nothing is missing, or nothing can be done for this computer now.
        case settled
        case failed(retryAfter: TimeInterval?)
        /// Nothing was sent; try at this time.
        case wait(Date)
        /// It failed and the app does not try again by itself: the computer waits for Retry.
        case stopped
    }

    /// How often on one connection a helper may say it lost this phone before it is left alone,
    /// so two sides that disagree can't keep each other busy.
    static let lossesPerConnection = 2

    init(gateway: PushGateway?, store: RegistrationStore, channel: HelperChannel, prefs: Prefs, phone: Phone,
         now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         random: PushRandom = .system) {
        self.gateway = gateway
        self.store = store
        self.channel = channel
        self.prefs = prefs
        self.phone = phone
        self.now = now
        self.sleep = sleep
        self.random = random
    }

    // MARK: Triggers

    /// Brings every computer in line. The app calls it at launch, on its return to the front,
    /// on a network change, for a new APNs token and after the master switch.
    func reconcileAll(by who: Trigger = .automatic) {
        if hasRetired { Task { await self.deleteRetired() } }
        watchOrphans()
        for id in channel.computers { trigger(id, by: who) }
    }

    // MARK: Entries of computers the app no longer lists

    /// The app's computers are loaded, once per launch: every stored entry that belongs to none
    /// of them is set aside. A computer whose helper proves the key pinned in one takes it over,
    /// secret and all, with no request to the gateway. The rest are retired at the end of the
    /// first pass in which every listed computer's helper was looked at, or `PushOrphans.wait`
    /// after a computer is listed, whichever is first. With no computer listed they stay as
    /// they are.
    func computersLoaded() {
        guard orphans == nil else { return }
        orphans = PushOrphans.setAside(record, listed: channel.computers)
        watchOrphans()
    }

    /// The orphans no listed computer owns now.
    private var unclaimed: Set<String> {
        (orphans ?? []).subtracting(channel.computers.map(\.uuidString))
    }

    /// Starts the orphans' wait once a computer is listed.
    private func watchOrphans() {
        guard orphanDeadline == nil, !unclaimed.isEmpty, !channel.computers.isEmpty else { return }
        let sleep = sleep
        orphanDeadline = Task { [weak self] in
            await sleep(PushOrphans.wait)
            guard !Task.isCancelled else { return }
            await self?.retireOrphans()
        }
    }

    /// The pass is over once every listed computer was looked at: what is left is retired.
    private func orphanPassEnded() async {
        guard !unclaimed.isEmpty, !channel.computers.isEmpty, examined.isSuperset(of: channel.computers) else { return }
        await retireOrphans()
    }

    /// The orphans that were not taken over leave the store, and their secrets are deleted at
    /// the gateway, now or on a later `deleteRetired`.
    private func retireOrphans() async {
        let left = unclaimed
        orphans = []
        orphanDeadline?.cancel()
        orphanDeadline = nil
        guard !left.isEmpty, (try? edit { PushOrphans.retire(left, in: &$0) }) != nil else { return }
        await deleteRetired()
    }

    /// A helper proved `helperKey` on a computer that has no entry: the orphan pinned to that
    /// key becomes the computer's.
    private func adoptOrphan(_ id: UUID, helperKey: String) {
        guard let stored = record, stored.servers[id.uuidString] == nil,
              let orphan = PushOrphans.match(helperKey, among: unclaimed, in: stored),
              (try? edit { PushOrphans.adopt(orphan, for: id, in: &$0) }) != nil else { return }
        orphans?.remove(orphan)
    }

    /// The app is in front again: each computer has its automatic tries again.
    func cameToFront() {
        failures = [:]
        // A computer the gateway has no room for stays as it is until the person asks.
        if stopped != full { stopped = stopped.intersection(full) }
        // A flag the gateway did not take is sent once more in this stay.
        flags = flags.filter { $0.value.taken }
        reconcileAll()
    }

    func trigger(_ id: UUID, by who: Trigger = .automatic) {
        Task { await self.run(id, by: who) }
    }

    /// One run for a computer, or a note for one more after the run that is under way.
    func run(_ id: UUID, by who: Trigger = .automatic) async {
        switch who {
        case .person:
            failures[id] = nil
            stopped.remove(id)
            pending.removeValue(forKey: id)?.cancel()
            links[id]?.lost = 0
            full.remove(id)
            if case .failed = helpers[id] { helpers[id] = nil }
        case .automatic:
            guard !stopped.contains(id), pending[id] == nil else { return }
        case .retry:
            break
        }
        guard !running.contains(id) else {
            if again[id] != .person { again[id] = who }
            return
        }
        running.insert(id)
        let outcome = await step(id)
        if outcome == .settled { await flagOwnership(id) }
        running.remove(id)
        settle(id, outcome)
        watchOrphans()
        await orphanPassEnded()
        if let next = again.removeValue(forKey: id) { await run(id, by: next) }
    }

    /// The computer's connection is new, or a helper joined or left it: what was known of the
    /// helper there is dropped and looked at again.
    func helperChanged(_ id: UUID) {
        if let link = links[id] {
            link.relay = nil
            link.held = nil
            link.paused = nil
            link.offeredKey = nil
            link.lost = 0
        }
        trigger(id)
    }

    /// A registered helper said it holds nothing for this phone (`registered: false`). It gets
    /// the stored secret again; the gateway is not asked.
    func helperLost(_ id: UUID) {
        guard let link = links[id], link.held != nil, case .on = intent(id) else { return }
        if !mending.contains(id) { mending.insert(id) }
        link.held = nil
        link.lost += 1
        guard link.lost <= Self.lossesPerConnection else {
            set(id, .failed("\(Brand.beaconName) on \(channel.name(id)) keeps losing this iPhone."))
            if !stopped.contains(id) { stopped.insert(id) }
            mending.remove(id)
            return
        }
        trigger(id, by: .retry)
    }

    /// A helper said it is paused for this phone although the computer is on (`helper_status`,
    /// or the `paused` answer to a test): it resumes. What the app believed of it does not
    /// matter; the helper's word does. Said again and again on one connection, it is left alone
    /// like a helper that keeps losing the phone, unless the person asked.
    func helperPaused(_ id: UUID, by who: Trigger = .retry) {
        guard let link = links[id], link.connection == channel.connection(id), case .on = intent(id) else { return }
        // Counted only when the app took it for resumed: an answer that was on its way while
        // the switch moved says nothing about a helper that disagrees.
        let disagrees = link.paused == false
        link.paused = true
        if who != .person, disagrees {
            link.lost += 1
            guard link.lost <= Self.lossesPerConnection else {
                set(id, .failed("\(Brand.beaconName) on \(channel.name(id)) keeps pausing this iPhone."))
                if !stopped.contains(id) { stopped.insert(id) }
                return
            }
        }
        if !mending.contains(id) { mending.insert(id) }
        trigger(id, by: who)
    }

    /// A helper said the gateway no longer takes its secret for this phone: the phone's address
    /// was dead. The device and every computer's secret go to the gateway again, once each,
    /// under the same owner key and ids.
    func addressDied(_ id: UUID) {
        links[id]?.held = nil
        heal(replacingSecretOf: id)
        trigger(id, by: .person)
    }

    // MARK: What the registrar reads

    /// The helper on the computer's current connection, once it holds its secret. Nothing else
    /// is asked for its status or told to update.
    func relay(_ id: UUID) -> String? {
        guard let link = links[id], link.connection == channel.connection(id), link.held != nil else { return nil }
        return link.relay
    }

    func isRelay(_ client: String, on id: UUID) -> Bool { links[id]?.relay == client }

    /// The phone holds a secret for the computer's helper.
    func hasSecret(_ id: UUID) -> Bool { record?.servers[id.uuidString]?.pushSecret != nil }

    /// The helper on the computer's current connection has confirmed that it holds the phone's
    /// secret and is not paused.
    func isSettled(_ id: UUID) -> Bool {
        guard let link = links[id], link.connection == channel.connection(id) else { return false }
        return link.held != nil && link.paused == false
    }

    /// A run for the computer is under way or asked for.
    func isBusy(_ id: UUID) -> Bool { running.contains(id) || again[id] != nil }

    // MARK: Pausing

    /// The computer was turned off (its own switch, or the master switch): its helper is told
    /// to pause this phone, now or the next time it is connected. Nothing is deleted.
    func pause(_ id: UUID) {
        if hasSecret(id) { prefs.helpersToTell.insert(id) }
        trigger(id, by: .person)
    }

    /// The computer was turned on again. A pause that never reached its helper is dropped.
    func resume(_ id: UUID) async {
        if prefs.helpersToTell.contains(id) { prefs.helpersToTell.remove(id) }
        await run(id, by: .person)
    }

    // MARK: Taking a secret back

    /// The computer's secret stops working and is never handed out again: the phone drops it at
    /// once, and the gateway deletes it now or, when it can't be reached, on a later
    /// `deleteRetired`. Only for a Beacon that is removed and a computer removed from the app
    /// (`keepPin: false` then also forgets the helper's key).
    func revoke(_ id: UUID, keepPin: Bool) async {
        let key = id.uuidString
        links[id]?.held = nil
        prefs.helpersToTell.remove(id)
        guard let stored = try? store.load(), let entry = stored.servers[key] else { return }
        var changed = stored
        changed.servers[key] = keepPin ? ServerPush(helperKey: entry.helperKey) : nil
        // Only a registration the gateway may still hold has something to delete there.
        if let secret = entry.secretID, stored.ended != true { changed.retired = (stored.retired ?? []) + [secret] }
        guard changed != stored, (try? store.save(changed)) != nil else { return }
        await deleteRetired()
    }

    /// Deletes at the gateway the secrets that were taken back and are still listed there. One
    /// the gateway no longer has counts as deleted.
    func deleteRetired() async {
        guard let gateway, let r = record, let ids = r.retired, waitUntil == nil else { return }
        for id in ids {
            do {
                try await gateway.deleteSecret(r, secretID: id)
            } catch GatewayError.unknownRegistration, GatewayError.rejected(404) {
                // Already gone.
            } catch {
                if let e = error as? GatewayError { note(e) }
                return
            }
            _ = try? edit(r.device) {
                $0.retired?.removeAll { $0 == id }
                if $0.retired?.isEmpty == true { $0.retired = nil }
            }
        }
    }

    /// Secrets are waiting to be deleted at the gateway.
    var hasRetired: Bool { record?.retired?.isEmpty == false }

    /// The key the computer's helper offers in place of the pinned one, on the computer's
    /// current connection. The confirm before "Trust" is shown for this key.
    func offeredKey(_ id: UUID) -> String? {
        guard helpers[id] == .identityChanged, let link = links[id], link.connection == channel.connection(id) else { return nil }
        return link.offeredKey
    }

    /// "Trust" in Settings, for a helper whose key changed: right when the helper was
    /// reinstalled on that computer. `key` is the key the confirm was shown for, and only that
    /// key is pinned: the secret the old helper held is deleted, `key` becomes the pin, and the
    /// helper that proves it gets a new secret. False, with nothing changed, when the helper
    /// offers another key by now; the row then still asks for "Trust", for the key offered now.
    @discardableResult
    func trust(_ id: UUID, key: String) async -> Bool {
        guard let link = links[id], offeredKey(id) == key else { return false }
        guard replacePin(id, with: key) else {
            note(.storeFailed)
            return false
        }
        link.offeredKey = nil
        heldBack.remove(id)
        helpers[id] = nil
        await deleteRetired()
        await run(id, by: .person)
        return true
    }

    /// The computer left the app.
    func forget(_ id: UUID) {
        links[id] = nil
        helpers[id] = nil
        mending.remove(id)
        retrying.remove(id)
        stopped.remove(id)
        full.remove(id)
        examined.remove(id)
        failures[id] = nil
        flags[id] = nil
        pending.removeValue(forKey: id)?.cancel()
        setups[id] = nil
        provenKeys[id] = nil
        setupRegistered.remove(id)
        heldBack.remove(id)
        Task { await self.revoke(id, keepPin: false) }
    }

    /// Nothing is known of the computer's helper any more (its Beacon was removed).
    func clear(_ id: UUID) {
        links[id] = nil
        helpers[id] = nil
        mending.remove(id)
        full.remove(id)
        heldBack.remove(id)
    }

    // MARK: An install of the helper

    /// An install on this computer has typed its setup code into the installer: from now until
    /// `setupEnded`, the computer's helper is registered only after it showed the proof for
    /// `code`. What this connection knew of a helper is dropped, since the install replaces it.
    func beginSetup(_ id: UUID, code: String) {
        setups[id] = code
        provenKeys[id] = nil
        setupRegistered.remove(id)
        if let link = links[id] {
            link.relay = nil
            link.held = nil
            link.paused = nil
            link.offeredKey = nil
        }
    }

    /// Asks the helper now connected on this computer for the proof that the install started
    /// it, once. With a valid proof the helper's key becomes the computer's pin, also in place
    /// of one pinned before, and the helper is signed up. Without one nothing is pinned and
    /// nothing is handed over.
    func prove(_ id: UUID) async -> SetupReply {
        guard let code = setups[id], !running.contains(id), let serial = channel.connection(id),
              case .on(let token) = intent(id) else { return .notAsked }
        running.insert(id)
        let link = link(id, serial)
        let reply = await proof(id, link, code: code)
        var outcome = Outcome.settled
        if reply == .proven { outcome = await signUp(id, link, token: token) }
        running.remove(id)
        settle(id, outcome)
        if let next = again.removeValue(forKey: id) { trigger(id, by: next) }
        return reply == .proven && setupRegistered.contains(id) ? .registered : reply
    }

    private func proof(_ id: UUID, _ link: Link, code: String) async -> SetupReply {
        guard case .found(let relay) = await find(id, link), let me = channel.clientID(id) else { return .notAsked }
        // A fresh challenge each time, so an old answer can't be replayed.
        let challenge = HelperIdentity.challenge()
        let setupChallenge = HelperIdentity.challenge()
        let asked = await channel.perform(id, relay: relay, action: "helper_identity",
                                          args: ["challenge": challenge, "device_id": phone.deviceID, "setup_challenge": setupChallenge],
                                          timeout: 5000)
        guard case .success(let reply) = asked, link === links[id], setups[id] == code else { return .missing }
        guard case .success(let key) = HelperIdentity.verify(reply: reply, challenge: challenge, called: relay, requester: me,
                                                             device: phone.deviceID) else { return .wrong }
        // Only the helper this install started can answer the setup challenge: the key of the
        // answer is the code the installer handed it.
        switch SetupProof.answer(proof: reply.str("setup_proof"), code: code, challenge: setupChallenge, helper: relay, requester: me) {
        case .missing:
            link.offeredKey = key
            return .missing
        case .wrong:
            link.offeredKey = key
            return .wrong
        case .valid:
            provenKeys[id] = key
            heldBack.remove(id)
            link.offeredKey = nil
            return .proven
        }
    }

    /// The helper that showed the proof holds its secret. Asks once more when it does not yet.
    func setupRegistered(_ id: UUID) async -> Bool {
        if !setupRegistered.contains(id) { await run(id) }
        return setupRegistered.contains(id)
    }

    /// The install on this computer ended without the helper's proof: the helper there gets
    /// nothing until the person trusts it in Settings, as a helper whose key changed.
    func setupUnproven(_ id: UUID) {
        heldBack.insert(id)
        if let link = links[id], link.connection == channel.connection(id), link.offeredKey != nil {
            link.held = nil
            set(id, .identityChanged)
        }
    }

    /// The install is over, whichever way: sign-up follows the usual rules again.
    func setupEnded(_ id: UUID) {
        setups[id] = nil
        provenKeys[id] = nil
        setupRegistered.remove(id)
    }

    // MARK: One run

    private func step(_ id: UUID) async -> Outcome {
        guard let serial = channel.connection(id) else { return .settled }
        let link = link(id, serial)
        switch intent(id) {
        case .leaveAlone, .waiting: return .settled
        case .paused: return await pause(id, link)
        case .on(let token): return await signUp(id, link, token: token)
        }
    }

    /// What a run came to: the tries start over, or the next one is set.
    private func settle(_ id: UUID, _ outcome: Outcome) {
        switch outcome {
        case .settled:
            failures[id] = nil
            retrying.remove(id)
            stopped.remove(id)
            mending.remove(id)
            full.remove(id)
        case .stopped:
            failures[id] = nil
            retrying.remove(id)
            mending.remove(id)
            pending.removeValue(forKey: id)?.cancel()
            if !stopped.contains(id) { stopped.insert(id) }
        case .failed(let retryAfter):
            let count = (failures[id] ?? 0) + 1
            failures[id] = count
            guard count < PushBackoff.tries else {
                retrying.remove(id)
                mending.remove(id)
                if !stopped.contains(id) { stopped.insert(id) }
                return
            }
            if !retrying.contains(id) { retrying.insert(id) }
            schedule(id, after: PushBackoff.delay(failures: count, retryAfter: retryAfter, fraction: random.fraction()))
        case .wait(let date):
            schedule(id, after: max(date.timeIntervalSince(now()), 0))
        }
    }

    private func schedule(_ id: UUID, after delay: TimeInterval) {
        pending.removeValue(forKey: id)?.cancel()
        // The wait holds on to the sleeper, not to this object.
        let sleep = sleep
        pending[id] = Task { [weak self] in
            await sleep(delay)
            guard let self, !Task.isCancelled else { return }
            self.pending[id] = nil
            await self.run(id, by: .retry)
        }
    }

    /// This connection's view of a computer's helper, made on first use.
    private func link(_ id: UUID, _ serial: Int) -> Link {
        if let l = links[id], l.connection == serial { return l }
        let link = Link(connection: serial)
        links[id] = link
        return link
    }

    private func set(_ id: UUID, _ state: Helper) {
        if helpers[id] != state { helpers[id] = state }
    }

    // MARK: Step 1: paused

    /// Tells the computer's helper to pause this phone, if it has not confirmed that yet.
    private func pause(_ id: UUID, _ link: Link) async -> Outcome {
        // The helper has to hear of it when the choice waits to be told, and whenever this
        // connection knows the helper to hold the phone's secret unpaused, whatever a run that
        // was under way when the switch moved did to the list meanwhile.
        guard prefs.helpersToTell.contains(id) || (link.held != nil && link.paused != true) else { return .settled }
        if link.paused == true {
            prefs.helpersToTell.remove(id)
            return .settled
        }
        let relay: String
        switch await find(id, link) {
        case .found(let r): relay = r
        // No helper to tell: it stays in the queue for the one that joins.
        case .none: return .settled
        case .failed: return .failed(retryAfter: nil)
        }
        if link.pauses {
            switch await channel.perform(id, relay: relay, action: "set_push_paused", args: ["paused": true], timeout: 5000) {
            case .success:
                link.paused = true
            case .failure(let f) where f.code == "not_registered":
                // The helper holds nothing for this phone, so there is nothing to pause.
                link.held = nil
                link.paused = true
            case .failure(let f) where f.isUnknownAction:
                link.pauses = false
            case .failure:
                return .failed(retryAfter: nil)
            }
        }
        if !link.pauses {
            // A helper without the action: it forgets this phone, and gets the same secret
            // again when the computer is turned on.
            let asked = await channel.perform(id, relay: relay, action: "unregister_push", args: ["device_id": phone.deviceID], timeout: 5000)
            if case .failure(let f) = asked, f.code != "not_registered" { return .failed(retryAfter: nil) }
            link.held = nil
            link.paused = true
        }
        guard link === links[id] else { return .settled }
        // Turned on again while the helper was being told: the run that follows resumes it.
        if case .paused = intent(id) { prefs.helpersToTell.remove(id) }
        return .settled
    }

    // MARK: Steps 3 to 5: on

    private func signUp(_ id: UUID, _ link: Link, token: String) async -> Outcome {
        let key = id.uuidString
        // An install that sent its code decides who this computer's helper is. Until a helper
        // showed the proof, only the install's own request goes out.
        if setups[id] != nil, provenKeys[id] == nil { return .settled }
        // The computer is on: a pause that never reached its helper is over.
        if prefs.helpersToTell.contains(id) { prefs.helpersToTell.remove(id) }
        // Whether the computer is confirmed as the person's own, read once for this run.
        let own = ownership(id) == true
        // The helper holds the secret from a registration made before that was known, or
        // before it changed: it is registered once more, with the presence key or without it.
        let rekey = link.held != nil && link.keyed != own
        // Nothing is missing: no request and no write anywhere.
        if let r = record, r.holds(token: token, environment: phone.environment), let entry = r.servers[key],
           entry.unconfirmed != true, let secret = entry.pushSecret, link.relay != nil, link.held == secret, link.paused != true,
           setups[id] == nil || setupRegistered.contains(id), !rekey {
            return .settled
        }

        // 3. The device, with the address iOS gave us now.
        let address: String
        switch await device(token: token) {
        case .success(let r): address = r.gateway
        case .failure(let stop): return failed(stop)
        }
        guard link === links[id], channel.connection(id) == link.connection else { return .settled }

        // The helper took this secret on this connection and was paused since: it only resumes.
        if setups[id] == nil, !rekey, let entry = record?.servers[key], entry.unconfirmed != true, let held = link.held,
           held == entry.pushSecret, link.paused == true, link.pauses, let known = link.relay {
            switch await channel.perform(id, relay: known, action: "set_push_paused", args: ["paused": false], timeout: 5000) {
            case .success:
                guard link === links[id] else { return .settled }
                link.paused = false
                return holds(id, link, pushEnabled: nil)
            case .failure(let f) where f.isUnknownAction:
                link.pauses = false
            case .failure(let f) where f.code == "not_registered":
                link.held = nil
            case .failure:
                return .failed(retryAfter: nil)
            }
            guard link === links[id] else { return .settled }
        }

        // The helper proved its key and took the computer's secret on this connection. Only the
        // gateway is missing something (the phone's address was dead): it gets the secret again.
        if setups[id] == nil, !rekey, let held = link.held, held == record?.servers[key]?.pushSecret, link.paused != true {
            switch await secret(id, label: SecretLabel.make(channel.name(id))) {
            case .success(let sent) where sent == held: return .settled
            case .success: break
            case .failure(let stop): return failed(stop)
            }
            guard link === links[id], channel.connection(id) == link.connection else { return .settled }
        }

        // Who is the helper there? A fresh challenge each time, so an old answer can't be replayed.
        let relay: String
        switch await find(id, link) {
        case .found(let r): relay = r
        case .none:
            link.held = nil
            set(id, .missing)
            examined.insert(id)
            return .settled
        case .failed: return .failed(retryAfter: nil)
        }
        guard let me = channel.clientID(id) else { return .settled }
        let name = channel.name(id)
        let challenge = HelperIdentity.challenge()
        let reply: JSONObject
        switch await channel.perform(id, relay: relay, action: "helper_identity",
                                     args: ["challenge": challenge, "device_id": phone.deviceID], timeout: 5000) {
        case .success(let r): reply = r
        case .failure(let f):
            guard link === links[id] else { return .settled }
            // A helper that doesn't know the action is too old to be given anything.
            if f.isUnknownAction || f.isLegacyRefusal {
                link.held = nil
                set(id, .outdated)
                examined.insert(id)
                return .settled
            }
            set(id, .failed(f.sentence(helper: name)))
            return .failed(retryAfter: nil)
        }
        guard link === links[id] else { return .settled }
        guard case .success(let helperKey) = HelperIdentity.verify(reply: reply, challenge: challenge, called: relay, requester: me,
                                                                    device: phone.deviceID) else {
            link.held = nil
            set(id, .failed("\(Brand.beaconName) on \(name) couldn't prove its identity."))
            return .settled
        }

        // The key is proven. Outside an install, a computer with no entry takes over the entry
        // set aside at launch that is pinned to this key, and with it the secret that helper holds.
        if setups[id] == nil, !heldBack.contains(id) { adoptOrphan(id, helperKey: helperKey) }
        examined.insert(id)

        let setup: HelperAdmission.Setup = setups[id] == nil ? .none
            : provenKeys[id].map { .proven(sameKey: $0 == helperKey) } ?? .unproven
        // The code of the install this helper showed its proof for, for the registration's seal.
        let setupCode = setups[id]
        let pinned = HelperIdentity.pin(pinned: record?.servers[key]?.helperKey, offered: helperKey)
        switch HelperAdmission.decide(pin: pinned, setup: setup, heldBack: heldBack.contains(id)) {
        case .wait:
            return .settled
        case .changed:
            link.offeredKey = helperKey
            link.held = nil
            set(id, .identityChanged)
            return .settled
        case .register(.keep):
            break
        case .register(.first):
            guard (try? edit { if $0.servers[key] == nil { $0.servers[key] = ServerPush(helperKey: helperKey) } }) != nil else {
                return failed(.gateway(.storeFailed))
            }
        case .register(.replace):
            // The install replaced the helper: its key becomes the pin, and the secret the old
            // one held is deleted, as "Trust" does.
            guard replacePin(id, with: helperKey) else { return failed(.gateway(.storeFailed)) }
            await deleteRetired()
            guard link === links[id] else { return .settled }
        }

        // 4. The computer's secret.
        let secret: String
        switch await self.secret(id, label: SecretLabel.make(name)) {
        case .success(let s): secret = s
        case .failure(let stop): return failed(stop)
        }
        guard link === links[id], channel.connection(id) == link.connection else { return .settled }

        // 5. The helper holds it and is not paused.
        // The seal goes along only while the install the proof was shown for is still the one running.
        // The presence key goes along only for a computer of the person's own; every other
        // registration is sent without it.
        var args = PushRegistration.arguments(gateway: address, secret: secret, environment: phone.environment,
                                              deviceName: phone.deviceName(), deviceID: phone.deviceID,
                                              setup: setup, code: setups[id] == setupCode ? setupCode : nil,
                                              presenceKey: own ? presenceKey() : nil)
        args["paused"] = false
        switch await channel.perform(id, relay: relay, action: "register_push", args: args, timeout: 5000) {
        case .success(let r):
            guard link === links[id] else { return .settled }
            link.held = secret
            link.paused = false
            link.keyed = own
            if setup == .proven(sameKey: true), setups[id] != nil { setupRegistered.insert(id) }
            return holds(id, link, pushEnabled: r.bool("push_enabled") ?? true, version: r.str("helper_version"))
        case .failure(let f):
            guard link === links[id] else { return .settled }
            link.held = nil
            if f.isSecretDropped {
                // The gateway refused this secret: the phone's address was dead.
                heal(replacingSecretOf: id)
                return .failed(retryAfter: nil)
            }
            if f.isLegacyRefusal {
                set(id, .outdated)
                return .settled
            }
            set(id, .failed(f.sentence(helper: name)))
            return .failed(retryAfter: nil)
        }
    }

    /// The computer's helper holds its secret and is not paused.
    private func holds(_ id: UUID, _ link: Link, pushEnabled: Bool?, version: String? = nil) -> Outcome {
        if let pushEnabled {
            set(id, .running(pushEnabled: pushEnabled))
        } else if case .running = helpers[id] {
            // Resumed: what it said when it registered still stands.
        } else {
            set(id, .running(pushEnabled: true))
        }
        if !prefs.helperSeen.contains(id) { prefs.helperSeen.insert(id) }
        registered(id, version)
        return .settled
    }

    private enum Found { case found(String), none, failed }

    /// The helper on this connection: the one already found, or a look at the computer's clients.
    private func find(_ id: UUID, _ link: Link) async -> Found {
        if let relay = link.relay { return .found(relay) }
        guard let clients = await channel.clients(id), link === links[id] else { return .failed }
        guard let relay = RelayLookup.relayID(in: clients) else { return .none }
        link.relay = relay
        return .found(relay)
    }

    private func failed(_ stop: Stop) -> Outcome {
        switch stop {
        case .wait(let date): return .wait(date)
        case .helper: return .failed(retryAfter: nil)
        case .full(let id):
            note(.tooManySecrets)
            if !full.contains(id) { full.insert(id) }
            return .stopped
        case .gateway(.secretConflict):
            note(.secretConflict)
            return .stopped
        case .gateway(let error):
            note(error)
            return .failed(retryAfter: error.retryAfter)
        }
    }

    // MARK: The store

    /// The stored registration this version of the app works from.
    private var record: GatewayRegistration? {
        guard let gateway else { return nil }
        return PushRecord.adopt(try? store.load(), gateway: gateway.base.absoluteString)
    }

    /// Reads, changes and saves the record with no suspension in between, so two computers that
    /// run at the same time can't overwrite each other's entry. Fails when there is no record,
    /// or it is no longer the one for `device`. Nothing is written when nothing changed.
    @discardableResult
    private func edit(_ device: String? = nil, _ change: (inout GatewayRegistration) -> Void) throws -> GatewayRegistration {
        guard let loaded = record, device == nil || loaded.device == device else { throw GatewayError.unknownRegistration }
        var r = loaded
        change(&r)
        if r != loaded {
            do { try store.save(r) } catch { throw GatewayError.storeFailed }
        }
        return r
    }

    /// The phone's presence key: the stored one, or a new one that is written before it is
    /// handed to anyone. Nil when there is no record or the new key can't be stored; a key that
    /// would not be there after the next launch is never sent.
    private func presenceKey() -> PresenceKey? {
        if let key = record?.presenceKey { return key }
        guard let made = PresenceKey.make(random) else { return nil }
        return (try? edit { if $0.presenceKey == nil { $0.presenceKey = made } })?.presenceKey
    }

    /// `key` becomes the pin of a computer's helper. The secret the helper before it held is
    /// taken back, to be deleted at the gateway.
    private func replacePin(_ id: UUID, with key: String) -> Bool {
        let name = id.uuidString
        return (try? edit {
            if let old = $0.servers[name]?.secretID { $0.retired = ($0.retired ?? []) + [old] }
            $0.servers[name] = ServerPush(helperKey: key)
        }) != nil
    }

    // MARK: The gateway

    /// The time before which the gateway wants no request, while that time is still ahead.
    private var waitUntil: Date? {
        guard let notBefore else { return nil }
        if notBefore > now() { return notBefore }
        self.notBefore = nil
        return nil
    }

    /// A request to the gateway failed.
    private func note(_ error: GatewayError) {
        if problem != error { problem = error }
        if let wait = error.retryAfter { notBefore = now().addingTimeInterval(wait) }
        if error.isRateLimit {
            let next = Limit(retryAt: error.retryAfter.map { now().addingTimeInterval($0) })
            if limit != next { limit = next }
        }
    }

    /// The gateway answered a request.
    private func answered() {
        if problem != nil { problem = nil }
        if limit != nil { limit = nil }
        notBefore = nil
    }

    /// The device for this token, shared by every computer that asks while one request is under way.
    private func device(token: String) async -> Result<GatewayRegistration, Stop> {
        if let deviceRequest { return await deviceRequest.value }
        let task = Task { await self.ensureDevice(token: token) }
        deviceRequest = task
        let result = await task.value
        deviceRequest = nil
        return result
    }

    private func ensureDevice(token: String) async -> Result<GatewayRegistration, Stop> {
        guard let gateway else { return .failure(.gateway(.badAddress)) }
        let address = gateway.base.absoluteString
        let stored: GatewayRegistration?
        do { stored = try store.load() } catch { return .failure(.gateway(.storeFailed)) }
        var record: GatewayRegistration
        if let adopted = PushRecord.adopt(stored, gateway: address) {
            record = adopted
            if record.holds(token: token, environment: phone.environment) { return .success(record) }
        } else {
            // The owner key and the device id are chosen once and written before they are sent.
            record = PushRecord.fresh(gateway: address, keeping: stored, random: random)
            do { try store.save(record) } catch { return .failure(.gateway(.storeFailed)) }
        }
        if let waitUntil { return .failure(.wait(waitUntil)) }
        do {
            try await gateway.putDevice(record, token: token, environment: phone.environment)
        } catch GatewayError.unknownRegistration {
            // A device the phone chose is made by this very request. Only one from the earlier
            // registration route can be unknown here: the phone chooses anew, keeping who each
            // helper is.
            if !record.isPhoneChosen {
                try? store.save(PushRecord.fresh(gateway: address, keeping: record, random: random))
            }
            return .failure(.gateway(.unknownRegistration))
        } catch {
            return .failure(.gateway(error as? GatewayError ?? .unavailable(retryAfter: nil)))
        }
        answered()
        do {
            return .success(try edit(record.device) {
                $0.token = token
                $0.environment = phone.environment
                $0.unconfirmed = nil
            })
        } catch {
            return .failure(.gateway(.storeFailed))
        }
    }

    /// The computer's secret, once the gateway has confirmed it. One that is not confirmed is
    /// sent again under the same id with the same value. A value the gateway already holds in
    /// another row (`409 conflict`) is replaced by a fresh one under the same id, once; a second
    /// conflict ends the run, and the computer waits for Retry. A device that holds as many
    /// secrets as it may (`409 too_many_secrets`) ends it too, and the row says so.
    private func secret(_ id: UUID, label: String) async -> Result<String, Stop> {
        let key = id.uuidString
        guard let gateway else { return .failure(.gateway(.badAddress)) }
        guard let stored = record, var entry = stored.servers[key] else { return .failure(.gateway(.storeFailed)) }
        if let secret = entry.pushSecret, entry.secretID != nil, entry.unconfirmed != true { return .success(secret) }
        var retire: String?
        if entry.pushSecret == nil || entry.secretID?.count != PushKeys.secretIDLength {
            // None yet, or one from the earlier route that has to be stored again: the gateway
            // takes only ids of this length from the phone.
            retire = entry.secretID
            entry.secretID = PushKeys.secretID(random)
            entry.pushSecret = PushKeys.key(random)
        }
        entry.unconfirmed = true
        guard let secretID = entry.secretID, let secret = entry.pushSecret else { return .failure(.gateway(.storeFailed)) }
        // Written before it is sent.
        let saved: GatewayRegistration
        do {
            saved = try edit(stored.device) {
                $0.servers[key] = entry
                if let retire { $0.retired = ($0.retired ?? []) + [retire] }
            }
        } catch {
            return .failure(.gateway(.storeFailed))
        }
        if let waitUntil { return .failure(.wait(waitUntil)) }
        // Whose computer it is goes along, when that is known.
        let presence = ownership(id)
        var sent = (secret: secret, record: saved)
        do {
            do {
                try await gateway.putSecret(sent.record, secretID: secretID, pushSecret: sent.secret, label: label, presence: presence)
            } catch GatewayError.secretConflict {
                // The gateway holds this value in another row. A fresh one under the same id,
                // written before it is sent, and one more request.
                let fresh = PushKeys.key(random)
                guard let again = try? edit(saved.device, {
                    guard $0.servers[key]?.secretID == secretID, $0.servers[key]?.pushSecret == secret else { return }
                    $0.servers[key]?.pushSecret = fresh
                    $0.servers[key]?.unconfirmed = true
                }) else { return .failure(.gateway(.storeFailed)) }
                // The entry went away meanwhile (the computer was removed): nothing is sent for it.
                guard again.servers[key]?.pushSecret == fresh else { return .failure(.helper) }
                sent = (fresh, again)
                try await gateway.putSecret(again, secretID: secretID, pushSecret: fresh, label: label, presence: presence)
            }
        } catch GatewayError.unknownRegistration {
            // The gateway no longer has the device: it is made again first.
            heal()
            return .failure(.gateway(.unknownRegistration))
        } catch GatewayError.tooManySecrets {
            return .failure(.full(id))
        } catch {
            return .failure(.gateway(error as? GatewayError ?? .unavailable(retryAfter: nil)))
        }
        answered()
        if let presence { flags[id] = SentFlag(secretID: secretID, presence: presence, taken: true) }
        let confirmedValue = sent.secret
        do {
            let confirmed = try edit(saved.device) {
                if $0.servers[key]?.secretID == secretID, $0.servers[key]?.pushSecret == confirmedValue { $0.servers[key]?.unconfirmed = nil }
            }
            // The entry went away meanwhile (the computer was removed): nothing holds the secret.
            guard confirmed.servers[key]?.pushSecret == confirmedValue else { return .failure(.helper) }
            return .success(confirmedValue)
        } catch {
            return .failure(.gateway(.storeFailed))
        }
    }

    /// A secret the gateway confirmed before the app knew whose computer it is for, or before
    /// that changed, has no flag or the wrong one: the same secret goes to the gateway once
    /// more with the flag, which writes only the flag there. Once per computer and launch for
    /// each answer of `ownership`, and never while that is unknown, while the computer is
    /// turned off, or while the gateway asked the phone to wait. It is no part of signing up:
    /// a request that fails changes nothing here or in Settings, and is made again in the
    /// app's next stay in front.
    private func flagOwnership(_ id: UUID) async {
        let key = id.uuidString
        guard let gateway, case .on = intent(id), let presence = ownership(id), waitUntil == nil,
              let r = record, r.unconfirmed != true, let entry = r.servers[key], entry.unconfirmed != true,
              let secretID = entry.secretID, let secret = entry.pushSecret else { return }
        let flag = SentFlag(secretID: secretID, presence: presence, taken: true)
        guard flags[id]?.secretID != secretID || flags[id]?.presence != presence else { return }
        flags[id] = SentFlag(secretID: secretID, presence: presence, taken: false)
        guard (try? await gateway.putSecret(r, secretID: secretID, pushSecret: secret,
                                            label: SecretLabel.make(channel.name(id)), presence: presence)) != nil else { return }
        // The computer left the app while the request was on its way, and its secret was
        // taken back: the request may have stored it again, so it is deleted once more.
        guard record?.servers[key]?.secretID == secretID else {
            flags[id] = nil
            if (try? edit(r.device) { $0.retired = ($0.retired ?? []) + [secretID] }) != nil { await deleteRetired() }
            return
        }
        if flags[id]?.secretID == secretID, flags[id]?.presence == presence { flags[id] = flag }
    }

    /// The gateway no longer has this phone's device, or the phone's address was dead: the
    /// device and every secret are marked as not confirmed, so each is sent again once, under
    /// the same owner key and ids. `replacingSecretOf` is the computer whose helper has seen
    /// its secret refused: a helper never takes such a secret again, so that computer gets a
    /// new value under its id.
    private func heal(replacingSecretOf dropped: UUID? = nil) {
        guard let before = record else { return }
        _ = try? edit(before.device) {
            $0.unconfirmed = true
            for key in $0.servers.keys where $0.servers[key]?.secretID != nil {
                $0.servers[key]?.unconfirmed = true
            }
            if let dropped, $0.servers[dropped.uuidString]?.secretID != nil {
                $0.servers[dropped.uuidString]?.pushSecret = PushKeys.key(random)
            }
        }
        for other in channel.computers where other != dropped { trigger(other) }
    }
}
