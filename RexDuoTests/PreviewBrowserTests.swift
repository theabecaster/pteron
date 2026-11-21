import Network
import WebKit
import XCTest
@testable import RexDuo

/// The preview browser's addresses: what it shows and copies, whatever loads underneath.
final class PreviewAddressTests: XCTestCase {
    private func link(_ s: String) -> LocalhostLink? { URL(string: s).flatMap { LocalhostLink($0) } }

    func testATappedLinkShowsItsOwnHostAndPortAsWritten() throws {
        XCTAssertEqual(link("http://localhost:3000/x")?.shown, "localhost:3000")
        XCTAssertEqual(link("http://127.0.0.1:5173")?.shown, "127.0.0.1:5173")
        XCTAssertEqual(link("http://0.0.0.0:8000/")?.shown, "0.0.0.0:8000")
        XCTAssertEqual(link("http://[::1]:4000/a")?.shown, "[::1]:4000")
        XCTAssertEqual(link("http://[::]:8000/")?.shown, "[::]:8000")
        // A LAN address, as dev servers print beside localhost.
        let lan = try XCTUnwrap(LocalhostLink(lan: XCTUnwrap(URL(string: "http://172.16.0.9:3000/app"))))
        XCTAssertEqual(lan.shown, "172.16.0.9:3000")
        // What loads is still the phone's own listener, by the name the page's requests need.
        XCTAssertEqual(lan.url(localPort: 49200)?.absoluteString, "http://localhost:49200/app")
        XCTAssertEqual(link("http://0.0.0.0:8000/")?.url(localPort: 8000)?.absoluteString, "http://localhost:8000/")
    }

    func testAPortsRowOrTheMenuShowsLocalhost() {
        XCTAssertEqual(LocalhostLink(port: 3000, dialHost: "::1").shown, "localhost:3000")
        XCTAssertEqual(LocalhostLink(port: 8765, dialHost: "127.0.0.1").shown, "localhost:8765")
    }

    func testTheChromeNeverShowsWhatLoadsUnderneath() throws {
        // The phone's port was taken, so the listener is on another one.
        let load = try XCTUnwrap(URL(string: "http://localhost:49200/"))
        for shown in ["localhost:3000", "127.0.0.1:5173", "0.0.0.0:8000", "[::1]:4000", "172.16.0.9:3000"] {
            let page = PreviewPage(load: load, shown: shown)
            let deep = URL(string: "http://localhost:49200/admin/users?x=1#top")
            XCTAssertEqual(PreviewAddress.display(nil, page), shown)
            XCTAssertEqual(PreviewAddress.display(deep, page), shown)
            XCTAssertEqual(PreviewAddress.errorTitle(deep, page), "Couldn't load \(shown)")
            XCTAssertEqual(PreviewAddress.link(deep, page), "http://\(shown)/admin/users?x=1#top")
            XCTAssertEqual(PreviewAddress.link(nil, page), "http://\(shown)/")
            XCTAssertFalse(PreviewAddress.link(deep, page).contains("49200"))
        }
    }

    func testAnHttpsLinkKeepsItsScheme() throws {
        let l = try XCTUnwrap(link("https://localhost:3443/a"))
        let page = PreviewPage(load: try XCTUnwrap(l.url(localPort: 3443)), shown: l.shown, scheme: l.scheme)
        XCTAssertEqual(PreviewAddress.link(URL(string: "https://localhost:3443/b"), page), "https://localhost:3443/b")
    }

    func testAPageThatLeftTheServerShowsItsOwnHost() throws {
        let page = PreviewPage(load: try XCTUnwrap(URL(string: "http://localhost:49200/")), shown: "localhost:3000")
        let away = URL(string: "https://example.com/docs")
        XCTAssertFalse(PreviewAddress.isOwn(away, page))
        XCTAssertEqual(PreviewAddress.display(away, page), "example.com")
        XCTAssertEqual(PreviewAddress.link(away, page), "https://example.com/docs")
        // Another port of the phone is not the opened server either.
        XCTAssertEqual(PreviewAddress.display(URL(string: "http://localhost:5000/"), page), "localhost:5000")
    }

    func testWhichFailuresShowTheErrorPage() {
        XCTAssertTrue(PreviewAddress.showsError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)))
        XCTAssertFalse(PreviewAddress.showsError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertFalse(PreviewAddress.showsError(NSError(domain: "WebKitErrorDomain", code: 102)), "a load that became a download")
    }

    func testWhatDownloadsAndWhatLoads() {
        XCTAssertTrue(PreviewAddress.isDownload(canShow: false, disposition: nil))
        XCTAssertTrue(PreviewAddress.isDownload(canShow: true, disposition: " Attachment; filename=\"a.txt\""))
        XCTAssertFalse(PreviewAddress.isDownload(canShow: true, disposition: "inline"))
        XCTAssertFalse(PreviewAddress.isDownload(canShow: true, disposition: nil))
        XCTAssertTrue(PreviewAddress.loads(URL(string: "http://localhost:3000/")))
        XCTAssertFalse(PreviewAddress.loads(URL(string: "tel:5550100")))
        XCTAssertFalse(PreviewAddress.loads(URL(string: "rexduo://open")))
    }
}

/// The places are a navigation controller's toolbar's own, read from it on iOS 27.2 on each
/// shape (the view is the sheet's; centres are given, in its coordinates).
final class PreviewBarLayoutTests: XCTestCase {
    private func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    func testAnIPhoneUprightWithOrWithoutAHomeIndicator() {
        // iPhone 17 Pro: a 402 x 812 sheet. The iPhone SE's is the same from its bottom edge up.
        let l = PreviewBarLayout.make(size: CGSize(width: 402, height: 812), verticalBar: nil, compactHeight: false, floats: false, rightToLeft: false)
        XCTAssertEqual(l.room, 86, "the page ends 86 pt above the sheet's edge, the home indicator's 34 included")
        XCTAssertEqual(l.strip, CGRect(x: 0, y: 726, width: 402, height: 86))
        XCTAssertEqual([l.back, l.forward, l.reload].map(centre), [CGPoint(x: 52, y: 760), CGPoint(x: 140, y: 760), CGPoint(x: 350, y: 760)])
        XCTAssertEqual(l.back.size, CGSize(width: 48, height: 48))
    }

    func testAnIPhoneOnItsSide() {
        let l = PreviewBarLayout.make(size: CGSize(width: 874, height: 402), verticalBar: nil, compactHeight: true, floats: false, rightToLeft: false)
        XCTAssertEqual(l.room, 78)
        XCTAssertEqual([l.back, l.forward, l.reload].map(centre), [CGPoint(x: 60, y: 356), CGPoint(x: 144, y: 356), CGPoint(x: 814, y: 356)])
        XCTAssertEqual(l.reload.size, CGSize(width: 44, height: 44))
    }

    func testASheetThatFloats() {
        // An iPad's form sheet, 580 x 660.
        let l = PreviewBarLayout.make(size: CGSize(width: 580, height: 660), verticalBar: nil, compactHeight: false, floats: true, rightToLeft: false)
        XCTAssertEqual(l.room, 64)
        XCTAssertEqual([l.back, l.forward, l.reload].map(centre), [CGPoint(x: 32, y: 628), CGPoint(x: 116, y: 628), CGPoint(x: 548, y: 628)])
    }

    func testTheDuosVerticalBarHoldsThemFromTheBottomUp() {
        // The outer screen upright: a 450 x 670 sheet, the bar on the right.
        let right = PreviewBarLayout.make(size: CGSize(width: 450, height: 670), verticalBar: .right, compactHeight: false, floats: false, rightToLeft: false)
        XCTAssertEqual(right.room, 0, "the page keeps its height beside a vertical bar")
        XCTAssertNil(right.strip, "and the bar has no background")
        XCTAssertEqual([right.back, right.forward, right.reload].map(centre), [CGPoint(x: 410, y: 474), CGPoint(x: 410, y: 562), CGPoint(x: 410, y: 622)])
        // On its side, the bar on the left: a 662 x 458 sheet.
        let left = PreviewBarLayout.make(size: CGSize(width: 662, height: 458), verticalBar: .left, compactHeight: true, floats: false, rightToLeft: false)
        XCTAssertEqual([left.back, left.forward, left.reload].map(centre), [CGPoint(x: 40, y: 262), CGPoint(x: 40, y: 350), CGPoint(x: 40, y: 410)])
        XCTAssertEqual(left.back.size, CGSize(width: 48, height: 48))
    }

    func testRightToLeftPutsBackOnTheRight() {
        let l = PreviewBarLayout.make(size: CGSize(width: 402, height: 812), verticalBar: nil, compactHeight: false, floats: false, rightToLeft: true)
        XCTAssertEqual([l.back, l.forward, l.reload].map(centre), [CGPoint(x: 350, y: 760), CGPoint(x: 262, y: 760), CGPoint(x: 52, y: 760)])
    }
}

/// A web server on the phone's loopback, for the browser's own tests.
final class PageServer: @unchecked Sendable {
    // `@unchecked`: `listener` is set once in `start`; connections live on `queue`.
    private let queue = DispatchQueue(label: "PageServer")
    private var listener: NWListener?

    func start() async throws -> Int {
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        l.newConnectionHandler = { [queue] c in
            c.start(queue: queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self)
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                c.send(content: Self.answer(path, authorized: head.contains("Authorization: Basic")), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { done in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: l.stateUpdateHandler = nil; done.resume(returning: Int(l.port?.rawValue ?? 0))
                case .failed(let e): l.stateUpdateHandler = nil; done.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    /// Returns once nothing listens on the port any more.
    func stop() async {
        guard let l = listener else { return }
        listener = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            l.stateUpdateHandler = { state in
                if case .cancelled = state { l.stateUpdateHandler = nil; done.resume() }
            }
            l.cancel()
        }
    }

    private static func answer(_ path: String, authorized: Bool) -> Data {
        func reply(_ status: String, _ headers: [String], _ body: String) -> Data {
            let lines = ["HTTP/1.1 \(status)", "Content-Length: \(body.utf8.count)", "Connection: close"] + headers
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
        }
        let html = ["Content-Type: text/html; charset=utf-8"]
        switch path {
        case "/file": return reply("200 OK", ["Content-Type: text/plain", "Content-Disposition: attachment; filename=\"notes.txt\""], "notes")
        case "/secret" where !authorized: return reply("401 Unauthorized", ["WWW-Authenticate: Basic realm=\"Staging\""], "")
        case "/secret": return reply("200 OK", html, "<title>Secret</title>in")
        case "/second": return reply("200 OK", html, "<title>Second</title>two")
        default: return reply("200 OK", html, "<title>Fixture page</title><a id=n target=_blank href=/second>new</a>")
        }
    }
}

@MainActor
final class PreviewBrowserTests: XCTestCase {
    private var server: PageServer!
    private var port = 0
    private var window: UIWindow!
    private var closes = 0

    override func setUp() async throws {
        server = PageServer()
        port = try await server.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        closes = 0
    }

    override func tearDown() async throws {
        await server.stop()
        window.isHidden = true
        window = nil
    }

    @MainActor
    private final class Wait {
        var over = false
    }

    /// Waits for `check` to hold, asked again each time the browser says something changed
    /// (`onChange`): no clock decides. `limit` is only the net under a browser that never says.
    private func until(_ b: PreviewBrowser, limit: Double = 120, _ check: @escaping @MainActor () -> Bool) async -> Bool {
        if check() { return true }
        let wait = Wait()
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let net = Task { @MainActor [weak b] in
                try? await Task.sleep(for: .seconds(limit))
                guard !wait.over else { return }
                wait.over = true
                b?.onChange = nil
                done.resume(returning: check())
            }
            b.onChange = { [weak b] in
                guard !wait.over, check() else { return }
                wait.over = true
                net.cancel()
                b?.onChange = nil
                done.resume(returning: true)
            }
        }
    }

    /// One turn of the main queue.
    private func turn() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
    }

    /// The browser on top of the test window, showing `path` of the fixture as `localhost:3000`.
    private func open(_ path: String = "/", port p: Int? = nil) async throws -> PreviewBrowser {
        let load = try XCTUnwrap(URL(string: "http://127.0.0.1:\(p ?? port)\(path)"))
        let page = PreviewPage(load: load, shown: "localhost:3000")
        XCTAssertTrue(PreviewBrowser.present(page, over: window.rootViewController?.view) { [weak self] in self?.closes += 1 })
        let shown = try XCTUnwrap(window.rootViewController?.presentedViewController)
        return try XCTUnwrap((shown as? UINavigationController)?.viewControllers.first as? PreviewBrowser ?? shown as? PreviewBrowser)
    }

    func testThePageShowsItsTitleOverTheComputersAddress() async throws {
        let b = try await open()
        let titled = await until(b) { b.shownTitle == "Fixture page" }
        XCTAssertTrue(titled)
        XCTAssertEqual(b.shownHost, "localhost:3000", "never the phone's own port \(port)")
        XCTAssertNil(b.shownError)
        var copied: [String] = []
        b.copy = { copied.append($0) }
        b.copyLink()
        XCTAssertEqual(copied, ["http://localhost:3000/"])
        b.close()
    }

    func testTheWebViewIsMadeOnOpenAndGoneAfterClose() async throws {
        weak var browser: PreviewBrowser?
        weak var web: WKWebView?
        let released = expectation(description: "the browser is released")
        do {
            let b = try await open()
            _ = await until(b) { b.shownTitle == "Fixture page" }
            browser = b
            web = b.webView
            XCTAssertNotNil(web, "one web view while the page is up")
            b.gone = { released.fulfill() }
            b.close()
            XCTAssertNil(b.webView, "let go at once on close")
        }
        XCTAssertEqual(closes, 1, "the forward is told once")
        // The browser says when it is released; the limit is only a net.
        await fulfillment(of: [released], timeout: 120)
        await turn()
        XCTAssertNil(browser, "nothing keeps the browser after it closed")
        XCTAssertNil(web, "nor its web view")
        XCTAssertEqual(closes, 1)
    }

    /// A leak test: after a close nothing of the page is alive. Not the browser, not what
    /// presented it, not the web view, nor what the web view was configured with (WebKit hands
    /// out its configuration as a copy, which shares the one user content controller). Nor
    /// anything that was in the bars: a `UIToolbar` kept its items, their buttons and the menu
    /// for every page opened, which is why the arrows are the browser's own buttons.
    func testNothingOfAPageOutlivesItsClose() async throws {
        weak var browser: PreviewBrowser?
        weak var shown: UIViewController?
        weak var web: WKWebView?
        weak var configuration: WKWebViewConfiguration?
        weak var content: WKUserContentController?
        weak var done: UIBarButtonItem?
        weak var more: UIBarButtonItem?
        weak var menu: UIMenu?
        weak var title: UIView?
        let buttons = NSHashTable<UIButton>.weakObjects()
        let released = expectation(description: "the browser is released")
        do {
            let b = try await open()
            _ = await until(b) { b.shownTitle == "Fixture page" && b.barButtons.count == 3 }
            browser = b
            done = b.navigationItem.leftBarButtonItem
            more = b.navigationItem.rightBarButtonItem
            menu = b.navigationItem.rightBarButtonItem?.menu
            title = b.navigationItem.titleView
            for button in b.barButtons { buttons.add(button) }
            XCTAssertNotNil(done)
            XCTAssertNotNil(more)
            XCTAssertNotNil(menu)
            XCTAssertEqual(buttons.count, 3)
            shown = window.rootViewController?.presentedViewController
            web = b.webView
            configuration = b.webView?.configuration
            content = b.webView?.configuration.userContentController
            XCTAssertNotNil(web)
            XCTAssertNotNil(content)
            b.gone = { released.fulfill() }
            b.close()
        }
        await fulfillment(of: [released], timeout: 120)
        // WebKit lets its own objects go over a few turns of the main queue after the view.
        func left() -> Bool {
            web != nil || content != nil || configuration != nil || shown != nil || done != nil || more != nil || menu != nil
                || title != nil || !buttons.allObjects.isEmpty
        }
        for _ in 0..<200 where left() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(browser, "the browser")
        XCTAssertNil(shown, "the controller that was presented")
        XCTAssertNil(web, "the web view")
        XCTAssertNil(configuration, "its configuration")
        XCTAssertNil(content, "its user content controller")
        XCTAssertNil(done, "Done")
        XCTAssertNil(more, "the menu's button")
        XCTAssertNil(menu, "the menu")
        XCTAssertNil(title, "the title and the address")
        XCTAssertEqual(buttons.allObjects.count, 0, "back, forward and reload")
        XCTAssertEqual(closes, 1)
    }

    /// What VoiceOver and the large content viewer get from the three buttons under the page.
    func testTheButtonsUnderThePageSayWhatTheyAre() async throws {
        let b = try await open()
        let up = await until(b) { b.shownTitle == "Fixture page" && b.barButtons.count == 3 }
        XCTAssertTrue(up)
        let buttons = b.barButtons
        XCTAssertEqual(buttons.map(\.accessibilityLabel), ["Back", "Forward", "Reload"])
        for button in buttons {
            XCTAssertTrue(button.accessibilityTraits.contains(.button), "\(button.accessibilityLabel ?? "") is a button")
            XCTAssertTrue(button.isAccessibilityElement)
            XCTAssertTrue(button.showsLargeContentViewer)
            XCTAssertEqual(button.largeContentTitle, button.accessibilityLabel)
        }
        XCTAssertTrue(buttons[0].superview?.interactions.contains { $0 is UILargeContentViewerInteraction } ?? false,
                      "a long press shows a button large at the accessibility text sizes")
        // One page, so nowhere to go back or forward to: the arrows are off, and say so.
        XCTAssertFalse(buttons[0].isEnabled)
        XCTAssertFalse(buttons[1].isEnabled)
        XCTAssertTrue(buttons[0].accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(buttons[1].accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(buttons[2].isEnabled)
        XCTAssertFalse(buttons[2].accessibilityTraits.contains(.notEnabled))
        b.close()
    }

    func testAFailedLoadShowsOurErrorPageWithTheComputersAddress() async throws {
        let other = PageServer()
        let dead = try await other.start()
        await other.stop()
        let b = try await open(port: dead)
        let failed = await until(b) { b.shownError != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(b.shownError, "Couldn't load localhost:3000")
        XCTAssertEqual(b.shownHost, "localhost:3000")
        XCTAssertEqual(b.shownTitle, "localhost:3000")
        var copied: [String] = []
        b.copy = { copied.append($0) }
        b.copyLink()
        XCTAssertEqual(copied, ["http://localhost:3000/"])
        b.close()
    }

    func testAFailedNavigationIsTitledByTheAddressNotByThePageBefore() async throws {
        let b = try await open()
        let titled = await until(b) { b.shownTitle == "Fixture page" }
        XCTAssertTrue(titled)
        // The server goes, and the page is loaded again.
        await server.stop()
        b.webView?.reload()
        let failed = await until(b) { b.shownError != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(b.shownTitle, "localhost:3000", "the address, never the title of the page that was there")
        XCTAssertEqual(b.shownError, "Couldn't load localhost:3000")
        b.close()
    }

    func testALinkForANewWindowOpensInTheSameView() async throws {
        let b = try await open()
        _ = await until(b) { b.shownTitle == "Fixture page" }
        _ = try? await b.webView?.evaluateJavaScript("document.getElementById('n').click()")
        let moved = await until(b) { b.shownTitle == "Second" }
        XCTAssertTrue(moved)
        XCTAssertEqual(b.webView?.url?.path, "/second")
        XCTAssertEqual(b.shownHost, "localhost:3000")
        XCTAssertTrue(b.webView?.canGoBack ?? false)
        b.close()
    }

    func testAServerThatAsksForAPasswordGetsAFormNamedByTheComputersAddress() async throws {
        let b = try await open("/secret")
        let asked = await until(b) { b.presentedViewController is UIAlertController }
        XCTAssertTrue(asked)
        let alert = try XCTUnwrap(b.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "Sign in to localhost:3000")
        XCTAssertEqual(alert.message, "Staging")
        XCTAssertEqual(alert.textFields?.count, 2)
        XCTAssertEqual(alert.textFields?.last?.isSecureTextEntry, true)
        alert.dismiss(animated: false)
        b.close()
    }

    func testAnAttachmentGoesToTheShareSheet() async throws {
        let b = try await open("/file")
        let shared = await until(b) { b.presentedViewController is UIActivityViewController }
        XCTAssertTrue(shared)
        XCTAssertNil(b.shownError, "a download is not a failed load")
        b.presentedViewController?.dismiss(animated: false)
        b.close()
    }
}
