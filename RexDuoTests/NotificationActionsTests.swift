import Foundation
import GlanceModel
import RexKit
import Testing
import UserNotifications
@testable import RexDuo

/// Enter and Interrupt on a question's notification: which notifications have them, how the
/// payload becomes the wait, and what the notification becomes once the action has ended.
/// The typing itself is `GlanceActions`', with a stand-in for the connection.
@MainActor
@Suite struct NotificationActionsTests {
    typealias FakeChannel = GlanceActionsTests.FakeChannel

    static let serverID = "11111111-2222-3333-4444-555555555555"
    static let address = "https://studio.example.ts.net"
    static let servers = [PushAction.Server(id: serverID, url: address, hostName: nil)]
    static let delivered = Date(timeIntervalSince1970: 1_800_000_000)
    static let changed = "The question changed. Open \(Brand.appName) to see it."
    static let failed = "Couldn't send. Open \(Brand.appName)."
    static let answered = "Already answered a moment ago. Open \(Brand.appName) if it's still waiting."

    /// The payload's own fields, as Beacon sends them for a question that names its wait.
    static let info: [String: String] = [
        "server": address, "session_id": "session:1", "window_id": "window:1", "block_id": "block:1a",
        "record": "claude", "fp": GlanceActionsTests.fp,
    ]

    static func response(_ kind: WatchAction.Kind = .enter, request: String = "1a-e40c292c", delivered: Date = delivered,
                         info: [String: String] = info) -> PushActionResponse {
        PushActionResponse(action: PushAction.identifier(kind), request: request, delivered: delivered, title: "Claude · api",
                           subtitle: "work", thread: address, info: info)
    }

    /// What was asked of Notification Center and of the system, in order.
    @MainActor
    final class Seen {
        var log: [String] = []
        var removed: [[String]] = []
        var replaced: [NotificationActions.Replacement] = []
        /// Put back without being waited for, in the moment the system's time ran out.
        var posted: [NotificationActions.Replacement] = []
        /// How often iOS was told the response was handled.
        var handled = 0
        /// Plays the moment the system's time for the background runs out.
        var expire: (@MainActor () -> Void)?
    }

    /// A connection whose status read answers only when the test lets it.
    @MainActor
    final class GatedChannel: ActionChannel {
        var calls: [String] = []
        var written: [String] = []
        var records: [String: ProgramStatus] = ["claude": ProgramStatus(GlanceActionsTests.waiting)]
        private var reading: CheckedContinuation<Void, Never>?

        func label(session: String) async -> String? { "" }

        func statuses(session: String, block: String) async -> [String: ProgramStatus]? {
            calls.append("status")
            await withCheckedContinuation { reading = $0 }
            return records
        }

        /// The status read answers now, with the records as they are now.
        func answerRead() {
            reading?.resume()
            reading = nil
        }

        func write(_ text: String, session: String, block: String, within limit: TimeInterval,
                   mayWrite: @escaping @MainActor () -> Bool) async -> TerminalStream.Delivery {
            guard mayWrite() else { return .unsent }
            calls.append("write")
            written.append(text)
            return .delivered
        }

        func close() { calls.append("close") }
    }

    /// The limits that were waited for.
    actor Limits {
        var asked: [TimeInterval] = []
        func add(_ limit: TimeInterval) { asked.append(limit) }
    }

    @MainActor
    struct Rig {
        let seen = Seen()
        let limits = Limits()
        let clock = GlanceActionsTests.TestClock()
        let channel: FakeChannel?
        let typing: GlanceActions
        let actions: NotificationActions

        /// `attached`: whether the app's model is there from the start. `gated`: a connection
        /// used in place of `channel`.
        init(channel: FakeChannel? = FakeChannel(), servers: [PushAction.Server] = NotificationActionsTests.servers,
             enabled: Bool = true, attached: Bool = true, gated: GatedChannel? = nil) {
            self.channel = channel
            // Limits that pass at once, so a call that never answers ends the test quickly.
            var typingParts = GlanceActions.Parts(sleep: { _ in try? await Task.sleep(nanoseconds: 50_000_000) })
            typingParts.now = { [clock] in clock.now }
            let typing = GlanceActions(parts: typingParts)
            typing.enabled = { enabled }
            typing.channel = { [seen] action in
                seen.log.append("channel \(action.target.server)")
                return gated ?? channel
            }
            self.typing = typing
            let center = NotificationActions.Center(
                remove: { [seen] ids in
                    seen.log.append("remove")
                    seen.removed.append(ids)
                },
                replace: { [seen] replacement in
                    seen.log.append("replace")
                    seen.replaced.append(replacement)
                },
                post: { [seen] replacement in
                    seen.log.append("post")
                    seen.posted.append(replacement)
                })
            var parts = NotificationActions.Parts()
            parts.sleep = { [limits] limit in
                await limits.add(limit)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            actions = NotificationActions(center: center, parts: parts, background: { [seen] expired in
                seen.log.append("begin")
                seen.expire = expired
                return { seen.log.append("end") }
            })
            if attached { attach(servers) }
        }

        func attach(_ servers: [PushAction.Server] = NotificationActionsTests.servers) {
            actions.attach(model(servers))
        }

        /// As the app's delegate calls it: with iOS's word that the response was handled.
        func handle(_ response: PushActionResponse) async {
            await actions.handle(response) { [seen] in
                seen.handled += 1
                seen.log.append("handled")
            }
        }

        func model(_ servers: [PushAction.Server]) -> NotificationActions.Model {
            NotificationActions.Model(servers: { servers }, handle: { [typing] in await typing.take($0, mayWrite: $1) })
        }
    }

    // MARK: Which notifications have the actions

    @Test func onlyAQuestionThatNamesItsWaitHasTheTwoActions() throws {
        let categories = AppDelegate.notificationCategories
        #expect(Set(categories.map(\.identifier)) == ["AGENT_BLOCKED", "AGENT_BLOCKED_ACT", "AGENT_DONE", "NOTICE"])
        // A push from an earlier Beacon is AGENT_BLOCKED: no button that could only fail.
        for plain in categories where plain.identifier != "AGENT_BLOCKED_ACT" {
            #expect(plain.actions.isEmpty, "\(plain.identifier)")
        }
        let act = try #require(categories.first { $0.identifier == "AGENT_BLOCKED_ACT" })
        #expect(act.actions.map(\.identifier) == ["ENTER", "INTERRUPT"])
        // The watch's words.
        #expect(act.actions.map(\.title) == ["Enter", "Interrupt"])
        #expect(act.actions[0].options == [.authenticationRequired])
        #expect(act.actions[1].options == [.authenticationRequired, .destructive])
        // Neither brings the app to the front, and the category asks for nothing more.
        #expect(act.actions.allSatisfy { !$0.options.contains(.foreground) })
        #expect(act.options == [] && act.intentIdentifiers.isEmpty)
        #expect(PushAction.category == "AGENT_BLOCKED_ACT" && PushAction.plain == "AGENT_BLOCKED")
    }

    @Test func theIdentifiersNameTheTwoKindsAndNothingElse() {
        #expect(PushAction.kind("ENTER") == .enter)
        #expect(PushAction.kind("INTERRUPT") == .interrupt)
        for other in [UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier, "enter", "", "OPEN"] {
            #expect(PushAction.kind(other) == nil, "\(other)")
        }
    }

    // MARK: From the payload to the wait

    @Test func thePayloadNamesTheWaitOnTheAppsServer() {
        let target = PushAction.target(Self.info, servers: Self.servers)
        #expect(target == WatchAction.Target(server: Self.serverID, session: "session:1", block: "block:1a", record: "claude",
                                             fp: GlanceActionsTests.fp))
        // The server is found as a tapped push finds it: by the address entered, without
        // case or scheme, or by the name the server reports.
        let named = [PushAction.Server(id: "other", url: "https://mini.example.ts.net", hostName: "Studio.Example.ts.net.")]
        #expect(PushAction.target(Self.info, servers: named)?.server == "other")
        let first = [PushAction.Server(id: "a", url: "https://elsewhere.example.ts.net", hostName: nil)] + Self.servers
        #expect(PushAction.target(Self.info, servers: first)?.server == Self.serverID)
    }

    /// Hazard 6. The payload's address fits none of the app's servers, or two of them (one
    /// computer added twice, or one by its address and one by the name it reports): nothing
    /// is typed and no server is contacted. It never picks one.
    @Test func anAddressThatFitsNoServerOrTwoIsRefusedAndNeverGuessed() async {
        let twice = Self.servers + [PushAction.Server(id: "second", url: "https://STUDIO.example.ts.net/", hostName: nil)]
        let byName = Self.servers + [PushAction.Server(id: "second", url: "https://mini.example.ts.net", hostName: "studio.example.ts.net")]
        let none = [PushAction.Server(id: "x", url: "https://other.example.ts.net", hostName: nil)]
        for servers in [twice, byName, none, []] {
            #expect(PushAction.target(Self.info, servers: servers) == nil, "\(servers.map(\.id))")
            let rig = Rig(servers: servers)
            await rig.actions.handle(Self.response())
            #expect(rig.channel?.calls.isEmpty == true, "\(servers.map(\.id))")
            #expect(rig.seen.log == ["begin", "replace", "end"], "\(servers.map(\.id))")
            expectReplaced(rig, with: Self.failed, "\(servers.map(\.id))")
        }
    }

    @Test func aPayloadThatNamesNoWaitOrAnUnknownServerGivesNone() {
        // An earlier Beacon's payload: no record and no fingerprint.
        for missing in ["record", "fp", "session_id", "block_id", "server"] {
            var info = Self.info
            info[missing] = nil
            #expect(PushAction.target(info, servers: Self.servers) == nil, "no \(missing)")
            info[missing] = ""
            #expect(PushAction.target(info, servers: Self.servers) == nil, "empty \(missing)")
        }
        #expect(PushAction.target(Self.info, servers: []) == nil)
        #expect(PushAction.target(Self.info, servers: [PushAction.Server(id: "x", url: "https://other.example.ts.net", hostName: nil)]) == nil)
        // The window is not needed to type.
        var bare = Self.info
        bare["window_id"] = nil
        #expect(PushAction.target(bare, servers: Self.servers) != nil)
    }

    @Test func thePayloadsOwnFieldsAreItsStrings() {
        let userInfo: [AnyHashable: Any] = ["aps": ["alert": ["title": "t"], "category": "AGENT_BLOCKED_ACT"], "server": Self.address,
                                            "record": "claude", "fp": GlanceActionsTests.fp, "n": 7, 3: "x"]
        #expect(PushAction.fields(userInfo) == ["server": Self.address, "record": "claude", "fp": GlanceActionsTests.fp])
    }

    @Test func oneTapOnOneNotificationHasOneName() {
        let id = PushAction.actionID(request: "1a-e40c292c", delivered: Self.delivered, kind: .enter)
        #expect(id == PushAction.actionID(request: "1a-e40c292c", delivered: Self.delivered, kind: .enter))
        #expect(id != PushAction.actionID(request: "1a-e40c292c", delivered: Self.delivered, kind: .interrupt))
        #expect(id != PushAction.actionID(request: "1b-e40c292c", delivered: Self.delivered, kind: .enter))
        // The pane's next question has the same collapse id, and is another notification.
        #expect(id != PushAction.actionID(request: "1a-e40c292c", delivered: Self.delivered.addingTimeInterval(0.5), kind: .enter))
    }

    @Test func eachAnswerDecidesWhatTheNotificationBecomes() {
        #expect(PushAction.outcome(.fresh(.sent)) == .remove)
        #expect(PushAction.outcome(.fresh(.changed)) == .replace(Self.changed))
        for failed in [GlanceActions.Answer.fresh(.unreachable), .fresh(.unconfirmed), nil] {
            #expect(PushAction.outcome(failed) == .replace(Self.failed), "\(String(describing: failed))")
        }
        // The same tap again leaves the notification to the first one, whatever that one came to.
        for result in WatchActionResult.allCases {
            #expect(PushAction.outcome(.repeated(result)) == .leave, "\(result)")
        }
        // A wait another action just answered is never removed for that: put back, saying so.
        #expect(PushAction.outcome(.answered) == .replace(Self.answered))
        #expect(NotificationCopy.actionAnswered == Self.answered)
        // The words, with the product's name from its one place.
        #expect(NotificationCopy.actionChanged == Self.changed && NotificationCopy.actionFailed == Self.failed)
    }

    // MARK: The payload of each app and Beacon

    /// Hazard 7. A Beacon before the actions sends AGENT_BLOCKED with no record and no
    /// fingerprint: the app registers that category without actions, and nothing in it can
    /// be acted on. A new Beacon's payload still opens its pane by the keys an earlier app
    /// reads, which ignores the two it doesn't know; that app has no category of the new
    /// name, and iOS shows no action for a category an app didn't register.
    @Test func eachPayloadShapeIsReadByTheAppThatGetsIt() throws {
        let place: [String: Any] = ["server": Self.address, "session_id": "session:1", "window_id": "window:1", "block_id": "block:1a"]
        func aps(_ category: String) -> [String: Any] {
            ["alert": ["title": "Claude · api", "body": "Run it?"], "category": category, "interruption-level": "time-sensitive",
             "thread-id": Self.address, "sound": "default"]
        }
        let old: [AnyHashable: Any] = place.merging(["aps": aps("AGENT_BLOCKED")]) { a, _ in a }
        let new: [AnyHashable: Any] = place.merging(["aps": aps("AGENT_BLOCKED_ACT"), "record": "claude", "fp": GlanceActionsTests.fp]) { a, _ in a }
        let route = PushRoute(server: Self.address, sessionID: "session:1", windowID: "window:1", blockID: "block:1a")

        // The new app with an old Beacon: a tap opens the pane, there are no buttons, and
        // the payload names no wait.
        #expect(PushRoute(userInfo: old) == route)
        #expect(PushAction.target(PushAction.fields(old), servers: Self.servers) == nil)
        let plain = try #require(AppDelegate.notificationCategories.first { $0.identifier == "AGENT_BLOCKED" })
        #expect(plain.actions.isEmpty)

        // A new Beacon: the keys a tap reads are the same ones, so an earlier app opens the
        // pane as before, and the new app also reads the wait.
        #expect(PushRoute(userInfo: new) == route)
        #expect(PushAction.target(PushAction.fields(new), servers: Self.servers)?.record == "claude")
        // The earlier app's categories, which are this app's without the new one.
        #expect(!AppDelegate.categories.contains("AGENT_BLOCKED_ACT"))
        #expect(Set(AppDelegate.categories) == ["AGENT_BLOCKED", "AGENT_DONE", "NOTICE"])
    }

    // MARK: Typed: the notification goes

    @Test func enterIsTypedOnceAndTheNotificationIsRemoved() async {
        let rig = Rig()
        await rig.actions.handle(Self.response(.enter))
        #expect(rig.channel?.calls == ["status", "write", "close"])
        #expect(rig.channel?.written == ["\r"])
        #expect(rig.seen.removed == [["1a-e40c292c"]])
        #expect(rig.seen.replaced.isEmpty)
        // The system's time is taken first and given back last, after the notification was dealt with.
        #expect(rig.seen.log == ["begin", "channel \(Self.serverID)", "remove", "end"])
    }

    @Test func interruptTypesControlC() async {
        let rig = Rig()
        await rig.actions.handle(Self.response(.interrupt))
        #expect(rig.channel?.written == ["\u{03}"])
        #expect(rig.seen.removed == [["1a-e40c292c"]])
    }

    // MARK: Not typed: the notification comes back, quiet

    private func expectReplaced(_ rig: Rig, with words: String, _ comment: Comment? = nil) {
        #expect(rig.seen.removed.isEmpty, comment)
        #expect(rig.seen.replaced == [NotificationActions.Replacement(identifier: "1a-e40c292c", title: "Claude · api", subtitle: "work",
                                                                      body: words, thread: Self.address, info: Self.info)], comment)
        #expect(rig.seen.log.first == "begin" && rig.seen.log.suffix(2) == ["replace", "end"], comment)
    }

    @Test func aWaitThatChangedTypesNothingAndSaysSo() async {
        let changes: [JSONObject] = [
            ["id": "claude", "app": "claude", "state": "working"],
            ["id": "claude", "app": "claude", "state": "done"],
            ["id": "claude", "app": "claude", "state": "blocked", "kind": "permission", "msg": "Run it again?"],
            ["id": "claude", "app": "claude", "state": "blocked", "kind": "permission", "msg": " Run it? "],
            ["id": "claude-2", "app": "claude", "state": "blocked", "kind": "permission", "msg": "Run it?"],
        ]
        for record in changes {
            let rig = Rig()
            rig.channel?.records = [record.str("id") ?? "": ProgramStatus(record)]
            await rig.actions.handle(Self.response())
            #expect(rig.channel?.calls == ["status", "close"], "\(record)")
            #expect(rig.channel?.written.isEmpty == true, "\(record)")
            expectReplaced(rig, with: Self.changed, "\(record)")
        }
        // The pane has no status any more.
        let gone = Rig()
        gone.channel?.records = [:]
        await gone.actions.handle(Self.response(.interrupt))
        #expect(gone.channel?.written.isEmpty == true)
        expectReplaced(gone, with: Self.changed)
    }

    /// Hazard 1. The Lock Screen may have shown only the start of the question, and the
    /// agent may ask something else by the time of the tap: when the record or its
    /// fingerprint is no longer the delivered one, nothing is typed and the notification
    /// comes back saying so.
    @Test func aQuestionWhoseFingerprintOrRecordChangedAfterDeliveryIsRefusedAndReplaced() async {
        // The same record, other words: only the end of a long question differs.
        let long = String(repeating: "Do you want to run this command? ", count: 30)
        var info = Self.info
        info["fp"] = ActionGuard.fingerprint(state: "blocked", kind: "permission", message: long + "rm -rf build")
        let rig = Rig()
        rig.channel?.records = ["claude": ProgramStatus(["id": "claude", "state": "blocked", "kind": "permission", "msg": long + "rm -rf /"])]
        await rig.actions.handle(Self.response(info: info))
        #expect(rig.channel?.calls == ["status", "close"] && rig.channel?.written.isEmpty == true)
        #expect(rig.seen.removed.isEmpty && rig.seen.replaced.map(\.body) == [Self.changed])
        #expect(rig.seen.replaced.first?.identifier == "1a-e40c292c")
        // The same words under another record id.
        var other = Self.info
        other["record"] = "claude-2"
        let second = Rig()
        await second.actions.handle(Self.response(info: other))
        #expect(second.channel?.written.isEmpty == true && second.seen.replaced.map(\.body) == [Self.changed])
        // And the unchanged wait is typed, so the two above were refused for the change.
        let same = Rig()
        await same.actions.handle(Self.response())
        #expect(same.channel?.written == ["\r"])
    }

    /// Hazard 3. The agent moves on between the tap and the write (it finished, or the
    /// person answered at the computer). The status is read after the tap, and the write
    /// follows that read with nothing in between: what the read finds decides.
    @Test func anAgentThatMovedOnAfterTheTapIsNotTypedInto() async {
        for after in [["id": "claude", "app": "claude", "state": "done"] as JSONObject,
                      ["id": "claude", "app": "claude", "state": "working"],
                      ["id": "claude", "app": "claude", "state": "blocked", "kind": "question", "msg": "Which branch?"]] {
            // The tap arrives while the pane still waits; the read is under way.
            let gated = GatedChannel()
            let rig = Rig(gated: gated)
            let handled = Task { await rig.actions.handle(Self.response()) }
            while gated.calls.isEmpty { await Task.yield() }
            // Now the agent moves on, and the read answers with the pane as it is.
            gated.records = ["claude": ProgramStatus(after)]
            gated.answerRead()
            await handled.value
            #expect(gated.calls == ["status", "close"] && gated.written.isEmpty, "\(after)")
            expectReplaced(rig, with: Self.changed, "\(after)")
        }
        // A read that finds the wait is followed by the one write, and by no second read.
        let gated = GatedChannel()
        let rig = Rig(gated: gated)
        let handled = Task { await rig.actions.handle(Self.response()) }
        while gated.calls.isEmpty { await Task.yield() }
        gated.answerRead()
        await handled.value
        #expect(gated.calls == ["status", "write", "close"] && gated.written == ["\r"])
        // The computer refusing the write (the pane went in that instant) is said, not retried.
        let late = Rig()
        late.channel?.delivery = .refused
        await late.actions.handle(Self.response())
        #expect(late.channel?.calls.filter { $0 == "write" }.count == 1)
        expectReplaced(late, with: Self.changed)
    }

    /// Hazard 5. Two questions of one pane are in the list, the older still shown: only the
    /// one the pane asks now is answered; the older one's buttons type nothing.
    @Test func ofTwoQuestionsForOnePaneOnlyTheNewestIsAnswered() async {
        let older = ActionGuard.fingerprint(state: "blocked", kind: "permission", message: "Delete the branch?")
        var stale = Self.info
        stale["fp"] = older
        // The pane now asks "Run it?" under the same record.
        let rig = Rig()
        await rig.actions.handle(Self.response(request: "1a-e40c292c", delivered: Self.delivered.addingTimeInterval(-300), info: stale))
        #expect(rig.channel?.written.isEmpty == true)
        #expect(rig.seen.replaced.map(\.body) == [Self.changed] && rig.seen.removed.isEmpty)
        await rig.actions.handle(Self.response())
        #expect(rig.channel?.written == ["\r"] && rig.seen.removed == [["1a-e40c292c"]])

        // The older question came from another record, which still waits beside the newer
        // one: the pane's top record decides, and the other's buttons type nothing.
        let two = Rig()
        two.channel?.records = ["claude": ProgramStatus(GlanceActionsTests.waiting),
                                "zeta": ProgramStatus(["id": "zeta", "state": "blocked", "kind": "permission", "msg": "Delete the branch?"])]
        var zeta = Self.info
        zeta["record"] = "zeta"
        zeta["fp"] = older
        await two.actions.handle(Self.response(request: "1a-zeta", info: zeta))
        #expect(two.channel?.written.isEmpty == true && two.seen.replaced.map(\.body) == [Self.changed])
    }

    @Test func aComputerThatCannotBeReachedTypesNothingAndSaysSo() async {
        // The status can't be read.
        let unread = Rig()
        unread.channel?.records = nil
        await unread.actions.handle(Self.response())
        #expect(unread.channel?.calls == ["status", "close"])
        expectReplaced(unread, with: Self.failed)
        // The status read never answers: its limit ends it.
        let slow = Rig()
        slow.channel?.silent = ["status"]
        await slow.actions.handle(Self.response())
        #expect(slow.channel?.written.isEmpty == true)
        expectReplaced(slow, with: Self.failed)
    }

    @Test func aWriteThatFailedOrGaveNoAnswerIsNotTriedAgain() async {
        for (delivery, words) in [(TerminalStream.Delivery.unsent, Self.failed),
                                  (.unknown, Self.failed),
                                  (.refused, Self.changed)] {
            let rig = Rig()
            rig.channel?.delivery = delivery
            await rig.actions.handle(Self.response())
            #expect(rig.channel?.calls == ["status", "write", "close"], "\(delivery)")
            expectReplaced(rig, with: words, "\(delivery)")
        }
        // The write never answers.
        let silent = Rig()
        silent.channel?.silent = ["write"]
        await silent.actions.handle(Self.response())
        #expect(silent.channel?.calls.filter { $0 == "write" }.count == 1)
        expectReplaced(silent, with: Self.failed)
    }

    @Test func aServerThatIsNotTheAppsIsNeverContacted() async {
        let rig = Rig(servers: [PushAction.Server(id: "x", url: "https://other.example.ts.net", hostName: nil)])
        await rig.actions.handle(Self.response())
        #expect(rig.channel?.calls.isEmpty == true)
        #expect(rig.seen.log == ["begin", "replace", "end"])
        expectReplaced(rig, with: Self.failed)
        // No server at all, and one the app has but can make no connection to.
        let none = Rig(servers: [])
        await none.actions.handle(Self.response())
        expectReplaced(none, with: Self.failed)
        let noChannel = Rig(channel: nil)
        await noChannel.actions.handle(Self.response())
        expectReplaced(noChannel, with: Self.changed)
    }

    @Test func aPayloadWithoutAWaitTypesNothing() async {
        // Such a push has the category without actions; should an action arrive for one all
        // the same, it reaches no server.
        var info = Self.info
        info["record"] = nil
        info["fp"] = nil
        let rig = Rig()
        await rig.actions.handle(Self.response(info: info))
        #expect(rig.channel?.calls.isEmpty == true)
        #expect(rig.seen.replaced.map(\.body) == [Self.failed])
        #expect(rig.seen.replaced.first?.info == info)
    }

    @Test func aLaunchThatMustTypeNothingTypesNothing() async {
        let rig = Rig(enabled: false)
        await rig.actions.handle(Self.response())
        #expect(rig.channel?.calls.isEmpty == true)
        #expect(rig.seen.removed.isEmpty && rig.seen.replaced.count == 1)
    }

    @Test func whatIsNoActionOfOursDoesNothing() async {
        let rig = Rig()
        for other in [UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier, "OPEN"] {
            var response = Self.response()
            response.action = other
            await rig.actions.handle(response)
        }
        #expect(rig.seen.log.isEmpty && rig.channel?.calls.isEmpty == true)
    }

    // MARK: The same tap twice, and the next question

    /// A tap delivered twice: the second leaves the notification alone. While the first
    /// write is still on its way it must not say "couldn't send", and afterwards it must not
    /// undo what the first one decided.
    @Test func theSameTapTwiceTypesOnceAndTheSecondLeavesTheNotificationAlone() async {
        // One after the other: the second is answered from memory.
        let rig = Rig()
        await rig.handle(Self.response())
        await rig.handle(Self.response())
        #expect(rig.channel?.written == ["\r"])
        #expect(rig.seen.removed == [["1a-e40c292c"]] && rig.seen.replaced.isEmpty && rig.seen.posted.isEmpty)
        #expect(rig.seen.handled == 2)

        // The second arrives while the first read is still under way.
        let gated = GatedChannel()
        let both = Rig(gated: gated)
        let first = Task { await both.handle(Self.response()) }
        while gated.calls.isEmpty { await Task.yield() }
        await both.handle(Self.response())
        // It is over at once, and the notification is as it was: not removed, not replaced.
        #expect(both.seen.handled == 1)
        #expect(both.seen.removed.isEmpty && both.seen.replaced.isEmpty && both.seen.posted.isEmpty)
        gated.answerRead()
        await first.value
        #expect(gated.written == ["\r"])
        #expect(both.seen.removed == [["1a-e40c292c"]] && both.seen.replaced.isEmpty)

        // The first one failed: its "couldn't send" stands, once.
        let failing = Rig()
        failing.channel?.records = nil
        await failing.handle(Self.response())
        await failing.handle(Self.response())
        #expect(failing.seen.replaced.map(\.body) == [Self.failed] && failing.seen.removed.isEmpty)
    }

    /// Hazard 4. The system hands the same response over twice, the first time while the
    /// app was only just launched for it and has no model yet: one write.
    @Test func anActionDeliveredTwiceAcrossAColdLaunchTypesOnce() async {
        let rig = Rig(attached: false)
        let first = Task { await rig.actions.handle(Self.response()) }
        let again = Task { await rig.actions.handle(Self.response()) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(rig.channel?.calls.isEmpty == true)
        rig.attach()
        _ = await (first.value, again.value)
        #expect(rig.channel?.written == ["\r"])
        #expect(rig.channel?.calls.filter { $0 == "write" }.count == 1)
        // And once more, long after: still the one write.
        await rig.actions.handle(Self.response())
        #expect(rig.channel?.written == ["\r"])
    }

    @Test func thePanesNextQuestionIsAnsweredThoughItsIdentifierIsTheSame() async {
        let rig = Rig()
        await rig.actions.handle(Self.response())
        // The same record asks again: the same collapse id, delivered later.
        rig.clock.advance(90)
        await rig.actions.handle(Self.response(delivered: Self.delivered.addingTimeInterval(90)))
        #expect(rig.channel?.written == ["\r", "\r"])
        // Enter and Interrupt on one notification are two actions.
        rig.clock.advance(90)
        await rig.actions.handle(Self.response(.interrupt))
        #expect(rig.channel?.written == ["\r", "\r", "\u{03}"])
    }

    // MARK: A launch in the background: the wait for the app's model

    @Test func withoutTheAppsModelItWaitsFiveSecondsAtMostAndThenSaysItFailed() async {
        #expect(NotificationActions.Parts().modelLimit == 5)
        #expect(NotificationActions.Parts().centerLimit == 2)
        let rig = Rig(attached: false)
        let start = Date()
        await rig.actions.handle(Self.response())
        // The stand-in clock ends each limit after 50 ms: the handler waited for the limit
        // and for nothing else.
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(await rig.limits.asked == [5, 2])
        #expect(rig.channel?.calls.isEmpty == true)
        #expect(rig.seen.log == ["begin", "replace", "end"])
        expectReplaced(rig, with: Self.failed)
        // A model that comes after the limit changes nothing for that action.
        rig.attach()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(rig.channel?.calls.isEmpty == true && rig.seen.replaced.count == 1)
    }

    @Test func theModelThatComesInTimeIsUsed() async {
        let rig = Rig(attached: false)
        let handled = Task { await rig.actions.handle(Self.response()) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(rig.seen.log == ["begin"])
        rig.attach()
        await handled.value
        #expect(rig.channel?.written == ["\r"])
        #expect(rig.seen.removed == [["1a-e40c292c"]] && rig.seen.replaced.isEmpty)
    }

    @Test func aNotificationCenterThatNeverAnswersDoesNotHoldTheActionUp() async {
        let rig = Rig()
        rig.channel?.records = [:]
        let stuck = NotificationActions(
            center: .init(remove: { _ in }, replace: { _ in await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }, post: { _ in }),
            parts: .init(sleep: { _ in try? await Task.sleep(nanoseconds: 50_000_000) }),
            background: { [seen = rig.seen] _ in
                seen.log.append("begin")
                return { seen.log.append("end") }
            })
        stuck.attach(rig.model(Self.servers))
        await stuck.handle(Self.response())
        #expect(rig.seen.log.last == "end")
    }

    // MARK: The system's time runs out

    /// Hazard 8. The background time ends while the status is still being read. The task
    /// ends as soon as the system's handler returns, so all of it happens inside that
    /// handler: the notification is put back and iOS is told. The run that was under way
    /// types nothing when its read answers afterwards.
    @Test func whenTheBackgroundTimeRunsOutTheAlertIsPutBackAndIOSIsToldInsideThatMoment() async throws {
        let gated = GatedChannel()
        let rig = Rig(gated: gated)
        let handled = Task { await rig.handle(Self.response()) }
        while gated.calls.isEmpty { await Task.yield() }
        #expect(rig.seen.handled == 0)
        let expire = try #require(rig.seen.expire)
        expire()
        // Nothing was awaited since `expire()`: this is the state when the task ends.
        #expect(rig.seen.posted == [NotificationActions.Replacement(identifier: "1a-e40c292c", title: "Claude · api", subtitle: "work",
                                                                    body: Self.failed, thread: Self.address, info: Self.info)])
        #expect(rig.seen.handled == 1)
        #expect(rig.seen.log == ["begin", "channel \(Self.serverID)", "post", "handled"])
        await handled.value
        // Nothing more became of the notification, and iOS was told once.
        #expect(rig.seen.log == ["begin", "channel \(Self.serverID)", "post", "handled", "end"])
        #expect(rig.seen.replaced.isEmpty && rig.seen.removed.isEmpty && rig.seen.handled == 1)
        // The read answers now, and the pane still waits for exactly this: no write.
        gated.answerRead()
        for _ in 0..<50 where !gated.calls.contains("close") { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(gated.calls == ["status", "close"])
        #expect(gated.written.isEmpty)
        // The same tap again is not typed either, and leaves the notification as it is.
        await rig.handle(Self.response())
        #expect(gated.written.isEmpty && rig.seen.posted.count == 1 && rig.seen.replaced.isEmpty)
    }

    @Test func timeThatRunsOutBeforeTheAppsModelCameEndsTheActionToo() async throws {
        var parts = NotificationActions.Parts()
        // A clock that never ends a limit: only the expiry can end the wait.
        parts.sleep = { _ in await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
        let seen = Seen()
        let actions = NotificationActions(
            center: .init(remove: { _ in seen.log.append("remove") }, replace: { seen.replaced.append($0) }, post: { seen.posted.append($0) }),
            parts: parts,
            background: { expired in
                seen.expire = expired
                return { seen.log.append("end") }
            })
        let handled = Task { await actions.handle(Self.response()) { seen.handled += 1 } }
        while seen.expire == nil { await Task.yield() }
        let expire = try #require(seen.expire)
        expire()
        #expect(seen.posted.map(\.body) == [Self.failed])
        #expect(seen.handled == 1)
        await handled.value
        #expect(seen.replaced.isEmpty && seen.handled == 1)
        #expect(seen.log == ["end"])
    }

    @Test func timeThatRunsOutAfterTheWriteLeftDoesNotTypeAgain() async throws {
        let rig = Rig()
        rig.channel?.silent = ["write"]
        let handled = Task { await rig.handle(Self.response()) }
        while rig.channel?.calls.contains("write") != true { await Task.yield() }
        let expire = try #require(rig.seen.expire)
        expire()
        await handled.value
        // It left once, nobody knows what came of it: said as not sent, and never sent again.
        #expect(rig.channel?.calls.filter { $0 == "write" }.count == 1)
        #expect(rig.seen.posted.map(\.body) == [Self.failed] && rig.seen.replaced.isEmpty && rig.seen.handled == 1)
    }

    @Test func timeThatRunsOutAfterTheNotificationWasDealtWithChangesNothing() async throws {
        // Typed and removed: a late expiry must not put a "couldn't send" in its place.
        let rig = Rig()
        await rig.handle(Self.response())
        let expire = try #require(rig.seen.expire)
        expire()
        #expect(rig.seen.posted.isEmpty && rig.seen.removed == [["1a-e40c292c"]] && rig.seen.handled == 1)
        // While the replacement is on its way to Notification Center: iOS is told, and
        // there is no second replacement.
        let seen = Seen()
        let slow = NotificationActions(
            center: .init(remove: { _ in }, replace: { replacement in
                seen.replaced.append(replacement)
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }, post: { seen.posted.append($0) }),
            parts: .init(sleep: { _ in await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }),
            background: { expired in
                seen.expire = expired
                return {}
            })
        slow.attach(Rig(servers: []).model([]))
        let handled = Task { await slow.handle(Self.response()) { seen.handled += 1 } }
        while seen.replaced.isEmpty { await Task.yield() }
        let late = try #require(seen.expire)
        late()
        #expect(seen.handled == 1 && seen.posted.isEmpty && seen.replaced.count == 1)
        handled.cancel()
    }

    // MARK: One wait, the watch and the notification

    /// The same wait shows on the watch and as a notification. Whichever is tapped second,
    /// within the moment the agent's status needs to catch up, types nothing: the pane still
    /// reads `blocked` for the same record and words, and the guard alone would pass it.
    @Test func afterTheNotificationTheWatchTypesNothing() async {
        let rig = Rig()
        await rig.handle(Self.response(.enter))
        #expect(rig.channel?.written == ["\r"] && rig.seen.removed == [["1a-e40c292c"]])
        // The watch's tap for the same wait, its own id, three seconds later.
        rig.clock.advance(3)
        let target = WatchAction.Target(server: Self.serverID, session: "session:1", block: "block:1a", record: "claude", fp: GlanceActionsTests.fp)
        let fromWatch = await rig.typing.handle(WatchAction(id: UUID().uuidString, kind: .enter, target: target))
        // The watch has no word of its own for this: the agent no longer waits for it.
        #expect(fromWatch == .changed)
        #expect(rig.channel?.written == ["\r"])
        #expect(rig.channel?.calls == ["status", "write", "close"])
    }

    @Test func afterTheWatchTheNotificationTypesNothingAndIsPutBackSayingItWasAnswered() async {
        let rig = Rig()
        let target = WatchAction.Target(server: Self.serverID, session: "session:1", block: "block:1a", record: "claude", fp: GlanceActionsTests.fp)
        #expect(await rig.typing.handle(WatchAction(id: UUID().uuidString, kind: .enter, target: target)) == .sent)
        rig.clock.advance(3)
        await rig.handle(Self.response(.enter))
        #expect(rig.channel?.written == ["\r"])
        // Never removed for this: the agent may have asked the very same question again.
        // Put back in place, quiet, saying it was answered, and a tap opens the pane.
        #expect(rig.seen.removed.isEmpty && rig.seen.posted.isEmpty && rig.seen.handled == 1)
        #expect(rig.seen.replaced == [NotificationActions.Replacement(identifier: "1a-e40c292c", title: "Claude · api", subtitle: "work",
                                                                      body: Self.answered, thread: Self.address, info: Self.info)])
        let content = rig.seen.replaced[0].content
        #expect(content.interruptionLevel == .passive && content.sound == nil)
        #expect(content.categoryIdentifier == "AGENT_BLOCKED")
        #expect(content.userInfo as? [String: String] == Self.info)
        // Interrupt from the notification right after is held back the same way.
        await rig.handle(Self.response(.interrupt))
        #expect(rig.channel?.written == ["\r"])
        #expect(rig.seen.removed.isEmpty && rig.seen.replaced.map(\.body) == [Self.answered, Self.answered])
        // Once the hold is over, the pane's status decides again.
        rig.clock.advance(15)
        await rig.handle(Self.response(.enter, delivered: Self.delivered.addingTimeInterval(20)))
        #expect(rig.channel?.written == ["\r", "\r"])
    }

    @Test func aWatchWriteNobodyKnowsTheEndOfAlsoHoldsTheNotificationBack() async {
        let rig = Rig()
        rig.channel?.delivery = .unknown
        let target = WatchAction.Target(server: Self.serverID, session: "session:1", block: "block:1a", record: "claude", fp: GlanceActionsTests.fp)
        #expect(await rig.typing.handle(WatchAction(id: UUID().uuidString, kind: .enter, target: target)) == .unconfirmed)
        await rig.handle(Self.response(.enter))
        #expect(rig.channel?.calls.filter { $0 == "write" }.count == 1)
        #expect(rig.seen.removed.isEmpty && rig.seen.replaced.map(\.body) == [Self.answered])
    }

    /// Two notifications for the same wait (the agent asked the very same question again
    /// right after the first was answered): the second one's action types nothing during
    /// the hold, and its alert stays in the list.
    @Test func theSameQuestionAskedAgainWithinTheHoldKeepsItsAlert() async {
        let rig = Rig()
        await rig.handle(Self.response(.enter))
        #expect(rig.seen.removed == [["1a-e40c292c"]])
        rig.clock.advance(5)
        await rig.handle(Self.response(.enter, delivered: Self.delivered.addingTimeInterval(5)))
        #expect(rig.channel?.written == ["\r"])
        #expect(rig.seen.removed == [["1a-e40c292c"]])
        #expect(rig.seen.replaced.map(\.body) == [Self.answered])
        #expect(rig.seen.replaced.first?.identifier == "1a-e40c292c")
    }

    // MARK: A launch with no view

    /// The system starts the app for an action after it was swiped away: no scene, so no
    /// view ever appears to hand the model over. The delegate has it from the app's `init`,
    /// and taking it starts nothing.
    @Test func theDelegateHasTheModelWithoutAnyView() throws {
        let suite = "notify-actions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(prefs: Prefs(defaults: defaults), connect: false)
        let delegate = AppDelegate()
        #expect(!delegate.answersActions)
        // What `RexDuoApp.init` does, and then what `didFinishLaunching` does.
        AppDelegate.launching(with: model)
        delegate.takeLaunchModel()
        #expect(delegate.answersActions)
        // No server was started for it.
        #expect(!model.mayConnect)
    }

    // MARK: The notification that comes back

    /// Hazard 10. Whatever went wrong, the person gets no second alert: one notification
    /// under the identifier of the one acted on, passive, with no sound, no badge and no
    /// actions, and nothing else is posted or removed.
    @Test func aRefusedOrFailedActionReplacesInPlaceAndStaysQuiet() async {
        let refused = Rig()
        refused.channel?.records = [:]
        let failed = Rig()
        failed.channel?.records = nil
        let unknown = Rig(servers: [])
        for rig in [refused, failed, unknown] {
            await rig.actions.handle(Self.response())
            #expect(rig.seen.replaced.count == 1 && rig.seen.removed.isEmpty)
            #expect(rig.seen.log.filter { $0 == "replace" }.count == 1)
            let replacement = rig.seen.replaced[0]
            #expect(replacement.identifier == Self.response().request)
            let content = replacement.content
            #expect(content.interruptionLevel == .passive)
            #expect(content.sound == nil && content.badge == nil)
            #expect(content.categoryIdentifier == "AGENT_BLOCKED")
            #expect(content.threadIdentifier == Self.address)
        }
        // In front it is put in the list only: no banner, no sound.
        let shown = PushPresentation.options(test: false, local: true)
        #expect(shown == [.list] && !shown.contains(.banner) && !shown.contains(.sound))
    }

    @Test func theReplacementIsQuietHasNoActionsAndOpensThePane() throws {
        let replacement = NotificationActions.Replacement(identifier: "1a-e40c292c", title: "Claude · api", subtitle: "work",
                                                          body: NotificationCopy.actionChanged, thread: Self.address, info: Self.info)
        let content = replacement.content
        #expect(content.categoryIdentifier == "AGENT_BLOCKED")
        #expect(content.interruptionLevel == .passive)
        #expect(content.sound == nil)
        #expect(content.badge == nil)
        #expect((content.title, content.subtitle, content.body) == ("Claude · api", "work", Self.changed))
        #expect(content.threadIdentifier == Self.address)
        #expect(content.userInfo as? [String: String] == Self.info)
        // A tap on it opens the pane, and the tidier finds its pane as it found the push's.
        let route = try #require(PushRoute(userInfo: content.userInfo))
        #expect(route == PushRoute(server: Self.address, sessionID: "session:1", windowID: "window:1", blockID: "block:1a"))
        #expect(NotificationTidy.agentCategories.contains(content.categoryIdentifier))
    }

    @Test func inFrontOnlyTheTestAndTheAppsOwnNotificationShow() {
        #expect(PushPresentation.options(test: false, local: false) == [])
        #expect(PushPresentation.options(test: true, local: false) == [.banner, .list, .sound])
        // The replacement: into the list, with no banner and no sound.
        #expect(PushPresentation.options(test: false, local: true) == [.list])
    }
}
