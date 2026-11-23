import RexKit
import XCTest
@testable import Pteron

/// A float in the narrow sheet claims its grid once, at Large with the keyboard down, and no
/// size change of the sheet or the keyboard resizes it on the Mac again (`FloatSheet`).
@MainActor
final class FloatSheetClaimTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    func testMediumAndTheKeyboardSendNoResizeAfterTheFirstClaim() async throws {
        let transport = FakeFitTransport()
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "float"), sizing: .fit,
                                fontSize: 13, theme: ThemeStore.fallback, claim: FitClaim(transport: transport, settle: {}))
        let canvas = CGSize(width: 402, height: 740)
        let large = FloatSheet.Geometry(canvas: canvas, live: canvas, keyboardUp: false, mediumAllowed: true)
        let rest = try XCTUnwrap(FloatSheet.Geometry.rest(canvas: canvas))
        host.setRestSize(rest)
        host.frame = CGRect(origin: .zero, size: large.content.size)
        window.rootViewController?.view.addSubview(host)
        host.layoutIfNeeded()
        await settleMainActor()
        let resizes = { transport.calls.filter { $0.hasPrefix("resize") } }
        XCTAssertEqual(resizes().count, 1, "the claim at Large")

        // Medium: the panes keep their bounds and take a cover for what is below the screen.
        let cover = try XCTUnwrap(large.mediumTop) - large.largeTop
        host.setSheetCover(cover)
        host.layoutIfNeeded()
        await settleMainActor()
        XCTAssertEqual(host.sheetCover, cover)
        XCTAssertEqual(host.frame.size, large.content.size)
        XCTAssertEqual(host.term.visibleHeight, host.bounds.height - cover, accuracy: 2, "covered as under the keyboard")
        XCTAssertEqual(resizes().count, 1, "Medium resizes nothing on the Mac")

        // Back to Large, then the keyboard: the sheet's panes are covered, not refitted.
        host.setSheetCover(0)
        let typing = FloatSheet.Geometry(canvas: canvas, live: CGSize(width: canvas.width, height: canvas.height - 336),
                                         keyboardUp: true, mediumAllowed: true)
        host.frame = CGRect(origin: .zero, size: typing.content.size)
        host.layoutIfNeeded()
        await settleMainActor()
        host.frame = CGRect(origin: .zero, size: large.content.size)
        host.layoutIfNeeded()
        await settleMainActor()
        XCTAssertEqual(resizes().count, 1, "the keyboard resizes nothing on the Mac")
        host.removeFromSuperview()
        host.stop()
    }
}
