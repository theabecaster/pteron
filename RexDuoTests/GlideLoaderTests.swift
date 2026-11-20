import RexKit
import XCTest
@testable import RexDuo

/// The loader of a pane with nothing to draw yet: when it shows, how it moves, how it looks.
@MainActor
final class GlideLoaderTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.isHidden = false
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func pause(_ seconds: TimeInterval) {
        let done = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    private func eventually(_ seconds: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { pause(0.01) }
        return condition()
    }

    // MARK: Timing

    func testItWaits400msThenFadesInOver180AndLoopsIn1200() {
        let t = GlideLoaderTiming()
        XCTAssertEqual(t.delay, 0.4)
        XCTAssertEqual(t.fadeIn, 0.18)
        XCTAssertEqual(t.fadeOut, 0.15)
        XCTAssertEqual(t.loop, 1.2)
        let m = GlideLoader.motions(still: false, timing: t)
        XCTAssertEqual(m.first, GlideLoader.Motion(layer: "loader", keyPath: "opacity", begin: 0.4, duration: 0.18, repeats: false))
        // The stroke's head and tail and the body's sway share one loop, and none starts before the fade.
        let loops = m.filter(\.repeats)
        XCTAssertEqual(loops.map(\.keyPath), ["strokeEnd", "strokeStart", "transform.rotation.z"])
        XCTAssertTrue(loops.allSatisfy { $0.duration == 1.2 && $0.begin == 0.4 })
    }

    func testReduceMotionHoldsStillAndBreathes() {
        let m = GlideLoader.motions(still: true, timing: GlideLoaderTiming())
        XCTAssertEqual(m.map(\.keyPath), ["opacity", "opacity"], "the fade in and a slow breath: nothing moves")
        XCTAssertEqual(m.last?.layer, "mark")
        let loader = GlideLoader(tint: .white, still: true)
        XCTAssertEqual(loader.addedMotions["glide"], [], "no gliding stroke")
        XCTAssertEqual(loader.addedMotions["mark"], ["opacity"])
    }

    func testTheLayersGetExactlyThePlannedMotions() {
        let loader = GlideLoader(tint: .white, still: false)
        XCTAssertEqual(loader.addedMotions["loader"], ["show"])
        XCTAssertEqual(Set(loader.addedMotions["glide"] ?? []), ["strokeEnd", "strokeStart"])
        XCTAssertEqual(loader.addedMotions["mark"], ["transform.rotation.z"])
    }

    func testItIsAbout44PointsAndTakesNoTouches() {
        XCTAssertEqual(GlideLoader.markSize.width, 44)
        XCTAssertEqual(GlideLoader.markSize.height, 40)
        let loader = GlideLoader(tint: .white, still: false)
        XCTAssertFalse(loader.isUserInteractionEnabled)
        let box = GlideLoader.outline.boundingBoxOfPath
        XCTAssertTrue(CGRect(origin: .zero, size: GlideLoader.markSize).insetBy(dx: -0.5, dy: -0.5).contains(box))
        XCTAssertTrue(box.contains(GlideLoader.eye.boundingBoxOfPath), "the eye lies inside the body")
    }

    func testItIsInvisibleBeforeItsDelayAndVisibleAfterIt() {
        let loader = GlideLoader(tint: .white, still: false, timing: GlideLoaderTiming(delay: 0.25, fadeIn: 0.05, fadeOut: 0.05))
        window.addSubview(loader)
        pause(0.08)
        XCTAssertEqual(loader.layer.presentation()?.opacity ?? 0, 0, accuracy: 0.01, "a fast open shows nothing")
        XCTAssertTrue(eventually { (loader.layer.presentation()?.opacity ?? 0) > 0.99 })
        loader.dismiss()
        XCTAssertTrue(eventually { loader.superview == nil }, "fades out and removes itself")
    }

    func testALoaderThatNeverShowedGoesAtOnce() {
        let loader = GlideLoader(tint: .white, still: false)
        window.addSubview(loader)
        loader.dismiss()
        XCTAssertNil(loader.superview)
    }

    // MARK: The host

    private func makeHost(sizing: SizingMode = .mirror) -> TerminalHost {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        let host = TerminalHost(stream: stream, sizing: sizing, fontSize: 12, theme: ThemeStore.fallback)
        host.hardwareKeyboard = { false }
        host.leaveTiming.settle = 0.02
        return host
    }

    private func show(_ host: TerminalHost) {
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
    }

    func testAPaneThatOpensHasALoaderInItsCenter() {
        let host = makeHost()
        XCTAssertNil(host.loader)
        show(host)
        let loader = try? XCTUnwrap(host.loader)
        XCTAssertEqual(loader?.center, CGPoint(x: host.bounds.midX, y: host.bounds.midY))
        XCTAssertEqual(loader?.bounds.size, GlideLoader.markSize)
        host.removeFromSuperview()
    }

    func testTheFirstScreenEndsTheLoader() {
        let host = makeHost()
        show(host)
        XCTAssertNotNil(host.loader)
        // The fallback screen read: text for the terminal, then the size it already has.
        host.streamSnapshot("hello")
        host.streamResized(cols: 80, rows: 24, owner: nil)
        XCTAssertTrue(eventually { host.loader == nil })
        host.removeFromSuperview()
    }

    func testAScreenStillHeldForItsResizeKeepsTheLoaderUntilTheHoldEnds() {
        let host = makeHost(sizing: .fit)
        show(host)
        host.stream.setClaimPending(true)
        host.streamSnapshot("hello")
        pause(0.1)
        XCTAssertNotNil(host.loader, "the screen is not drawn yet")
        host.streamFence(false, screen: true)
        XCTAssertNil(host.loader)
        host.removeFromSuperview()
    }

    func testAParkedPaneWithAScreenComesBackWithoutALoader() {
        let pool = TerminalHostPool()
        // No pane stays warm here (as in Low Power Mode): the one that leaves parks.
        pool.power = { (lowPower: true, hot: false) }
        let host = makeHost()
        pool.add(host, for: TerminalHostPool.Key(server: UUID(), session: "s", block: "b"))
        show(host)
        host.streamSnapshot("hello")
        host.streamResized(cols: 80, rows: 24, owner: nil)
        XCTAssertTrue(eventually { host.loader == nil })
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked })
        show(host)
        XCTAssertNil(host.loader, "its last screen is there")
        host.removeFromSuperview()
    }

    func testAPaneParkedBeforeItsFirstScreenComesBackWithOne() {
        let pool = TerminalHostPool()
        // No pane stays warm here (as in Low Power Mode): the one that leaves parks.
        pool.power = { (lowPower: true, hot: false) }
        let host = makeHost()
        pool.add(host, for: TerminalHostPool.Key(server: UUID(), session: "s", block: "b"))
        show(host)
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked })
        XCTAssertNil(host.loader, "nothing animates off screen")
        show(host)
        XCTAssertNotNil(host.loader)
        host.removeFromSuperview()
    }

    func testConnectingComesLaterAndUnderTheLoader() {
        let host = makeHost()
        host.connectingDelay = 0.3
        show(host)
        // After the start's own first status (no connection in this test), the opening's.
        pause(0.05)
        host.streamStatus(.connecting)
        pause(0.1)
        XCTAssertNil(host.statusChipText, "not before its own, longer delay")
        XCTAssertTrue(eventually { host.statusChipText == "Connecting…" })
        let loader = try? XCTUnwrap(host.loader)
        XCTAssertGreaterThan(host.statusChipFrame.minY, loader?.frame.maxY ?? .infinity)
        XCTAssertEqual(host.statusChipFrame.midX, host.bounds.midX, accuracy: 0.5)
        host.removeFromSuperview()
    }

    func testAThemeChangeReachesTheLoader() {
        let host = makeHost()
        show(host)
        let light = ThemeStore.theme(Prefs.defaultLightTheme)
        host.applyTheme(light)
        XCTAssertNotNil(host.loader)
        host.removeFromSuperview()
    }

    // MARK: Pictures

    /// The loader, held in the middle of its loop, over a pane-sized view in the theme's
    /// background. Returns the picture's pixels (RGBA) and writes it as a PNG.
    private func picture(_ name: String, theme: TermTheme, size: CGSize, still: Bool) throws -> (pixels: [UInt8], width: Int, height: Int, box: CGRect) {
        window.frame = CGRect(origin: .zero, size: size)
        let pane = UIView(frame: window.bounds)
        pane.backgroundColor = theme.uiBG
        window.addSubview(pane)
        defer { pane.removeFromSuperview() }
        let loader = GlideLoader(tint: theme.uiFG, still: still)
        loader.center = CGPoint(x: pane.bounds.midX, y: pane.bounds.midY)
        pane.addSubview(loader)
        loader.pose(strokeStart: 0.2, strokeEnd: 0.62, tilt: 0.03)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            pane.drawHierarchy(in: pane.bounds, afterScreenUpdates: true)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-loader")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: dir.appendingPathComponent(name + ".png"))
        print("GLIDE_LOADER_PICTURE \(dir.appendingPathComponent(name + ".png").path)")
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (pixels, cg.width, cg.height, loader.frame)
    }

    /// Counts the pixels that are not the background, inside and outside the loader's box
    /// (grown by 6 pt for the sway and the stroke's soft edge), and the strongest one's
    /// distance from the background.
    private func marks(_ p: (pixels: [UInt8], width: Int, height: Int, box: CGRect)) -> (inside: Int, outside: Int, strongest: Int) {
        let bg = Array(p.pixels[0..<3])
        let box = p.box.insetBy(dx: -6, dy: -6).applying(CGAffineTransform(scaleX: 2, y: 2))
        var inside = 0, outside = 0, strongest = 0
        for y in 0..<p.height {
            for x in 0..<p.width {
                let i = (y * p.width + x) * 4
                let d = abs(Int(p.pixels[i]) - Int(bg[0])) + abs(Int(p.pixels[i + 1]) - Int(bg[1])) + abs(Int(p.pixels[i + 2]) - Int(bg[2]))
                guard d > 6 else { continue }
                if box.contains(CGPoint(x: x, y: y)) { inside += 1 } else { outside += 1 }
                strongest = max(strongest, d)
            }
        }
        return (inside, outside, strongest)
    }

    private func checkPictures(_ place: String, size: CGSize) throws {
        let dark = ThemeStore.theme(Prefs.defaultDarkTheme), light = ThemeStore.theme(Prefs.defaultLightTheme)
        XCTAssertTrue(dark.isDark)
        XCTAssertFalse(light.isDark)
        for (name, theme, still) in [("dark", dark, false), ("light", light, false), ("reduce-motion", dark, true)] {
            let m = marks(try picture("\(place)-\(name)", theme: theme, size: size, still: still))
            XCTAssertGreaterThan(m.inside, 150, "\(place) \(name): Glide is drawn")
            XCTAssertLessThan(m.inside, 44 * 40 * 4 * 2, "\(place) \(name): about 44 pt")
            XCTAssertEqual(m.outside, 0, "\(place) \(name): nothing else on the pane")
            XCTAssertGreaterThan(m.strongest, 120, "\(place) \(name): in the theme's text color, clear against its background")
        }
    }

    func testPicturesOnTheDuoFolded() throws {
        // The outer screen's pane, inside its bar and insets (docs/debug-args.md, `folded`).
        try checkPictures("duo-folded", size: CGSize(width: 382, height: 600))
    }

    func testPicturesOnTheIPhone() throws {
        try checkPictures("iphone", size: CGSize(width: 402, height: 778))
    }

    func testLightAndDarkDrawTheSameShapeInTheirOwnColors() throws {
        let dark = ThemeStore.theme(Prefs.defaultDarkTheme), light = ThemeStore.theme(Prefs.defaultLightTheme)
        let size = CGSize(width: 200, height: 200)
        let d = try picture("compare-dark", theme: dark, size: size, still: true)
        let l = try picture("compare-light", theme: light, size: size, still: true)
        // The center of the body: lighter than a dark background, darker than a light one.
        let i = (d.height / 2 * d.width + d.width / 2) * 4
        func luma(_ p: [UInt8], _ i: Int) -> Int { Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]) }
        XCTAssertGreaterThan(luma(d.pixels, i), luma(d.pixels, 0))
        XCTAssertLessThan(luma(l.pixels, i), luma(l.pixels, 0))
    }
}
