import Testing
import UIKit
@testable import Pteron

/// The launch art's picture, outline and numbers agree with each other, and the hole it leaves
/// clears the screen. `LaunchArt` is generated (Brand/make-launch-art.swift); the golden test
/// pins what it wrote, so a wrong regeneration fails even where derived points would move with it.
@MainActor
struct LaunchArtTests {
    // MARK: Golden

    @Test func theGeneratedNumbersAreTheOnesChecked() {
        #expect(LaunchArt.assetName == "LaunchMark")
        #expect(LaunchArt.size == CGSize(width: 182, height: 165))
        #expect(LaunchArt.box == CGRect(x: 60.2, y: 103.0, width: 900.8, height: 816.6))
        #expect(LaunchArt.pivot == CGPoint(x: 612.5, y: 384.0))
        #expect(LaunchArt.pivotRadius == 162.61)
        #expect(LaunchArt.extent.count == 720)
        // To the right, straight down the body, and to the left.
        #expect(LaunchArt.extent[0] == 186.16 && LaunchArt.extent[180] == 483.81 && LaunchArt.extent[360] == 184.25)
        // The silhouette's area is the area of the art before it: the sticker is as large.
        #expect(abs(area(LaunchArt.silhouette) - 12_255) < 15)
    }

    private func area(_ path: CGPath) -> CGFloat {
        let ring = points(path)
        var sum: CGFloat = 0
        for (i, a) in ring.enumerated() {
            let b = ring[(i + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    private func points(_ path: CGPath) -> [CGPoint] {
        var out: [CGPoint] = []
        path.flattened(threshold: 0.01).applyWithBlock { el in
            let e = el.pointee
            if e.type == .moveToPoint || e.type == .addLineToPoint { out.append(e.points[0]) }
        }
        return out
    }

    // MARK: The picture

    /// The image set in the source tree. A build holds only the picture for its own device.
    private nonisolated static let imageSet = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Pteron/Resources/Assets.xcassets/\(LaunchArt.assetName).imageset")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: imageSet.path), "the source tree is not on this machine"))
    func thePictureHasTheArtsSizeAtBothScales() throws {
        for scale in [2, 3] {
            let file = Self.imageSet.appendingPathComponent("\(LaunchArt.assetName)@\(scale)x.png")
            let image = try #require(UIImage(contentsOfFile: file.path)?.cgImage, "\(file.lastPathComponent)")
            #expect(image.width == Int(LaunchArt.size.width) * scale)
            #expect(image.height == Int(LaunchArt.size.height) * scale)
        }
    }

    @Test func theBundledPictureHasTheArtsSize() throws {
        let image = try #require(UIImage(named: LaunchArt.assetName))
        #expect(image.size == LaunchArt.size)
        #expect(image.cgImage?.width == Int(LaunchArt.size.width * image.scale))
    }

    /// The picture's shape is the outline's, by the generator's own gate: the hole the splash
    /// cuts lies under the art's edge all the way round, thin beak and crest included.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: imageSet.path), "the source tree is not on this machine"))
    func thePicturesShapeIsTheOutlines() throws {
        let scale = 3
        let file = Self.imageSet.appendingPathComponent("\(LaunchArt.assetName)@\(scale)x.png")
        let image = try #require(UIImage(contentsOfFile: file.path)?.cgImage)
        let w = image.width, h = image.height
        func alpha(_ draw: (CGContext) -> Void) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                draw(ctx)
                return true
            }
            try #require(ok)
            return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
        }
        let picture = try alpha { $0.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        let shape = try alpha { ctx in
            // Rows from the top, as the art's points count them.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            ctx.addPath(LaunchArt.silhouette)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillPath()
        }
        let ring = points(LaunchArt.silhouette)
        func distance(_ p: CGPoint) -> CGFloat {
            var best = CGFloat.infinity
            for (i, a) in ring.enumerated() {
                let b = ring[(i + 1) % ring.count]
                let v = CGPoint(x: b.x - a.x, y: b.y - a.y), q = CGPoint(x: p.x - a.x, y: p.y - a.y)
                let len = v.x * v.x + v.y * v.y
                let t = len > 0 ? min(max((q.x * v.x + q.y * v.y) / len, 0), 1) : 0
                best = min(best, hypot(q.x - t * v.x, q.y - t * v.y))
            }
            return best
        }
        var both = 0, either = 0, worst: CGFloat = 0
        for y in 0..<h {
            for x in 0..<w {
                let a = picture[y * w + x] >= 128, b = shape[y * w + x] >= 128
                if a && b { both += 1 }
                if a || b { either += 1 }
                // A pixel the two disagree on lies between their edges: its centre's distance to
                // the outline is how far apart they are there.
                if a != b {
                    worst = max(worst, distance(CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(scale), y: (CGFloat(y) + 0.5) / CGFloat(scale))) * CGFloat(scale))
                }
            }
        }
        let iou = Double(both) / Double(max(either, 1))
        #expect(iou >= 0.995, "IoU \(iou)")
        #expect(worst <= 0.5, "edge offset \(worst) px")
    }

    // MARK: The outline

    @Test func thePivotsCircleLiesInsideTheSilhouette() {
        let centre = LaunchArt.point(LaunchArt.pivot.x, LaunchArt.pivot.y)
        let radius = LaunchArt.pivotRadius * LaunchArt.pointsPerUnit - 0.05
        #expect(LaunchArt.silhouette.contains(centre))
        for i in 0..<360 {
            let a = CGFloat(i) * .pi / 180
            #expect(LaunchArt.silhouette.contains(CGPoint(x: centre.x + radius * cos(a), y: centre.y + radius * sin(a))), "\(i)°")
        }
        // And it is the head's: above the wing gap.
        #expect(centre.y < LaunchArt.size.height / 2)
    }

    @Test func theSilhouetteSitsInsideTheArtWithRoomForTheHolesMargin() {
        let box = LaunchArt.silhouette.boundingBoxOfPath
        let margin = LaunchSplashView.holeMargin
        #expect(box.minX >= margin && box.minY >= margin)
        #expect(LaunchArt.size.width - box.maxX >= margin && LaunchArt.size.height - box.maxY >= margin)
    }

    // MARK: Clearing the screen

    /// Where the splash puts the art and its pivot on a screen of `size` (centred, on the pixel grid).
    private func pivot(on size: CGSize, scale: CGFloat = 3) -> (art: CGPoint, pivot: CGPoint) {
        let x = ((size.width / 2 - LaunchArt.size.width / 2) * scale).rounded() / scale
        let y = ((size.height / 2 - LaunchArt.size.height / 2) * scale).rounded() / scale
        let p = LaunchArt.point(LaunchArt.pivot.x, LaunchArt.pivot.y)
        return (CGPoint(x: x, y: y), CGPoint(x: x + p.x, y: y + p.y))
    }

    private var reach: [CGFloat] { LaunchArt.extent.map { $0 * LaunchArt.pointsPerUnit } }

    /// Whether the hole, grown `scale` times about the pivot, shows the screen point `q`.
    private func shows(_ q: CGPoint, scale: CGFloat, art: CGPoint, pivot: CGPoint) -> Bool {
        let back = CGPoint(x: pivot.x + (q.x - pivot.x) / scale - art.x, y: pivot.y + (q.y - pivot.y) / scale - art.y)
        return LaunchArt.silhouette.contains(back)
    }

    private nonisolated static let screens = [CGSize(width: 402, height: 874), CGSize(width: 440, height: 956), CGSize(width: 375, height: 812),
                                  CGSize(width: 744, height: 1133), CGSize(width: 1024, height: 1366),
                                  CGSize(width: 874, height: 402), CGSize(width: 951, height: 669), CGSize(width: 466, height: 678)]

    @Test(arguments: screens)
    func theOpenHoleClearsTheWholeScreen(size: CGSize) {
        let (art, pivot) = pivot(on: size)
        let bounds = CGRect(origin: .zero, size: size)
        let scale = LaunchClearing.scale(pivot: pivot, in: bounds, extent: reach)
        // Every corner and edge midpoint, then the whole edge a point at a time.
        var edge = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height),
                    CGPoint(x: size.width / 2, y: 0), CGPoint(x: size.width / 2, y: size.height),
                    CGPoint(x: 0, y: size.height / 2), CGPoint(x: size.width, y: size.height / 2)]
        for x in stride(from: CGFloat(0), through: size.width, by: 1) { edge += [CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height)] }
        for y in stride(from: CGFloat(0), through: size.height, by: 1) { edge += [CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)] }
        #expect(edge.allSatisfy { shows($0, scale: scale, art: art, pivot: pivot) })
        // It is the exact fit plus the margin, no more: a little under the fit, some of the edge is covered.
        let fit = scale / LaunchClearing.margin
        #expect(!edge.allSatisfy { shows($0, scale: fit * 0.98, art: art, pivot: pivot) })
    }

    @Test func theScaleOnAnIPhoneIsTheMeasuredOne() {
        let size = CGSize(width: 402, height: 874)
        let scale = LaunchClearing.scale(pivot: pivot(on: size).pivot, in: CGRect(origin: .zero, size: size), extent: reach)
        // What the pivot circle alone would need is 16.6: the table saves a seventh of the zoom.
        #expect(abs(scale - 14.42) < 0.05, "\(scale)")
    }

    // MARK: LaunchClearing

    @Test func aRoundHoleNeedsTheFarthestCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 200)
        let circle = [CGFloat](repeating: 10, count: 720)
        let centred = LaunchClearing.scale(pivot: CGPoint(x: 50, y: 100), in: bounds, extent: circle)
        // The corner lies between two of the 720 directions, so the answer is a little under it,
        // which the margin is there for.
        let need = hypot(50, 100) / 10 * LaunchClearing.margin
        #expect(centred <= need && centred > need * 0.99)
        let off = LaunchClearing.scale(pivot: CGPoint(x: 20, y: 30), in: bounds, extent: circle)
        let far = hypot(80, 170) / 10 * LaunchClearing.margin
        #expect(off <= far && off > far * 0.99)
    }

    @Test func aLongReachTowardTheFarSideNeedsLess() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Reaches 50 to the right (the quarter turn around the x axis) and 10 elsewhere, from the left edge's middle.
        let lopsided = (0..<720).map { i -> CGFloat in i < 90 || i >= 630 ? 50 : 10 }
        let scale = LaunchClearing.scale(pivot: CGPoint(x: 10, y: 50), in: bounds, extent: lopsided)
        // To the right the edge is at most hypot(90, 50) away, 2.06 reaches. The most is needed
        // where the short reach starts, an eighth of a turn up: the top edge is 70.7 away there.
        #expect(abs(scale - 50 / sin(CGFloat.pi / 4) / 10 * LaunchClearing.margin) < 0.01)
    }

    @Test func edgeDistanceFollowsTheDirection() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 200)
        let p = CGPoint(x: 30, y: 50)
        #expect(LaunchClearing.edgeDistance(from: p, in: bounds, dx: 1, dy: 0) == 70)
        #expect(LaunchClearing.edgeDistance(from: p, in: bounds, dx: -1, dy: 0) == 30)
        #expect(LaunchClearing.edgeDistance(from: p, in: bounds, dx: 0, dy: 1) == 150)
        #expect(LaunchClearing.edgeDistance(from: p, in: bounds, dx: 0, dy: -1) == 50)
        // An empty table changes nothing.
        #expect(LaunchClearing.scale(pivot: p, in: bounds, extent: []) == LaunchClearing.margin)
    }
}
