import Foundation
import Testing
@testable import RexKit

/// The creator list as a source of answers, and which errors say "this server has no such method".
struct CreatorCatalogTests {
    /// `block_creator.list` as a revision-18 server sends it, cut to what the catalog reads, plus
    /// one creator on a remote host and fields no build knows.
    private static var result: JSONObject { [
        "creators": [
            [
                "name": "com.superlogical.terminal", "title": "Terminal", "host_id": "host-a",
                "flavors": [["name": "shell", "flavor": "com.superlogical.terminal.shell", "title": "Shell"]],
                "api": [
                    "events": ["bell": [:], "progress_report": [:], "ports_changed": [:], "some_future_event": [:]],
                    "methods": ["write": ["description": "x"], "list_dir": [:], "ports": [:], "some_future_method": [:]],
                ],
                "features": ["a_future_feature"],
                "a_future_field": 1,
            ],
            [
                "name": "com.superlogical.tunnel", "host_id": "host-a",
                "flavors": [["flavor": "com.superlogical.tunnel.dial"], ["flavor": "com.superlogical.tunnel.listen"]],
                "api": ["events": ["connection_requested": [:]], "methods": ["info": [:]]],
            ],
            // A remote host on an older Rex: no ports, no list_dir, no tunnel creator.
            [
                "name": "com.superlogical.terminal", "host_id": "host-b",
                "flavors": [["flavor": "com.superlogical.terminal.shell"]],
                "api": ["events": ["bell": [:]], "methods": ["write": [:]]],
            ],
            ["name": "com.example.future", "host_id": "host-a", "flavors": [["flavor": "com.example.future.thing"]], "api": [:]],
        ] as [JSONObject],
    ] }

    @Test func answersPerHost() {
        let c = CreatorCatalog(Self.result)
        let terminal = "com.superlogical.terminal"
        #expect(c.creators.count == 4)
        #expect(c.method("list_dir", creator: terminal, host: "host-a") == .present)
        #expect(c.method("list_dir", creator: terminal, host: "host-b") == .absent, "the remote host's creator answers for it")
        #expect(c.method("write", creator: terminal, host: "host-b") == .present)
        #expect(c.event("progress_report", creator: terminal, host: "host-a") == .present)
        #expect(c.event("progress_report", creator: terminal, host: "host-b") == .absent)
        #expect(c.hasFlavor("com.superlogical.tunnel.dial", host: "host-a"))
        #expect(!c.hasFlavor("com.superlogical.tunnel.dial", host: "host-b"))
        #expect(!c.hasFlavor("com.superlogical.tunnel.dial", host: nil), "a creator for another host doesn't count")
        #expect(c.blockMethods(creator: terminal, host: "host-a")?.contains("some_future_method") == true)
        #expect(c.blockEvents(creator: "com.superlogical.tunnel", host: "host-a") == ["connection_requested"])
    }

    @Test func aMissingCreatorIsAbsent() {
        let c = CreatorCatalog(Self.result)
        #expect(c.method("info", creator: "com.superlogical.tunnel", host: "host-b") == .absent)
        #expect(c.event("connection_requested", creator: "com.superlogical.tunnel", host: "host-b") == .absent)
        #expect(c.blockMethods(creator: "com.superlogical.tunnel", host: "host-b") == nil)
    }

    /// An older shape must not read as "the method is missing": that would hide what shows today.
    @Test func aCreatorWithoutAnAPIOrMethodsIsUnknown() {
        let noAPI = CreatorCatalog(["creators": [["name": "com.superlogical.terminal", "flavors": [JSONObject]()]] as [JSONObject]])
        #expect(noAPI.method("upload_begin", creator: "com.superlogical.terminal", host: nil) == .unknown)
        #expect(noAPI.event("bell", creator: "com.superlogical.terminal", host: nil) == .unknown)
        #expect(noAPI.blockMethods(creator: "com.superlogical.terminal", host: nil) == nil)

        let emptyAPI = CreatorCatalog(Self.result)
        #expect(emptyAPI.method("x", creator: "com.example.future", host: "host-a") == .unknown)

        let eventsOnly = CreatorCatalog(["creators": [["name": "t", "api": ["events": ["bell": [:]]]]] as [JSONObject]])
        #expect(eventsOnly.method("write", creator: "t", host: nil) == .unknown)
        #expect(eventsOnly.event("bell", creator: "t", host: nil) == .present)
        #expect(eventsOnly.event("other", creator: "t", host: nil) == .absent)
    }

    @Test func aServerWithoutHostIDsMatchesANilHost() {
        let c = CreatorCatalog(["creators": [["name": "t", "flavors": [["flavor": "t.shell"]], "api": ["methods": ["write": [:]]]]] as [JSONObject]])
        #expect(c.method("write", creator: "t", host: nil) == .present)
        #expect(c.hasFlavor("t.shell", host: nil))
        #expect(c.method("write", creator: "t", host: "host-a") == .absent)
    }

    @Test func malformedListsAreEmptyNotFatal() {
        #expect(CreatorCatalog([:]).creators.isEmpty)
        #expect(CreatorCatalog(["creators": NSNull()]).creators.isEmpty)
        #expect(CreatorCatalog(["creators": [["title": "nameless"], "junk", 3] as [Any]]).creators.isEmpty)
    }
}

struct PresenceTests {
    private func error(_ code: String, status: Int = 404) -> RexError { RexError(code: code, message: code, status: status) }

    @Test func methodNotFoundAndRevisionTooLowMeanAbsent() {
        #expect(error("method_not_found").presence(targetExists: false) == .absent)
        #expect(error("revision_too_low", status: 400).presence(targetExists: false) == .absent)
    }

    /// Servers from before `method_not_found` say `not_found`, which also means "no such block".
    @Test func notFoundCountsOnlyWhenTheTargetIsKnownToExist() {
        #expect(error("not_found").presence(targetExists: true) == .absent)
        #expect(error("not_found").presence(targetExists: false) == .unknown)
    }

    @Test func anyOtherErrorSaysNothing() {
        for code in ["bad_request", "conflict", "internal", "timeout", "session_not_found", "client", "a_future_code"] {
            #expect(error(code, status: 500).presence(targetExists: true) == .unknown, "\(code)")
        }
        #expect(Presence.present.answer == true)
        #expect(Presence.absent.answer == false)
        #expect(Presence.unknown.answer == nil)
    }

    @Test func theMethodTableNamesOnlyMethodsNewerThan13() {
        #expect(RexAPI.minimum(for: "com.superlogical.terminal.ports") == 15)
        #expect(RexAPI.minimum(for: "com.superlogical.tunnel.info") == 14)
        #expect(RexAPI.minimum(for: "session.bootstrap") == 0)
        #expect(RexAPI.minimum(for: "client.reply") == 0, "client.reply is older than the prompts it answers")
        #expect(RexAPI.minimumRevision.values.allSatisfy { $0 > 13 && $0 <= RexControl.apiRevision })
    }
}

/// `event_dropped`: each kind of lost event names the smallest read that brings its state back.
struct DroppedEventTests {
    private func recovery(_ type: String, session: String? = nil, block: String? = nil, name: String? = nil) -> DroppedEvent.Recovery {
        DroppedEvent(type: type, sessionID: session, blockID: block, blockEventName: name).recovery
    }

    @Test func parsesTheEvent() {
        let d = DroppedEvent(["event_type": "block_event", "session_id": "session:1", "block_id": "block:1",
                              "creator_name": "com.superlogical.terminal", "block_event_name": "program_status_changed",
                              "size": 2_000_000, "a_future_field": true])
        #expect(d == DroppedEvent(type: "block_event", sessionID: "session:1", blockID: "block:1",
                                  creator: "com.superlogical.terminal", blockEventName: "program_status_changed", size: 2_000_000))
        // Inside a session_event the wrapper names the session.
        #expect(DroppedEvent(["event_type": "window_created"], session: "session:2").sessionID == "session:2")
        #expect(DroppedEvent([:]).type == "")
    }

    @Test func aBlockEventReadsThatBlockNeverEverything() {
        #expect(recovery("block_event", session: "s", block: "b", name: "program_status_changed")
            == .block(session: "s", block: "b", name: "program_status_changed"))
        #expect(recovery("block_event", block: "b", name: "title_changed") == .block(session: nil, block: "b", name: "title_changed"))
        #expect(recovery("block_event", session: "s", block: "b", name: "an_event_from_the_future")
            == .block(session: "s", block: "b", name: "an_event_from_the_future"))
        #expect(recovery("block_event", session: "s") == .sessionView("s"), "no block named: the session's view")
        #expect(recovery("block_event") == .ignore)
    }

    @Test func aSessionEventReadsThatSessionsView() {
        for type in ["session_view_changed", "window_created", "window_closed", "block_created", "block_closed",
                     "block_owner_changed", "session_label_changed", "a_session_event_from_the_future"] {
            #expect(recovery(type, session: "s") == .sessionView("s"), "\(type)")
        }
    }

    @Test func serverWideEventsReadTheirList() {
        for type in ["session_created", "session_destroyed", "session_moved"] {
            #expect(recovery(type) == .sessionList, "\(type)")
            // `session_destroyed` may name its session; the list is still what changed.
            #expect(recovery(type, session: "s") == .sessionList, "\(type)")
        }
        #expect(recovery("hosts_changed") == .hosts)
        #expect(recovery("keymap_changed") == .keymap)
        #expect(recovery("creator_changed", session: "s") == .creators)
        #expect(recovery("creator_changed") == .creators)
        for type in ["client_joined", "client_left", "client_changed"] { #expect(recovery(type) == .clients, "\(type)") }
    }

    /// A request to this client lost its `call_id` with the event: there is nothing to answer,
    /// and reading everything again answers nothing either.
    @Test func eventsAddressedToThisClientAreIgnored() {
        for type in ["client_prompt_requested", "client_call_requested", "client_perform_requested",
                     "client_something_new_requested"] {
            #expect(recovery(type) == .ignore, "\(type)")
            #expect(recovery(type, session: "s") == .ignore, "\(type)")
        }
        for type in ["client_prompt_ended", "client_performed", "client_script_events_dropped", "tailscale_status_changed"] {
            #expect(recovery(type) == .ignore, "\(type)")
            #expect(recovery(type, session: "s") == .ignore, "\(type)")
        }
    }

    @Test func onlyATrulyUnknownServerWideTypeReadsEverything() {
        #expect(recovery("an_event_from_the_future") == .everything)
        #expect(recovery("") == .everything)
        #expect(recovery("client_something_else") == .everything)
    }
}

struct PromptRequestTests {
    @Test func parsesAPrompt() throws {
        let p = try #require(PromptRequest([
            "call_id": "call:1", "action": "dev_layout", "timeout_ms": 120_000,
            "prompt": ["kind": "pick", "title": "Branch", "multiple": false,
                       "items": [["id": "a", "title": "main"], ["id": "b", "title": "dev", "icon": "branch"]]] as JSONObject,
        ], receivedAt: Date(timeIntervalSince1970: 5), connectionSerial: 3))
        #expect(p.callID == "call:1")
        #expect(p.action == "dev_layout")
        #expect(p.kind == "pick")
        #expect(p.isKnownKind)
        #expect(p.timeoutMS == 120_000)
        #expect(p.prompt.arr("items").count == 2)
        #expect(p.connectionSerial == 3)
        #expect(p.receivedAt == Date(timeIntervalSince1970: 5))
    }

    @Test func aKindFromTheFutureIsNotKnown() throws {
        let p = try #require(PromptRequest(["call_id": "c", "prompt": ["kind": "color_wheel", "title": "x"] as JSONObject, "timeout_ms": 1]))
        #expect(!p.isKnownKind)
        #expect(p.action == nil)
        let bare = try #require(PromptRequest(["call_id": "c"]))
        #expect(!bare.isKnownKind && bare.kind == "" && bare.timeoutMS == 0)
    }

    @Test func withoutACallIDThereIsNothingToAnswer() {
        #expect(PromptRequest(["prompt": ["kind": "input"] as JSONObject]) == nil)
        #expect(PromptRequest(["call_id": ""]) == nil)
    }

    @Test func theDeclineIsAnErrorAndNoResult() {
        let d = PromptRequest.decline(callID: "call:9")
        #expect(d.str("call_id") == "call:9")
        #expect(d.obj("error")?.str("code") == "not_supported")
        #expect(d.obj("error")?.str("message")?.isEmpty == false)
        #expect(d["result"] == nil)
    }
}

/// The shapes the app decodes, as one server sent them to connections at four hello revisions
/// (0, 13, 16, 18; IDs replaced). They were the same at every one: revisions 14 to 18 only add
/// methods and events. Pinned here because no server is left that tops out at 13. What each
/// revision's welcome leaves the connection with is in `RevisionTests`, against a server.
struct RevisionShapeTests {
    static let revisions = [0, 13, 16, 18]

    static let view = #"""
    {"active_window_id": "window:1", "label": "zz-shapes", "revision": 2, "session_id": "session:1",
     "windows": [{"focused_block_id": "block:1", "label": "Window ae001cca", "window_id": "window:1",
       "layers": [{"kind": "tiled", "layer_id": "layer:1", "bounds": [0, 0, 1, 1],
         "blocks": [{"block_id": "block:1", "creator_name": "com.superlogical.terminal",
                     "flavor": "com.superlogical.terminal.shell", "host_id": "host-a", "label": "shell", "owner": "client:1"},
                    {"block_id": "block:2", "creator_name": "com.superlogical.terminal",
                     "flavor": "com.superlogical.terminal.shell", "host_id": "host-a", "label": "shell"}],
         "layout": {"rect": [0, 0, 1, 1], "split": {"split_id": "split:1", "direction": "horizontal", "ratio": 0.5,
                    "before": {"block_id": "block:1", "rect": [0, 0, 0.5, 1]},
                    "after": {"block_id": "block:2", "rect": [0.5, 0, 0.5, 1]}}}}]}]}
    """#

    static let programStatus = #"""
    {"records": [{"id": "claude", "app": "claude", "effective_app": "claude", "state": "blocked", "kind": "permission",
                  "msg": "Wants to run a command", "title": "Claude Code", "progress": 40, "a_future_field": 1},
                 {"id": "build", "app": "make", "state": "working"}]}
    """#

    static let bootstrap = #"""
    {"client_id": "client:1",
     "server_status": {"pid": 100, "instance_id": "instance-1", "host_id": "host-a", "started_at": "2026-01-01T00:00:00Z",
                       "exit_empty": false, "session_count": 2, "api_revision": 18,
                       "tailscale": {"state": "running", "dns_name": "rex.example.ts.net", "allow_tailnet_members": false},
                       "config": {"generation": 1, "hash": "h"}},
     "attach_all": {"sessions": [{"session_id": "session:1", "label": "zz-shapes"}, {"session_id": "session:2", "label": "zz-other"}]},
     "sessions": []}
    """#

    @Test(arguments: revisions) func sessionViewDecodes(revision: Int) throws {
        let v = SessionView(try #require(JSONCodec.decode(Self.view)))
        #expect(v.sessionID == "session:1" && v.label == "zz-shapes" && v.revision == 2)
        #expect(v.activeWindow?.id == "window:1")
        let w = try #require(v.windows.first)
        #expect(w.orderedBlockIDs == ["block:1", "block:2"])
        #expect(w.focusedBlockID == "block:1" && w.zoomedBlockID == nil)
        #expect(w.block("block:1")?.owner == "client:1")
        #expect(w.block("block:2")?.owner == nil, "no owner until a client takes the block")
        #expect(w.block("block:1")?.hostID == "host-a")
        #expect(w.allBlocks.allSatisfy { $0.isTerminal })
        #expect(w.layout?.splits.first?.direction == "horizontal")
        #expect(w.layout?.leaves.map(\.rect.width) == [0.5, 0.5])
        #expect(w.layers.first?.minimized == false)
    }

    @Test(arguments: revisions) func programStatusDecodes(revision: Int) throws {
        var m = BlockMeta()
        for rec in try #require(JSONCodec.decode(Self.programStatus)).arr("records") {
            m.statuses[rec.str("id") ?? ""] = ProgramStatus(rec)
        }
        #expect(m.statuses.count == 2)
        #expect(m.topStatus?.state == "blocked")
        #expect(m.topStatus?.waitingFor == "permission")
        #expect(m.topStatus?.text == "Wants to run a command")
        #expect(m.topStatus?.progress == 40)
        #expect(m.agentKind == .claude)
    }

    @Test(arguments: revisions) func bootstrapDecodes(revision: Int) throws {
        let r = try #require(JSONCodec.decode(Self.bootstrap))
        #expect(r.obj("attach_all")?.arr("sessions").compactMap { $0.str("session_id") } == ["session:1", "session:2"])
        #expect(r.obj("server_status")?.obj("tailscale")?.str("dns_name") == "rex.example.ts.net")
        #expect(r.obj("server_status")?.str("instance_id") == "instance-1")
        #expect(r.obj("server_status")?.str("host_id") == "host-a")
    }
}
