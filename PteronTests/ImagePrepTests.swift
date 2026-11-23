import XCTest
import ImageIO
import UIKit
import UniformTypeIdentifiers
@testable import Pteron

/// How a picked photo is prepared, always and with no switch: HEIC to JPEG, a photo at most
/// 2,048 px, a screenshot or a PNG kept sharp up to 3,000 px, oriented, without its location, and
/// never sent with a location it couldn't remove unless the user says so. The fixture is a
/// 4032 × 3024 HEIC with EXIF orientation 6 and a made-up location (GPS 0.5 N 0.5 E, invented IPTC
/// place names).
final class ImagePrepTests: XCTestCase {
    typealias P = ImagePrep.Plan

    func testTheFixedValues() {
        XCTAssertEqual(ImagePrep.photoLongEdge, 2048, "GPT-5.5's high detail; under Claude's 2,576 px and 4,784 patches for 4:3")
        XCTAssertEqual(ImagePrep.screenshotLongEdge, 3000, "Claude's limit once a conversation holds more than 20 images")
        XCTAssertEqual(ImagePrep.jpegQuality, 0.85)
        XCTAssertLessThanOrEqual(ImagePrep.targetBytes, 7_500_000, "under Claude's 10 MB per image once base64-encoded")
    }

    func testHEICBecomesJPEGAndPNGStaysPNG() {
        XCTAssertEqual(ImagePrep.plan(type: .heic, width: 4032, height: 3024), P.render(.jpeg, maxEdge: 2048))
        XCTAssertEqual(ImagePrep.plan(type: .heic, width: 800, height: 600), P.render(.jpeg, maxEdge: 800), "converted at any size")
        XCTAssertEqual(ImagePrep.plan(type: .png, width: 1000, height: 800), P.stripLocation)
        XCTAssertEqual(ImagePrep.plan(type: .jpeg, width: 1000, height: 800), P.stripLocation)
        XCTAssertEqual(ImagePrep.plan(type: .jpeg, width: 4032, height: 3024), P.render(.jpeg, maxEdge: 2048), "a photo is capped")
        XCTAssertEqual(ImagePrep.plan(type: .jpeg, width: 1000, height: 800, orientation: 6),
                       P.render(.jpeg, maxEdge: 1000), "the orientation goes into the pixels")
    }

    func testScreenshotsStayPNGAtFullSize() {
        // iPhone 17 Pro Max and the 13-inch iPad: every pixel goes, untouched.
        XCTAssertEqual(ImagePrep.plan(type: .png, width: 1320, height: 2868), P.stripLocation)
        XCTAssertEqual(ImagePrep.plan(type: .png, width: 2064, height: 2752), P.stripLocation)
        XCTAssertEqual(ImagePrep.plan(type: .png, width: 4000, height: 2000), P.render(.png, maxEdge: 3000),
                       "a PNG past the agents' limit is scaled, still PNG")
        // A screenshot saved as HEIF (iOS marks it in its EXIF) becomes PNG, not a blurred JPEG.
        XCTAssertEqual(ImagePrep.plan(type: .heic, width: 1206, height: 2622, screenshot: true), P.render(.png, maxEdge: 2622))
        XCTAssertEqual(ImagePrep.plan(type: .jpeg, width: 1206, height: 2622, screenshot: true), P.stripLocation,
                       "a JPEG screenshot keeps its size and format")
        XCTAssertTrue(ImagePrep.isScreenshot([kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Screenshot"]]))
        XCTAssertFalse(ImagePrep.isScreenshot([kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Holiday"]]))
        XCTAssertFalse(ImagePrep.isScreenshot([:]))
    }

    func testEveryOtherStillImageIsDrawnAgain() {
        XCTAssertEqual(ImagePrep.plan(type: .tiff, width: 3000, height: 2000), P.render(.jpeg, maxEdge: 2048))
        XCTAssertEqual(ImagePrep.plan(type: .webP, width: 1200, height: 800), P.render(.jpeg, maxEdge: 1200))
        XCTAssertEqual(ImagePrep.plan(type: .rawImage, width: 6000, height: 4000), P.render(.jpeg, maxEdge: 2048))
        XCTAssertEqual(ImagePrep.plan(type: .heif, width: 4000, height: 3000, frames: 3),
                       P.render(.jpeg, maxEdge: 2048), "a HEIF of several images sends its primary image")
        XCTAssertEqual(ImagePrep.plan(type: .tiff, width: 500, height: 500, alpha: true),
                       P.render(.png, maxEdge: 500), "transparency stays")
        XCTAssertEqual(ImagePrep.plan(type: .gif, width: 400, height: 400), P.render(.jpeg, maxEdge: 400))
        XCTAssertEqual(ImagePrep.plan(type: .tiff, width: 0, height: 0), P.render(.jpeg, maxEdge: 2048),
                       "an image whose size can't be read is still drawn, never sent as it is")
    }

    func testWhatIsNotAStillImageGoesAsItIs() {
        XCTAssertEqual(ImagePrep.plan(type: .gif, width: 400, height: 400, frames: 12), P.keep)
        XCTAssertEqual(ImagePrep.plan(type: .mpeg4Movie, width: 1920, height: 1080), P.keep)
        XCTAssertEqual(ImagePrep.plan(type: .quickTimeMovie, width: 3840, height: 2160), P.keep, "videos go as they are")
        XCTAssertEqual(ImagePrep.plan(type: .pdf, width: 0, height: 0), P.keep)
        XCTAssertEqual(ImagePrep.plan(type: nil, width: 0, height: 0), P.keep)
    }

    func testDownscaleKeepsTheAspect() {
        XCTAssertTrue(ImagePrep.scaled(width: 4032, height: 3024, maxEdge: 2048) == (2048, 1536))
        XCTAssertTrue(ImagePrep.scaled(width: 1179, height: 2556, maxEdge: 3000) == (1179, 2556))
        XCTAssertTrue(ImagePrep.scaled(width: 640, height: 480, maxEdge: 2048) == (640, 480))
    }

    // MARK: Files

    private func fixture() throws -> StagedFile {
        let url = try XCTUnwrap(Bundle(for: ImagePrepTests.self).url(forResource: "photo-gps-rotated", withExtension: "heic"))
        return try FileStaging.stage(copying: url, as: "photo-gps-rotated.heic")
    }

    private func properties(_ url: URL) throws -> (type: String, props: [CFString: Any]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return (CGImageSourceGetType(src) as String? ?? "", props)
    }

    private func pixels(_ url: URL) throws -> (width: Int, height: Int) {
        let props = try properties(url).props
        return ((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
                (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
    }

    private func ready(_ r: ImagePrep.Result, file: StaticString = #filePath, line: UInt = #line) throws -> StagedFile {
        guard case .ready(let f) = r else { XCTFail("not ready: \(r)", file: file, line: line); throw XCTSkip() }
        return f
    }

    private func assertNoLocation(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let props = try properties(url).props
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "GPS", file: file, line: line)
        XCTAssertNil(props[kCGImagePropertyIPTCDictionary], "IPTC place names", file: file, line: line)
        XCTAssertTrue(ImagePrep.isClean(try Data(contentsOf: url)), "no XMP place or position", file: file, line: line)
    }

    /// The fixture's pixels as `type`, with its location and place names, `edge` pixels at most,
    /// and `exif` when given.
    private func withLocation(_ type: UTType, edge: Int, name: String, exif: [CFString: Any]? = nil) throws -> StagedFile {
        let heic = try fixture()
        defer { FileStaging.discard([heic]) }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(heic.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: edge,
        ] as CFDictionary))
        let source = try properties(heic.url).props
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: try XCTUnwrap(source[kCGImagePropertyGPSDictionary]),
            kCGImagePropertyIPTCDictionary: try XCTUnwrap(source[kCGImagePropertyIPTCDictionary]),
        ]
        if let exif { props[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let f = try FileStaging.stage(data: data as Data, as: name)
        let read = try properties(f.url).props
        XCTAssertNotNil(read[kCGImagePropertyGPSDictionary], "the input has a location")
        XCTAssertNotNil(read[kCGImagePropertyIPTCDictionary], "the input has place names")
        XCTAssertFalse(ImagePrep.isClean(data as Data))
        return f
    }

    /// A PNG of `width` × `height` with text-like detail, so it doesn't compress to nothing.
    private func png(width: Int, height: Int, name: String) throws -> StagedFile {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            for y in stride(from: 0, to: height, by: 24) {
                for x in stride(from: (y / 24) % 3 * 7, to: width, by: 19) { ctx.fill(CGRect(x: x, y: y, width: 9, height: 14)) }
            }
        }
        return try FileStaging.stage(data: data, as: name)
    }

    func testAPhotoIsConvertedScaledOrientedAndLosesItsLocation() throws {
        let heic = try fixture()
        XCTAssertNotNil(try properties(heic.url).props[kCGImagePropertyGPSDictionary], "the fixture has a location")
        let out = try ready(ImagePrep.prepare(heic))
        defer { FileStaging.discard([out]) }
        XCTAssertEqual(out.name, "photo-gps-rotated.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.url.path), "the HEIC copy is replaced")
        let (type, props) = try properties(out.url)
        XCTAssertEqual(type, UTType.jpeg.identifier, "HEIC is always converted")
        try assertNoLocation(out.url)
        // 4032 × 3024 turned a quarter: 1536 × 2048, upright, with no orientation left to apply.
        XCTAssertTrue(try pixels(out.url) == (1536, 2048))
        XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        let onDisk = try FileManager.default.attributesOfItem(atPath: out.url.path)[.size] as? NSNumber
        XCTAssertEqual(onDisk?.int64Value, out.size)
        XCTAssertLessThan(out.size, Int64(ImagePrep.targetBytes))
    }

    func testASmallJPEGKeepsItsPixelsAndLosesItsLocationAndPlaceNames() throws {
        let jpeg = try withLocation(.jpeg, edge: 600, name: "small.jpg")
        let out = try ready(ImagePrep.prepare(jpeg))
        defer { FileStaging.discard([out]) }
        XCTAssertEqual(out.name, "small.jpg")
        let (type, props) = try properties(out.url)
        XCTAssertEqual(type, UTType.jpeg.identifier)
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 600)
        try assertNoLocation(out.url)
    }

    func testATIFFIsDrawnAgainWithoutItsLocation() throws {
        let tiff = try withLocation(.tiff, edge: 500, name: "scan.tiff")
        let out = try ready(ImagePrep.prepare(tiff))
        defer { FileStaging.discard([out]) }
        XCTAssertEqual(out.name, "scan.jpg")
        XCTAssertEqual(try properties(out.url).type, UTType.jpeg.identifier)
        try assertNoLocation(out.url)
    }

    func testAScreenshotMarkedByIOSBecomesPNGWithoutItsLocation() throws {
        let shot = try withLocation(.tiff, edge: 640, name: "IMG_0002.tiff",
                                    exif: [kCGImagePropertyExifUserComment: "Screenshot"])
        let out = try ready(ImagePrep.prepare(shot))
        defer { FileStaging.discard([out]) }
        XCTAssertEqual(out.name, "IMG_0002.png")
        XCTAssertEqual(try properties(out.url).type, UTType.png.identifier, "sharp text, no JPEG blur")
        XCTAssertTrue(try pixels(out.url) == (640, 480), "at full size")
        try assertNoLocation(out.url)
    }

    func testAPhoneScreenshotGoesAtFullSizeAndALargePNGIsCapped() throws {
        let shot = try png(width: 1206, height: 2622, name: "Screenshot.png")
        let kept = try ready(ImagePrep.prepare(shot))
        defer { FileStaging.discard([kept]) }
        XCTAssertEqual(kept.name, "Screenshot.png")
        XCTAssertEqual(try properties(kept.url).type, UTType.png.identifier)
        XCTAssertTrue(try pixels(kept.url) == (1206, 2622), "every pixel of an iPhone 17 Pro screenshot")

        let big = try png(width: 4000, height: 1000, name: "Wide.png")
        let capped = try ready(ImagePrep.prepare(big))
        defer { FileStaging.discard([capped]) }
        XCTAssertEqual(try properties(capped.url).type, UTType.png.identifier)
        XCTAssertTrue(try pixels(capped.url) == (3000, 750), "scaled to the agents' limit, still PNG")
        XCTAssertLessThanOrEqual(capped.size, Int64(ImagePrep.targetBytes))
    }

    func testAnImageThatCantBeReadIsNeverSentSilently() throws {
        let broken = try FileStaging.stage(data: Data("not really a photo".utf8), as: "IMG_0001.jpg")
        defer { FileStaging.discard([broken]) }
        XCTAssertEqual(ImagePrep.prepare(broken), .locationKept(broken), "the user is asked first")
        let text = try FileStaging.stage(data: Data("notes".utf8), as: "notes.txt")
        defer { FileStaging.discard([text]) }
        XCTAssertEqual(ImagePrep.prepare(text), .ready(text), "not an image")
    }
}
