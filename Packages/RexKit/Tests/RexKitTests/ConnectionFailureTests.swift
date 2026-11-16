import Foundation
import Testing
@testable import RexKit

struct ConnectionFailureTests {
    @Test func readsURLErrorWithPOSIXUnderneath() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 61)
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                          userInfo: [NSUnderlyingErrorKey: posix, "_kCFStreamErrorCodeKey": 61,
                                     NSLocalizedDescriptionKey: "Could not connect to the server."])
        let f = ConnectionFailure(err, httpStatus: 403, closeCode: nil)
        #expect(f.domain == NSURLErrorDomain)
        #expect(f.code == NSURLErrorCannotConnectToHost)
        #expect(f.underlyingCode == 61)
        #expect(f.posixCode == 61)
        #expect(f.httpStatus == 403)
        #expect(f.detail == "NSURLErrorDomain -1004 · NSPOSIXErrorDomain 61 · HTTP 403")
    }

    @Test func posixCodeFromStreamCodeAlone() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: ["_kCFStreamErrorCodeKey": 65])
        #expect(ConnectionFailure(err).posixCode == 65)
    }

    @Test func keepsAnExistingFailure() {
        var f = ConnectionFailure.timedOut()
        f = ConnectionFailure(f, closeCode: 1008)
        #expect(f.code == NSURLErrorTimedOut)
        #expect(f.closeCode == 1008)
    }

    @Test func invalidAddress() {
        let f = ConnectionFailure.invalidAddress("nope")
        #expect(f.isInvalidAddress)
        #expect(!ConnectionFailure.timedOut().isInvalidAddress)
    }

    @Test func rexErrorKeepsItsMessage() {
        let f = ConnectionFailure(RexError(code: "forbidden", message: "no", status: 403))
        #expect(f.domain == ConnectionFailure.rexDomain)
        #expect(f.code == 403)
        #expect(f.message == "no")
    }

    @MainActor @Test func invalidAddressFailsWithoutRetrying() async {
        let c = RexControl(address: "not a url", client: ClientInfo(name: "t", version: "1", label: "t"))
        await #expect(throws: ConnectionFailure.self) { try await c.connect() }
        #expect(c.state == .failed(.invalidAddress("not a url")))
    }
}
