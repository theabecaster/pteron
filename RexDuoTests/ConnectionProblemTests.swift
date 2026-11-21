import Foundation
import Testing
import RexKit
@testable import RexDuo

struct ConnectionProblemTests {
    private let offTailnet = NetworkSnapshot(reachable: true, onPrivateNetwork: false)
    private let onTailnet = NetworkSnapshot(reachable: true, onPrivateNetwork: true)
    private let offline = NetworkSnapshot(reachable: false, onPrivateNetwork: false)

    private func url(_ code: Int, posix: Int? = nil, status: Int? = nil) -> ConnectionFailure {
        var info: [String: Any] = [:]
        if let posix {
            info[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: posix)
            info["_kCFStreamErrorCodeKey"] = posix
        }
        return ConnectionFailure(NSError(domain: NSURLErrorDomain, code: code, userInfo: info), httpStatus: status)
    }

    private func kind(_ f: ConnectionFailure, _ n: NetworkSnapshot) -> ConnectionProblem.Kind {
        ConnectionProblem.classify(f, network: n).kind
    }

    @Test func noPathIsNoInternetWhateverTheError() {
        #expect(kind(url(NSURLErrorCannotFindHost), offline) == .noInternet)
        #expect(kind(url(NSURLErrorTimedOut), offline) == .noInternet)
        #expect(kind(url(NSURLErrorNotConnectedToInternet), onTailnet) == .noInternet)
        #expect(kind(url(NSURLErrorDataNotAllowed), onTailnet) == .noInternet)
    }

    @Test func unresolvedPrivateNameOffTheTailnet() {
        #expect(kind(url(NSURLErrorCannotFindHost), offTailnet) == .offPrivateNetwork)
        #expect(kind(url(NSURLErrorDNSLookupFailed), offTailnet) == .offPrivateNetwork)
        #expect(kind(url(NSURLErrorTimedOut), offTailnet) == .offPrivateNetwork)
        // Can't tell whether the phone is on a tailnet: the private network is the likely cause.
        #expect(kind(url(NSURLErrorCannotFindHost), .unknown) == .offPrivateNetwork)
        #expect(kind(.timedOut(), .unknown) == .offPrivateNetwork)
    }

    @Test func unresolvedNameOnTheTailnetIsNotFound() {
        #expect(kind(url(NSURLErrorCannotFindHost), onTailnet) == .hostNotFound)
    }

    @Test func silenceOnTheTailnetIsAMacNotAnswering() {
        #expect(kind(url(NSURLErrorTimedOut), onTailnet) == .notAnswering)
        #expect(kind(.timedOut(), onTailnet) == .notAnswering)
        #expect(kind(url(NSURLErrorCannotConnectToHost, posix: Int(EHOSTUNREACH)), onTailnet) == .notAnswering)
        #expect(kind(url(NSURLErrorCannotConnectToHost, posix: Int(EHOSTUNREACH)), offTailnet) == .offPrivateNetwork)
    }

    @Test func refusedOrNotRexIsNotAnswering() {
        #expect(kind(url(NSURLErrorCannotConnectToHost, posix: Int(ECONNREFUSED)), offTailnet) == .notAnswering)
        #expect(kind(url(NSURLErrorBadServerResponse, status: 502), onTailnet) == .notAnswering)
        #expect(kind(url(NSURLErrorBadServerResponse, status: 404), onTailnet) == .notAnswering)
        #expect(kind(url(NSURLErrorBadServerResponse), onTailnet) == .notAnswering)
        #expect(kind(ConnectionFailure(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED), message: ""), onTailnet) == .notAnswering)
    }

    @Test func rejectedIsNotAllowed() {
        #expect(kind(url(NSURLErrorBadServerResponse, status: 403), onTailnet) == .notAllowed)
        #expect(kind(url(NSURLErrorBadServerResponse, status: 401), offTailnet) == .notAllowed)
        var closed = url(NSURLErrorNetworkConnectionLost)
        closed.closeCode = 1008
        #expect(kind(closed, onTailnet) == .notAllowed)
    }

    @Test func tlsIsInsecure() {
        #expect(kind(url(NSURLErrorServerCertificateUntrusted), onTailnet) == .insecure)
        #expect(kind(url(NSURLErrorSecureConnectionFailed), onTailnet) == .insecure)
        #expect(kind(url(NSURLErrorAppTransportSecurityRequiresSecureConnection), onTailnet) == .insecure)
        let ssl = ConnectionFailure(domain: "kCFErrorDomainCFNetwork", code: 0, message: "", streamCode: -9807)
        #expect(kind(ssl, onTailnet) == .insecure)
    }

    @Test func badAddressBeatsEverything() {
        #expect(kind(.invalidAddress("x"), offline) == .badAddress)
    }

    @Test func anythingElseIsUnknownWithDetail() {
        let p = ConnectionProblem.classify(ConnectionFailure(domain: "Weird", code: 7, message: "odd"), network: onTailnet)
        #expect(p.kind == .unknown)
        #expect(p.detail == "Weird 7")
    }

    // MARK: Hysteresis

    private func problem(_ k: ConnectionProblem.Kind, _ detail: String = "") -> ConnectionProblem {
        ConnectionProblem(kind: k, detail: detail)
    }

    @Test func sameKindKeepsWhatIsShown() {
        var g = ProblemGate()
        #expect(g.observe(problem(.offPrivateNetwork, "a")).detail == "a")
        // A new error string of the same kind doesn't change the screen.
        #expect(g.observe(problem(.offPrivateNetwork, "b")).detail == "a")
    }

    @Test func otherKindNeedsTwoInARow() {
        var g = ProblemGate()
        _ = g.observe(problem(.offPrivateNetwork))
        #expect(g.observe(problem(.notAnswering)).kind == .offPrivateNetwork)
        #expect(g.observe(problem(.offPrivateNetwork)).kind == .offPrivateNetwork)
        #expect(g.observe(problem(.notAnswering)).kind == .offPrivateNetwork)
        #expect(g.observe(problem(.notAnswering)).kind == .notAnswering)
    }

    @Test func decisiveKindsSwitchAtOnce() {
        var g = ProblemGate()
        _ = g.observe(problem(.offPrivateNetwork))
        #expect(g.observe(problem(.noInternet)).kind == .noInternet)
        #expect(g.observe(problem(.notAllowed)).kind == .notAllowed)
    }

    @Test func networkChangeTakesTheNextProblemAsIs() {
        var g = ProblemGate()
        _ = g.observe(problem(.noInternet))
        g.networkChanged()
        #expect(g.observe(problem(.offPrivateNetwork)).kind == .offPrivateNetwork)
    }

    // MARK: Network

    @Test func tailnetRanges() {
        #expect(PrivateNetwork.isTailnet(ipv4: 0x646D_0631))   // 100.109.6.49
        #expect(PrivateNetwork.isTailnet(ipv4: 0x6440_0000))   // 100.64.0.0
        #expect(PrivateNetwork.isTailnet(ipv4: 0x647F_FFFF))   // 100.127.255.255
        #expect(!PrivateNetwork.isTailnet(ipv4: 0x6480_0000))  // 100.128.0.0
        #expect(!PrivateNetwork.isTailnet(ipv4: 0xC0A8_0101))  // 192.168.1.1
        #expect(PrivateNetwork.isTailnet(ipv6: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] + Array(repeating: 0, count: 10)))
        #expect(!PrivateNetwork.isTailnet(ipv6: [0xfe, 0x80] + Array(repeating: 0, count: 14)))
    }

    // MARK: Copy

    @Test func copyNamesTheServer() {
        #expect(OfflineCopy.of(.notAnswering, server: "Studio", address: "").title == "Studio isn't answering")
        #expect(OfflineCopy.of(.notAnswering, server: "studio", address: "").title == "Studio isn't answering")
        #expect(OfflineCopy.of(.hostNotFound, server: "Studio", address: "").message
            == "This iPhone is on a private network, but Studio isn't on it.")
        // Every kind names the computer, never "the Mac" or "server", and says "running", not "open".
        for kind in ConnectionProblem.Kind.allCases {
            for address in ["x", "https://studio-rex.tail1234.ts.net"] {
                let c = OfflineCopy.of(kind, server: "Studio", address: address)
                for text in [c.title, c.message, c.hint ?? ""] {
                    #expect(!text.contains("the Mac") && !text.contains("Mac's"), "\(kind): \(text)")
                    #expect(!text.localizedCaseInsensitiveContains("server"), "\(kind): \(text)")
                    #expect(!text.contains("Rex is open") && !text.contains("isn't open"), "\(kind): \(text)")
                }
            }
        }
        #expect(OfflineCopy.of(.notAnswering, server: "Studio", address: "").hint == "Check that Studio is awake and Rex is running.")
        #expect(OfflineCopy.of(.offPrivateNetwork, server: "Studio", address: "x").hint
            == "Connect this iPhone to the same network or VPN as Studio, then try again.")
        #expect(OfflineAction.serverSettings.title == "Computer Settings")
        #expect(OfflineCopy.short(.offPrivateNetwork) == "Out of range" && OfflineCopy.short(.hostNotFound) == "Not found")
        let asleep = OfflineCopy.of(.notAnswering, server: "Studio", address: "")
        #expect(asleep.message == "It may be asleep, or Rex isn't running there.")
    }

    /// A Linux computer is never called a Mac: every line names the computer instead.
    @Test func copyNeverSaysMacForAComputer() {
        for kind in ConnectionProblem.Kind.allCases {
            for address in ["x", "https://box-rex.tail1234.ts.net"] {
                let c = OfflineCopy.of(kind, server: "Box", address: address)
                for text in [c.title, c.message, c.hint ?? ""] {
                    #expect(!text.contains("Mac"), "\(kind): \(text)")
                }
            }
        }
    }

    /// Tailscale is named only where the computer's address is a Tailscale one: off Tailscale the
    /// fix is on this iPhone, and a computer that doesn't answer or let this iPhone in may be a
    /// Tailscale matter too. Every other case words it as for any address. (The tunnel's own
    /// message is the other place, and has its own tests below.)
    @Test func copyNamesTailscaleOnlyForATailscaleAddressOffTheTailnet() {
        for kind in ConnectionProblem.Kind.allCases where kind != .tunnelDown {
            for address in ["x", "http://192.168.1.20:8765"] {
                let c = OfflineCopy.of(kind, server: "Studio", address: address)
                for text in [c.title, c.message, c.hint ?? ""] {
                    #expect(!text.localizedCaseInsensitiveContains("tailscale"))
                    #expect(!text.contains("ts.net"))
                }
                #expect(OfflineAction.secondary(for: kind, address: address) != .getTailscale)
            }
            let tailnet = "https://studio-rex.tail1234.ts.net"
            let c = OfflineCopy.of(kind, server: "Studio", address: tailnet)
            if kind == .offPrivateNetwork {
                #expect(c.message == "Tailscale isn't connected on this iPhone.")
                #expect(OfflineAction.secondary(for: kind, address: tailnet) == .getTailscale)
            } else if kind == .notAnswering {
                #expect(c.hint == "Check that Studio is awake and Rex is running. If no computer connects, turn Tailscale off and on.")
                #expect(OfflineAction.secondary(for: kind, address: tailnet) == nil)
            } else if kind == .notAllowed {
                #expect(c.message == "Rex only accepts devices signed in to the same Tailscale account as Studio.")
                #expect(OfflineAction.secondary(for: kind, address: tailnet) == nil)
            } else if kind == .hostNotFound {
                #expect(c.message == "Tailscale on this iPhone is signed in to a different account than Studio.")
                #expect(c.hint == "Sign in with the account you used in Rex.")
            } else {
                // A bad address quotes the address, so only its title stays the same.
                if kind != .badAddress { #expect(c == OfflineCopy.of(kind, server: "Studio", address: "x")) }
                #expect(OfflineAction.secondary(for: kind, address: tailnet) == OfflineAction.secondary(for: kind))
            }
        }
    }

    // MARK: The tunnel's message

    @Test func theTunnelsMessageIsTheAgreedWordsAndNamesNoServer() {
        let c = OfflineCopy.of(.tunnelDown, server: "Studio", address: "https://studio-rex.tail1234.ts.net")
        #expect(c.title == "Can't reach your computers")
        #expect(c.message == "If Tailscale shows a warning, turn it off and on.")
        #expect(c.hint == nil)
        #expect(!c.title.contains("Studio") && !c.message.contains("Studio"))
        #expect(c == OfflineCopy.of(.tunnelDown, server: "This Mac", address: "x"))
        // No new button, and nothing shown at once on one failure.
        #expect(OfflineAction.secondary(for: .tunnelDown, address: "https://studio-rex.tail1234.ts.net") == nil)
        #expect(!ConnectionProblem.Kind.tunnelDown.isDecisive)
    }

    @Test func aSilentServerSaysTheTunnelsProblemOnlyWhileItShows() {
        let own = problem(.notAnswering, "d")
        #expect(own.under(tunnel: true, host: .unanswered, tailnetAddress: true)
            == ConnectionProblem(kind: .tunnelDown, detail: "d"))
        #expect(own.under(tunnel: false, host: .unanswered, tailnetAddress: true) == own)
        for kind in [ConnectionProblem.Kind.hostNotFound, .unknown] {
            #expect(problem(kind).under(tunnel: true, host: .unanswered, tailnetAddress: true).kind == .tunnelDown)
        }
        // Tailscale is off on this iPhone: its own screen says so, and says what to do.
        let off = problem(.offPrivateNetwork)
        #expect(off.under(tunnel: true, host: .unanswered, tailnetAddress: true) == off)
    }

    /// One server that is off, a refusal, an HTTP answer, TLS and a server that turned the phone
    /// away keep what they say, whatever the others do.
    @Test func aServerThatAnsweredOrWasTurnedAwayKeepsItsOwnProblem() {
        let own = problem(.notAnswering, "d")
        for host in [TunnelSuspicion.Host.answered, .unknown, .up] {
            #expect(own.under(tunnel: true, host: host, tailnetAddress: true) == own)
        }
        for kind in ConnectionProblem.Kind.allCases where kind.isDecisive {
            #expect(problem(kind).under(tunnel: true, host: .unanswered, tailnetAddress: true).kind == kind)
        }
        // A refusal classifies as not answering, and its host says it answered.
        let refusal = ConnectionProblem.classify(url(NSURLErrorCannotConnectToHost, posix: Int(ECONNREFUSED)), network: onTailnet)
        #expect(refusal.under(tunnel: true, host: .answered, tailnetAddress: true) == refusal)
    }

    @Test func aServerWithNoTailscaleAddressIsNeverToldToCheckTailscale() {
        let own = problem(.notAnswering)
        #expect(own.under(tunnel: true, host: .unanswered, tailnetAddress: false) == own)
    }

    @Test func classifyNeverGivesTheTunnelsProblem() {
        for net in [offTailnet, onTailnet, offline, NetworkSnapshot.unknown] {
            for f in [url(NSURLErrorTimedOut), url(NSURLErrorNetworkConnectionLost), url(NSURLErrorCannotFindHost),
                      .timedOut(), url(NSURLErrorCannotConnectToHost, posix: Int(ECONNREFUSED))] {
                #expect(kind(f, net) != .tunnelDown)
            }
        }
    }

    /// The sidebar's line stays one computer's: a dormant one reads as any that doesn't answer,
    /// and so does one under the tunnel's problem.
    @Test func theSidebarsLine() {
        #expect(OfflineCopy.short(.notAnswering) == "Not answering")
        #expect(OfflineCopy.short(.tunnelDown) == "Not answering")
    }

    /// VoiceOver says a tap tries again only where it does: a row of a computer that is down
    /// and is not the one on screen.
    @Test func theHintIsOnlyOnRowsWhoseTapTriesAgain() {
        #expect(OfflineCopy.tapHint(down: true, otherComputer: true) == "Tries again.")
        #expect(OfflineCopy.tapHint(down: true, otherComputer: false) == nil, "a tab of the computer on screen")
        #expect(OfflineCopy.tapHint(down: false, otherComputer: true) == nil)
        #expect(OfflineCopy.tapHint(down: false, otherComputer: false) == nil)
    }

    @MainActor @Test func aDropShowsNothingForFiveSeconds() {
        #expect(ServerConnection.phaseGrace == 5)
    }

    // MARK: Actions

    @Test func secondaryActions() {
        #expect(OfflineAction.secondary(for: .offPrivateNetwork) == .openSettings)
        #expect(OfflineAction.secondary(for: .noInternet) == .openSettings)
        #expect(OfflineAction.secondary(for: .insecure) == .serverSettings)
        #expect(OfflineAction.secondary(for: .notAllowed) == nil)
        #expect(OfflineAction.secondary(for: .notAnswering) == nil)
    }
}
