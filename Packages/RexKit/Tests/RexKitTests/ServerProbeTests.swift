import Foundation
import Testing
@testable import RexKit

struct ServerProbeTests {
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
}
