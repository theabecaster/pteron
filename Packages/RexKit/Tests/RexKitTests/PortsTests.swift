import Foundation
import Testing
@testable import RexKit

/// `terminal.ports` replies and `ports_changed` events: what a pane's port list keeps.
struct PortsTests {
    /// A process's name the way the app labels it, enough for these tests.
    static func label(_ p: JSONObject) -> String { p.str("argv0") ?? p.str("name") ?? "" }

    static func port(_ n: Int, _ address: String, pid: Int? = 1, proto: String = "tcp", seen: String = "2026-11-20T03:45:46Z") -> JSONObject {
        var o: JSONObject = ["port": n, "address": address, "protocol": proto, "first_seen_at": seen]
        if let pid { o["pid"] = pid }
        return o
    }

    static func reply(_ ports: [JSONObject], status: String = "ok", processes: [JSONObject] = [["pid": 1, "user_id": 501, "name": "node", "argv0": "vite"]],
                      truncated: Bool? = nil) -> JSONObject {
        var o: JSONObject = ["status": status, "ports": ports, "processes": processes]
        if let truncated { o["truncated"] = truncated }
        return o
    }

    @Test func everyStatus() {
        #expect(PortList(Self.reply([], status: "ok"), label: Self.label).status == .ok)
        #expect(PortList(Self.reply([], status: "partial"), label: Self.label).status == .partial)
        #expect(PortList(Self.reply([], status: "unsupported"), label: Self.label).status == .unsupported)
        #expect(PortList(Self.reply([], status: "something-new"), label: Self.label).status == .partial, "unknown counts as partial")
        #expect(PortList([:], label: Self.label).status == .partial)
    }

    @Test func unknownProtocolIsSkippedAndPidMayBeMissing() {
        let l = PortList(Self.reply([Self.port(5173, "127.0.0.1"), Self.port(5174, "127.0.0.1", proto: "udp"),
                                     Self.port(3000, "127.0.0.1", pid: nil)], status: "partial"), label: Self.label)
        #expect(l.entries.map(\.port) == [3000, 5173])
        #expect(l.entry(5173)?.process == "vite")
        #expect(l.entry(3000)?.process == nil, "no pid, no label")
    }

    @Test func anEntryCarriesItsProcessForTheRowAndForStop() {
        let processes: [JSONObject] = [["pid": 41, "user_id": 501, "name": "python3.12", "argv0": "python3", "cwd": "/work/site"]]
        let list = PortList(Self.reply([Self.port(8765, "::", pid: 41), Self.port(9000, "127.0.0.1", pid: nil)], processes: processes), label: Self.label)
        let e = list.entry(8765)
        #expect(e?.pid == 41)
        #expect(e?.program == "python3.12")
        #expect(e?.folder == "/work/site")
        #expect(e?.process == "python3")
        // The server couldn't tell which process holds it: nothing to name, nothing to stop.
        #expect(list.entry(9000)?.pid == nil)
        #expect(list.entry(9000)?.program == nil)
        // A process that moves to another folder is another list, so the row's name follows.
        let moved: [JSONObject] = [["pid": 41, "user_id": 501, "name": "python3.12", "argv0": "python3", "cwd": "/work/other"]]
        #expect(PortList(Self.reply([Self.port(8765, "::", pid: 41)], processes: moved), label: Self.label)
            != PortList(Self.reply([Self.port(8765, "::", pid: 41)], processes: processes), label: Self.label))
    }

    @Test func truncatedKeepsWhatCame() {
        let l = PortList(Self.reply([Self.port(8080, "::")], truncated: true), label: Self.label)
        #expect(l.truncated)
        #expect(l.entries.map(\.port) == [8080])
    }

    @Test func dialAddresses() {
        #expect(PortRules.dialHost("0.0.0.0") == "127.0.0.1")
        #expect(PortRules.dialHost("::") == "::1")
        #expect(PortRules.dialHost("127.0.0.1") == "127.0.0.1")
        #expect(PortRules.dialHost("::1") == "::1")
        #expect(PortRules.dialHost("192.168.1.20") == "192.168.1.20")
        #expect(PortRules.dialHost("fe80::1%1") == nil, "a zone names the computer's interface")
        #expect(PortRules.dialHost("") == nil)
    }

    @Test func dedupePrefersLoopbackAndSorts() {
        let l = PortList(Self.reply([Self.port(5173, "192.168.1.20"), Self.port(5173, "::1"), Self.port(5173, "127.0.0.1"),
                                     Self.port(80, "0.0.0.0"), Self.port(9000, "fe80::1%2")]), label: Self.label)
        #expect(l.entries.map(\.port) == [80, 5173], "one per port, sorted, a zoned address skipped")
        #expect(l.entry(5173)?.dialHost == "::1", "the first loopback wins over a specific address")
        #expect(l.entry(80)?.dialHost == "127.0.0.1")
        #expect(l.entry(5173)?.name == "localhost:5173")
    }

    @Test func webFilter() {
        let processes: [JSONObject] = [["pid": 1, "name": "node"], ["pid": 2, "name": "postgres"], ["pid": 3, "name": "redis-server"]]
        let l = PortList(Self.reply([Self.port(5173, "127.0.0.1"), Self.port(9229, "127.0.0.1"), Self.port(9222, "127.0.0.1"),
                                     Self.port(9230, "127.0.0.1"), Self.port(5432, "127.0.0.1", pid: 2),
                                     Self.port(6380, "127.0.0.1", pid: 3), Self.port(22, "0.0.0.0"), Self.port(3306, "::"),
                                     Self.port(8000, "::", pid: nil)], processes: processes), label: { $0.str("name") ?? "" })
        #expect(l.webPorts.map(\.port) == [5173, 8000], "debuggers, databases, SSH and a database's own port are left out")
    }

    @Test func equalityIgnoresFirstSeen() {
        let a = PortList(Self.reply([Self.port(5173, "127.0.0.1", seen: "2026-11-20T03:45:46Z")]), label: Self.label)
        let b = PortList(Self.reply([Self.port(5173, "127.0.0.1", seen: "2026-11-20T04:00:00Z")]), label: Self.label)
        #expect(a == b)
    }

    /// The event exactly as a revision-18 server (preview.21, macOS) sent it.
    @Test func aRecordedEvent() throws {
        let text = #"{"status":"ok","ports":[{"port":18770,"address":"127.0.0.1","protocol":"tcp","first_seen_at":"2026-11-20T03:48:26Z","pid":71425}],"processes":[{"pid":71425,"user_id":501,"user":"theabecaster","name":"Python","path":"/usr/bin/python3","argv0":"/usr/bin/python3","cwd":"/tmp"}]}"#
        let l = PortList(try #require(JSONCodec.decode(text)), label: Self.label)
        #expect(l == PortList(status: .ok, entries: [PortEntry(port: 18770, dialHost: "127.0.0.1", process: "/usr/bin/python3", pid: 71425, program: "Python", folder: "/tmp")]))
    }
}
