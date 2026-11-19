import Foundation
import Testing
@testable import GlanceModel

@Suite struct DeepLinkTests {
    private func link(_ s: String) -> DeepLink? {
        URL(string: s).flatMap(DeepLink.init)
    }

    @Test func buildsAndParsesBothWays() {
        #expect(DeepLink.open.url.absoluteString == "rexduo://open")
        #expect(DeepLink.waiting.url.absoluteString == "rexduo://waiting")
        for l in DeepLink.allCases { #expect(DeepLink(l.url) == l) }
    }

    @Test func schemeAndHostIgnoreCase() {
        #expect(link("REXDUO://WAITING") == .waiting)
        #expect(link("RexDuo://Open") == .open)
        #expect(link("rexduo://waiting/") == .waiting)
    }

    @Test func anUnknownHostOrPathBecomesOpen() {
        for s in ["rexduo://", "rexduo:", "rexduo:waiting", "rexduo:///waiting", "rexduo://settings",
                  "rexduo://pane", "rexduo://pair", "rexduo://waiting/now", "rexduo://waiting//",
                  "rexduo://open/waiting", "rexduo://waiting.example.com", "rexduo://waitingx",
                  "rexduo://user@waiting", "rexduo://user:pw@waiting", "rexduo://waiting:80",
                  "rexduo://%77aiting", "rexduo://%77aiting/%2e%2e"] {
            #expect(link(s) == .open, "\(s)")
        }
    }

    @Test func aPercentEncodedOrUnicodeHostIsNotALink() {
        // Only the plain ASCII spelling names a link; a look-alike is `open`, which does nothing.
        for s in ["rexduo://%77aiting", "rexduo://%57AITING", "rexduo://wa%69ting", "rexduo://waiting%00",
                  "rexduo://w\u{0430}iting", "rexduo://waitin\u{0261}", "rexduo://wa\u{0131}ting",
                  "rexduo://xn--witing-6wf"] {
            let url = URL(string: s)
            // Foundation may refuse to parse some of these at all, which is as good.
            #expect(url.flatMap(DeepLink.init) != .waiting, "\(s)")
            if let url { #expect(DeepLink(url) == .open, "\(s)") }
        }
    }

    @Test func aHostFoundationRewritesToTheLinkIsTheLink() {
        // Foundation applies the domain-name mapping while it parses: a full-width letter becomes
        // its ASCII letter and a zero-width space is dropped. What reaches `DeepLink` is then the
        // URL `rexduo://waiting` itself, with nothing left to tell it from the real link.
        for s in ["rexduo://\u{FF57}aiting", "rexduo://waiting\u{200B}"] {
            // A Foundation that doesn't map it leaves a look-alike, which is `open`, or no URL.
            guard let url = URL(string: s) else { continue }
            let rewritten = url.absoluteString == "rexduo://waiting"
            #expect(DeepLink(url) == (rewritten ? .waiting : .open), "\(s)")
        }
    }

    @Test func parametersAreIgnored() {
        #expect(link("rexduo://waiting?x=1&server=abc") == .waiting)
        #expect(link("rexduo://waiting?%00%ff=%zz&&&=") == .waiting)
        #expect(link("rexduo://waiting?a b") == .waiting)
        #expect(link("rexduo://waiting#frag") == .waiting)
        #expect(link("rexduo://open?url=javascript:alert(1)") == .open)
        #expect(link("rexduo://open?next=rexduo://waiting") == .open)
        #expect(link("rexduo://nothing?go=waiting") == .open)
    }

    @Test func veryLongValuesAreHarmless() {
        let long = String(repeating: "a", count: 200_000)
        #expect(link("rexduo://waiting?q=\(long)") == .waiting)
        #expect(link("rexduo://\(long)") == .open)
        #expect(link("rexduo://waiting/\(long)") == .open)
        #expect(link("rexduo://open#\(long)") == .open)
    }

    @Test func otherSchemesAreRefused() {
        for s in ["javascript:alert(1)", "javascript://waiting", "http://waiting", "https://open",
                  "file:///waiting", "data:text/plain,waiting", "rexduo2://waiting", "xrexduo://waiting",
                  "rex://waiting", "tel:waiting", "waiting", "//waiting", "/open"] {
            #expect(link(s) == nil, "\(s)")
        }
    }
}
