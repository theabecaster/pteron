import Foundation
import Network
import RexKit

/// Asks Tailscale's own service on this phone whether it answers: one TCP connection to
/// 100.100.100.100:53, the address every Tailscale client serves itself. No computer is asked,
/// so it costs the tunnel nothing.
///
/// For the connection log only. The result is one line there (`ConnectionEvent.tunnelProbe`),
/// read by a person after the fact. Nothing on screen and nothing about reconnecting reads it:
/// whether it tells a stuck tunnel from a working one is not known yet.
enum TunnelProbe {
    struct Result: Equatable, Sendable {
        var reachable: Bool
        var milliseconds: Int64
    }

    /// How long the connection may take before it counts as no answer.
    static let timeout: Double = 3

    /// Runs `probe` and writes its result in `log`. It returns nothing and changes nothing else.
    static func record(into log: ConnectionLog,
                       probe: @Sendable () async -> Result = { await TunnelProbe.connect() }) async {
        let result = await probe()
        log.record(.tunnelProbe(reachable: result.reachable, milliseconds: result.milliseconds))
    }

    /// One connection, closed as soon as it is made or has failed. No byte is sent.
    static func connect(host: String = "100.100.100.100", port: UInt16 = 53,
                        timeout: Double = TunnelProbe.timeout) async -> Result {
        let began = ProcessInfo.processInfo.systemUptime
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any,
                                      using: params)
        let queue = DispatchQueue(label: "dev.abrahamgonzalez.rexduo.tunnelprobe", qos: .utility)
        let reachable: Bool = await withCheckedContinuation { done in
            // The state handler and the deadline may both end it; only the first one counts.
            let once = ResumeOnce(done)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(returning: true)
                // Waiting: no route now. This asks once and doesn't wait for one.
                case .failed, .waiting, .cancelled: once.resume(returning: false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(returning: false) }
            connection.start(queue: queue)
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        let ms = Int64(((ProcessInfo.processInfo.systemUptime - began) * 1000).rounded())
        return Result(reachable: reachable, milliseconds: ms)
    }
}
