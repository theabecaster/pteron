import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import RexDuo

/// How a picked photo is prepared: HEIC to JPEG, downscaled, oriented, without its location, and
/// never sent with a location it couldn't remove unless the user says so. The fixture is a
/// 4032 × 3024 HEIC with EXIF orientation 6 and a made-up location (GPS 0.5 N 0.5 E, invented IPTC
/// place names).
final class ImagePrepTests: XCTestCase {
    typealias P = ImagePrep.Plan

    func testHEICBecomesJPEGAndPNGStaysPNG() {
        XCTAssertEqual(ImagePrep.plan(type: .heic, width: 4032, height: 3024, original: false), P.render(.jpeg, maxEdge: 2000))
        XCTAssertEqual(ImagePrep.plan(type: .heic, width: 800, height: 600, original: false), P.render(.jpeg, maxEdge: 800))
        XCTAssertEqual(ImagePrep.plan(type: .png, width: 1179, height: 2556, original: false), P.render(.png, maxEdge: 2000))
        XCTAssertEqual(ImagePrep.plan(type: .png, width: 1000, height: 800, original: false), P.stripLocation)
        XCTAssertEqual(ImagePrep.plan(type: .jpeg, width: 1000, height: 800, original: false), P.stripLocation)
        XCTAssertEqual(ImagePrep.plan(type: .jpeg, width: 1000, height: 800, orientation: 6, original: false),
                       P.render(.jpeg, maxEdge: 1000), "the orientation goes into the pixels")
        XCTAssertEqual(ImagePrep.plan(type: .heic, width: 4032, height: 3024, original: true), P.keep, "Send Original")
    }

    func testEveryOtherStillImageIsDrawnAgain() {
        XCTAssertEqual(ImagePrep.plan(type: .tiff, width: 3000, height: 2000, original: false), P.render(.jpeg, maxEdge: 2000))
        XCTAssertEqual(ImagePrep.plan(type: .webP, width: 1200, height: 800, original: false), P.render(.jpeg, maxEdge: 1200))
        XCTAssertEqual(ImagePrep.plan(type: .rawImage, width: 6000, height: 4000, original: false), P.render(.jpeg, maxEdge: 2000))
        XCTAssertEqual(ImagePrep.plan(type: .heif, width: 4000, height: 3000, frames: 3, original: false),
                       P.render(.jpeg, maxEdge: 2000), "a HEIF of several images sends its primary image")
        XCTAssertEqual(ImagePrep.plan(type: .tiff, width: 500, height: 500, alpha: true, original: false),
                       P.render(.png, maxEdge: 500), "transparency stays")
        XCTAssertEqual(ImagePrep.plan(type: .gif, width: 400, height: 400, original: false), P.render(.jpeg, maxEdge: 400))
        XCTAssertEqual(ImagePrep.plan(type: .tiff, width: 0, height: 0, original: false), P.render(.jpeg, maxEdge: 2000),
                       "an image whose size can't be read is still drawn, never sent as it is")
    }

    func testWhatIsNotAStillImageGoesAsItIs() {
        XCTAssertEqual(ImagePrep.plan(type: .gif, width: 400, height: 400, frames: 12, original: false), P.keep)
        XCTAssertEqual(ImagePrep.plan(type: .mpeg4Movie, width: 1920, height: 1080, original: false), P.keep)
        XCTAssertEqual(ImagePrep.plan(type: .pdf, width: 0, height: 0, original: false), P.keep)
        XCTAssertEqual(ImagePrep.plan(type: nil, width: 0, height: 0, original: false), P.keep)
    }

    func testDownscaleKeepsTheAspect() {
        XCTAssertTrue(ImagePrep.scaled(width: 4032, height: 3024, maxEdge: 2000) == (2000, 1500))
        XCTAssertTrue(ImagePrep.scaled(width: 1179, height: 2556, maxEdge: 2000) == (923, 2000))
        XCTAssertTrue(ImagePrep.scaled(width: 640, height: 480, maxEdge: 2000) == (640, 480))
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

    /// The fixture's pixels as `type`, with its location and place names, `edge` pixels at most.
    private func withLocation(_ type: UTType, edge: Int, name: String) throws -> StagedFile {
        let heic = try fixture()
        defer { FileStaging.discard([heic]) }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(heic.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: edge,
        ] as CFDictionary))
        let source = try properties(heic.url).props
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyGPSDictionary: try XCTUnwrap(source[kCGImagePropertyGPSDictionary]),
            kCGImagePropertyIPTCDictionary: try XCTUnwrap(source[kCGImagePropertyIPTCDictionary]),
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let f = try FileStaging.stage(data: data as Data, as: name)
        let props = try properties(f.url).props
        XCTAssertNotNil(props[kCGImagePropertyGPSDictionary], "the input has a location")
        XCTAssertNotNil(props[kCGImagePropertyIPTCDictionary], "the input has place names")
        XCTAssertFalse(ImagePrep.isClean(data as Data))
        return f
    }

    func testAPhotoIsConvertedScaledOrientedAndLosesItsLocation() throws {
        let heic = try fixture()
        XCTAssertNotNil(try properties(heic.url).props[kCGImagePropertyGPSDictionary], "the fixture has a location")
        let out = try ready(ImagePrep.prepare(heic, original: false))
        defer { FileStaging.discard([out]) }
        XCTAssertEqual(out.name, "photo-gps-rotated.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.url.path), "the HEIC copy is replaced")
        let (type, props) = try properties(out.url)
        XCTAssertEqual(type, UTType.jpeg.identifier)
        try assertNoLocation(out.url)
        // 4032 × 3024 turned a quarter: 1500 × 2000, upright, with no orientation left to apply.
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1500)
        XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 2000)
        XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        let onDisk = try FileManager.default.attributesOfItem(atPath: out.url.path)[.size] as? NSNumber
        XCTAssertEqual(onDisk?.int64Value, out.size)
    }

    func testASmallJPEGKeepsItsPixelsAndLosesItsLocationAndPlaceNames() throws {
        let jpeg = try withLocation(.jpeg, edge: 600, name: "small.jpg")
        let out = try ready(ImagePrep.prepare(jpeg, original: false))
        defer { FileStaging.discard([out]) }
        XCTAssertEqual(out.name, "small.jpg")
        let (type, props) = try properties(out.url)
        XCTAssertEqual(type, UTType.jpeg.identifier)
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 600)
        try assertNoLocation(out.url)
    }

    func testATIFFIsDrawnAgainWithoutItsLocation() throws {
        let tiff = try withLocation(.tiff, edge: 500, name: "scan.tiff")
        let out = try ready(ImagePrep.prepare(tiff, original: false))
        defer { FileStaging.discard([out]) }
        XCTAssertEqual(out.name, "scan.jpg")
        XCTAssertEqual(try properties(out.url).type, UTType.jpeg.identifier)
        try assertNoLocation(out.url)
    }

    func testAnImageThatCantBeReadIsNeverSentSilently() throws {
        let broken = try FileStaging.stage(data: Data("not really a photo".utf8), as: "IMG_0001.jpg")
        defer { FileStaging.discard([broken]) }
        XCTAssertEqual(ImagePrep.prepare(broken, original: false), .locationKept(broken), "the user is asked first")
        let text = try FileStaging.stage(data: Data("notes".utf8), as: "notes.txt")
        defer { FileStaging.discard([text]) }
        XCTAssertEqual(ImagePrep.prepare(text, original: false), .ready(text), "not an image")
    }

    func testSendOriginalSendsTheBytesUntouched() throws {
        let heic = try fixture()
        defer { FileStaging.discard([heic]) }
        let before = try Data(contentsOf: heic.url)
        let out = ImagePrep.prepare(heic, original: true)
        XCTAssertEqual(out, .ready(heic))
        XCTAssertEqual(try Data(contentsOf: heic.url), before)
    }
}
