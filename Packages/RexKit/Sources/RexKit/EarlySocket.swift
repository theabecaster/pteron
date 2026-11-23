import Foundation

/// What a fresh start does with the data socket it opened beside its ticket request. Pure:
/// `TerminalStream` asks.
///
/// A fresh start needs a ticket (`data.connect`) and a data socket, and the HELLO on that socket
/// carries the ticket. Asked one after the other, the socket's connect and upgrade wait for the
/// ticket's round trip. So the start opens the socket in the turn it asks for the ticket, and
/// sends the HELLO when both are there: one round trip less on the way to the first screen.
///
/// The server takes a HELLO on a socket that has been open for a while, and ends a socket that
/// has sent none 5 s after its upgrade (REJECT `0x05`, close 1002), ping or no ping. So an
/// early socket is used only while it is younger than `ageLimit`.
enum EarlySocket {
    /// How old an early socket may be when its HELLO goes: 1 s under the 5 s after which the
    /// server ends a socket that has said nothing.
    static let ageLimit: Duration = .seconds(4)

    /// What came of the ticket request.
    enum Ticket: Equatable {
        case arrived
        /// Refused because the session is not attached yet: the start waits for the attach and
        /// asks again (`TerminalStream.awaitAttach`).
        case conflict
        /// Any other failure.
        case failed
    }

    enum Step: Equatable {
        /// The HELLO goes on the early socket.
        case hello
        /// The early socket is closed and the ticket goes on a new one: the order of a start
        /// without an early socket. Not a failed start.
        case freshSocket
        /// The early socket stays open through the wait for the attach, for this long at most.
        case keep(Duration)
        /// The early socket is closed; the start goes on, or fails, as it would without one.
        case close
    }

    /// - Parameters:
    ///   - ended: the socket was rejected, closed or failed before a HELLO went.
    ///   - age: the time since the socket was opened.
    static func step(ticket: Ticket, ended: Bool, age: Duration) -> Step {
        let usable = !ended && age < ageLimit
        switch ticket {
        case .arrived: return usable ? .hello : .freshSocket
        case .conflict: return usable ? .keep(ageLimit - age) : .close
        case .failed: return .close
        }
    }
}
