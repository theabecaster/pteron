import Foundation
import Testing
@testable import RexKit

/// Answers by host, so the tests share no state: `s<status>.test` answers with that status,
/// `redirect.test` redirects to `s426.test`, `silent.test` never answers.
private final class StubServer: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        func answer(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        switch host {
        case "silent.test":
            return
        case "redirect.test":
            let target = URL(string: "https://s426.test/api/control")!
            let redirect = answer(302, headers: ["Location": target.absoluteString])
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            // Refused, the redirect is the answer; followed, the loader has already left this request.
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        default:
            let status = Int(host.dropFirst().prefix { $0.isNumber }) ?? 500
            client?.urlProtocol(self, didReceive: answer(status), cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

struct ServerProbeTests {
    private func check(_ host: String, timeout: TimeInterval = 5) async -> ConnectionFailure? {
        await ServerProbe.check(address: "https://\(host)", timeout: timeout, protocols: [StubServer.self])
    }

    @Test func asksTheControlEndpointOfTheAddress() {
        #expect(ServerProbe.url(for: "https://studio.tail1234.ts.net")?.absoluteString == "https://studio.tail1234.ts.net/api/control")
        #expect(ServerProbe.url(for: " https://studio.tail1234.ts.net:8443/x?y=1#z ")?.absoluteString
                == "https://studio.tail1234.ts.net:8443/api/control")
        #expect(ServerProbe.url(for: "http://127.0.0.1:8765")?.absoluteString == "http://127.0.0.1:8765/api/control")
    }

    @Test func refusesWhatIsNotAServerAddress() async {
        for bad in ["", "studio", "ftp://studio.ts.net", "https://"] {
            #expect(ServerProbe.url(for: bad) == nil, "\(bad)")
        }
        #expect(await ServerProbe.check(address: "not an address")?.isInvalidAddress == true)
    }

    @Test func onlyRexAskingForTheUpgradeCountsAsAnAnswer() {
        #expect(ServerProbe.failure(status: 426) == nil)
        for status in [200, 301, 401, 403, 404, 502] {
            let f = ServerProbe.failure(status: status)
            #expect(f?.httpStatus == status)
            #expect(f?.domain == NSURLErrorDomain)
            #expect(f?.code == NSURLErrorBadServerResponse)
        }
        #expect(ServerProbe.failure(status: nil)?.httpStatus == nil)
    }

    @Test func rexAnsweringIsReachable() async {
        #expect(await check("s426.test") == nil)
    }

    @Test func aRefusalCarriesItsStatus() async {
        #expect(await check("s403.test")?.httpStatus == 403)
        #expect(await check("s200.test")?.httpStatus == 200)
    }

    @Test func aRedirectIsNotFollowedToAnotherHost() async {
        // Followed, this would reach s426.test and pass.
        let f = await check("redirect.test")
        #expect(f != nil)
        #expect(f?.httpStatus == 302)
    }

    @Test func noAnswerTimesOut() async {
        let f = await check("silent.test", timeout: 0.3)
        #expect(f?.domain == NSURLErrorDomain)
        #expect(f?.code == NSURLErrorTimedOut)
    }

    @Test func cancellingTheTaskEndsTheRequest() async {
        let started = Date()
        let task = Task { await check("silent.test", timeout: 30) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let f = await task.value
        #expect(f?.code == NSURLErrorCancelled)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
