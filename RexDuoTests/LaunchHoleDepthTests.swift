import SwiftUI
import Testing
import UIKit
@testable import RexDuo

@MainActor
struct LaunchHoleDepthTests {
    typealias RGB = LaunchHoleDepth.RGB

    private var cover: RGB { RGB(UIColor(named: "LaunchBackground") ?? .black) }

    // MARK: Colour

    @Test func luminanceAndContrastFollowWCAG() {
        #expect(RGB.black.luminance == 0)
        #expect(abs(RGB.white.luminance - 1) < 1e-9)
        #expect(abs(RGB.white.contrast(with: .black) - 21) < 1e-9)
        #expect(RGB(r: 0.3, g: 0.6, b: 0.9).contrast(with: RGB(r: 0.3, g: 0.6, b: 0.9)) == 1)
        // Mid grey 0x77 on white is the textbook 4.48.
        let grey = RGB(r: 0x77 / 255.0, g: 0x77 / 255.0, b: 0x77 / 255.0)
        #expect(abs(grey.contrast(with: .white) - 4.48) < 0.01)
        // Order doesn't matter.
        #expect(grey.contrast(with: .black) == RGB.black.contrast(with: grey))
    }

    @Test func blendingIsStraightAlphaOver() {
        #expect(RGB.black.under(.white, alpha: 0.25) == RGB(r: 0.25, g: 0.25, b: 0.25))
        #expect(RGB.white.under(.black, alpha: 1) == .black)
        let c = RGB(r: 0.2, g: 0.4, b: 0.6)
        #expect(c.under(.white, alpha: 0) == c)
    }

    @Test func theSplashColourIsTheLaunchScreens() {
        #expect(abs(cover.r - 0x22 / 255.0) < 0.002 && abs(cover.g - 0x27 / 255.0) < 0.002 && abs(cover.b - 0x2e / 255.0) < 0.002)
    }

    // MARK: The guarantee

    @Test func theRimStandsOffTheSplashOverTheSplashsOwnColour() {
        // The case that started this: the app's canvas is exactly the splash colour.
        #expect(cover.contrast(with: cover) == 1)
        #expect(LaunchHoleDepth.rimContrast(cover: cover, content: cover) >= LaunchHoleDepth.minimumContrast)
        // And the opening itself is no longer the splash colour.
        #expect(LaunchHoleDepth.dimmed(cover) != cover)
    }

    @Test func theRimStandsOffTheSplashOverEveryThemesColours() {
        for theme in ThemeStore.all {
            let colours: [(String, Color)] = [("bg", theme.bg), ("fg", theme.fg), ("canvas", theme.chrome.canvas),
                                              ("sidebar", theme.chrome.sidebar), ("accent", theme.accent)]
            for (name, colour) in colours {
                let contrast = LaunchHoleDepth.rimContrast(cover: cover, content: RGB(UIColor(colour)))
                #expect(contrast >= LaunchHoleDepth.minimumContrast, "\(theme.name) \(name): \(contrast)")
            }
        }
    }

    @Test func theRimStandsOffTheSplashOverAnyColourAtAll() {
        // Every corner and a sweep of the colour cube, greys included: nothing an app could draw
        // makes the rim match the splash.
        var worst = Double.infinity
        let steps = stride(from: 0.0, through: 1.0, by: 1.0 / 16)
        for r in steps {
            for g in steps {
                for b in steps {
                    worst = min(worst, LaunchHoleDepth.rimContrast(cover: cover, content: RGB(r: r, g: g, b: b)))
                }
            }
        }
        #expect(worst >= LaunchHoleDepth.minimumContrast, "worst case \(worst)")
        // Black is the worst there is: the rim is light added on top, so it never gets darker.
        #expect(abs(worst - LaunchHoleDepth.rimContrast(cover: cover, content: .black)) < 1e-9)
    }

    @Test func theRimIsNeverDarkerThanItsOwnStrength() {
        let rim = LaunchHoleDepth.rim(over: .black)
        #expect(abs(rim.r - Double(LaunchHoleDepth.rimNear)) < 1e-9)
        #expect(LaunchHoleDepth.rim(over: .white).luminance > rim.luminance)
        #expect(LaunchHoleDepth.rimFar > LaunchHoleDepth.rimNear)
    }

    // MARK: The bitmap

    private static let size = CGSize(width: 150, height: 153)
    private static let margin: CGFloat = 12
    private static let scale: CGFloat = 4

    /// The premultiplied RGBA of the bitmap at a point of the art (origin at its top-left).
    private func pixel(_ image: CGImage, at p: CGPoint) -> (r: Double, g: Double, b: Double, a: Double) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = Int(((p.x + Self.margin) * Self.scale).rounded()), y = Int(((p.y + Self.margin) * Self.scale).rounded())
        // Core Graphics counts rows from the bottom.
        ctx.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y), width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255, Double(px[3]) / 255)
    }

    private func image() throws -> CGImage {
        try #require(LaunchHoleDepth.image(silhouette: LaunchSplashView.silhouette, size: Self.size, margin: Self.margin, scale: Self.scale))
    }

    @Test func theBitmapMatchesTheHoleBitmapsSize() throws {
        let img = try image()
        #expect(img.width == Int((Self.size.width + 2 * Self.margin) * Self.scale))
        #expect(img.height == Int((Self.size.height + 2 * Self.margin) * Self.scale))
    }

    @Test func nothingIsDrawnOnTheSplashItself() throws {
        let img = try image()
        // Outside Rexie: the corners of the art's box and the margin around it.
        for p in [CGPoint(x: 2, y: 2), CGPoint(x: 148, y: 2), CGPoint(x: 2, y: 151), CGPoint(x: 148, y: 151),
                  CGPoint(x: -8, y: 76), CGPoint(x: 158, y: 76), CGPoint(x: 75, y: -8), CGPoint(x: 75, y: 161)] {
            #expect(pixel(img, at: p).a == 0, "\(p)")
        }
        #expect(!LaunchSplashView.silhouette.contains(CGPoint(x: 2, y: 2)))
    }

    @Test func theOpeningStartsInsideTheLip() {
        let silhouette = LaunchSplashView.silhouette
        let opening = LaunchHoleDepth.opening(in: silhouette)
        let box = silhouette.boundingBoxOfPath, inner = opening.boundingBoxOfPath
        // Smaller than the silhouette by the lip on every side, and never outside it.
        #expect(abs((inner.minX - box.minX) - LaunchHoleDepth.lip) < 0.2)
        #expect(abs((box.maxX - inner.maxX) - LaunchHoleDepth.lip) < 0.2)
        #expect(abs((inner.minY - box.minY) - LaunchHoleDepth.lip) < 0.2)
        #expect(silhouette.contains(CGPoint(x: 78, y: 62)) && opening.contains(CGPoint(x: 78, y: 62)))
    }

    @Test func theMiddleIsDimmedAndTheTopLeftIsInShadow() throws {
        let img = try image()
        // The zoom pivot, deep inside the head: only the ambient dimming, plus what little of the
        // shadow reaches that far.
        let middle = pixel(img, at: CGPoint(x: 78, y: 62))
        #expect(middle.a >= Double(LaunchHoleDepth.ambient) - 0.02 && middle.a < 0.4)
        #expect(middle.r < 0.02 && middle.g < 0.02 && middle.b < 0.02)

        // Walk in from the top edge and from the bottom edge along the same column. The light is at
        // the top left, so the shadow lies under the top edge and not under the bottom one.
        let silhouette = LaunchSplashView.silhouette
        let x: CGFloat = 78
        let top = try #require(stride(from: CGFloat(0), to: 153, by: 0.25).first { silhouette.contains(CGPoint(x: x, y: $0)) })
        let bottom = try #require(stride(from: CGFloat(153), to: 0, by: -0.25).first { silhouette.contains(CGPoint(x: x, y: $0)) })
        let underTop = pixel(img, at: CGPoint(x: x, y: top + 3))
        let aboveBottom = pixel(img, at: CGPoint(x: x, y: bottom - 3))
        #expect(underTop.a > aboveBottom.a + 0.15, "top \(underTop.a) bottom \(aboveBottom.a)")
        #expect(underTop.a > middle.a + 0.15)
    }

    @Test func theCutEdgeIsLit() throws {
        let img = try image()
        let silhouette = LaunchSplashView.silhouette
        let x: CGFloat = 78
        let bottom = try #require(stride(from: CGFloat(153), to: 0, by: -0.25).first { silhouette.contains(CGPoint(x: x, y: $0)) })
        // Just inside the lip at the bottom: light, where a little further in is only dimming.
        let rim = pixel(img, at: CGPoint(x: x, y: bottom - LaunchHoleDepth.lip - LaunchHoleDepth.rimWidth / 2))
        let inside = pixel(img, at: CGPoint(x: x, y: bottom - 4))
        #expect(rim.r > 0.25, "rim \(rim)")
        #expect(inside.r < 0.05)
    }

    // MARK: The splash

    @Test func theDepthIsHiddenUntilThePeelStarts() throws {
        let splash = LaunchSplashView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        splash.layoutIfNeeded()
        // cover → [hole, depth]: the depth lies exactly on the hole bitmap and shows nothing yet,
        // so the first frame is still the static launch screen.
        let cover = try #require(splash.layer.sublayers?.first)
        let layers = try #require(cover.sublayers)
        #expect(layers.count == 2)
        #expect(layers[1].frame == layers[0].frame)
        #expect(layers[1].opacity == 0)
        #expect(layers[0].opacity == 1)
    }
}
