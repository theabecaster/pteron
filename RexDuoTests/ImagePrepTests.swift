import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import RexDuo

/// How a picked photo is prepared: HEIC to JPEG, downscaled, oriented, without its location.
/// The fixture is a 4032 × 3024 HEIC with a location and EXIF orientation 6.
final class ImagePrepTests: XCTestCase {
    func testHEICBecomesJPEGAndPNGStaysPNG() {
        typealias P = ImagePrep.Plan
        XCTAssertEqual(ImagePrep.plan(type: .heic, width: 4032, height: 3024, original: false), P.render(.jpeg, maxEdge: 2000))
        XCTAssertEqual(ImagePrep.plan(type: .heic, width: 800, height: 600, original: false), P.render(.jpeg, maxEdge: 800))
        XCTAssertEqual(ImagePrep.plan(type: .png, width: 1179, height: 2556, original: false), P.render(.png, maxEdge: 2000))
        XCTAssertEqual(ImagePrep.plan(type: .png, width: 1000, height: 800, original: false), P.stripLocation)
        XCTAssertEqual(ImagePrep.plan(type: .jpeg, width: 1000, height: 800, original: false), P.stripLocation)
        XCTAssertEqual(ImagePrep.plan(type: .jpeg, width: 1000, height: 800, orientation: 6, original: false),
                       P.render(.jpeg, maxEdge: 1000), "the orientation goes into the pixels")
        XCTAssertEqual(ImagePrep.plan(type: .gif, width: 4000, height: 4000, original: false), P.keep)
        XCTAssertEqual(ImagePrep.plan(type: .heic, width: 4032, height: 3024, original: true), P.keep, "Send Original")
        XCTAssertEqual(ImagePrep.plan(type: .mpeg4Movie, width: 1920, height: 1080, original: false), P.keep)
    }

    func testDownscaleKeepsTheAspect() {
        XCTAssertTrue(ImagePrep.scaled(width: 4032, height: 3024, maxEdge: 2000) == (2000, 1500))
        XCTAssertTrue(ImagePrep.scaled(width: 1179, height: 2556, maxEdge: 2000) == (923, 2000))
        XCTAssertTrue(ImagePrep.scaled(width: 640, height: 480, maxEdge: 2000) == (640, 480))
    }

    private func fixture(_ name: String, _ ext: String) throws -> StagedFile {
        let url = try XCTUnwrap(Bundle(for: ImagePrepTests.self).url(forResource: name, withExtension: ext))
        return try FileStaging.stage(copying: url, as: "\(name).\(ext)")
    }

    private func properties(_ f: StagedFile) throws -> (type: String, props: [CFString: Any]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(f.url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return (CGImageSourceGetType(src) as String? ?? "", props)
    }

    func testAPhotoIsConvertedScaledOrientedAndLosesItsLocation() throws {
        let heic = try fixture("photo-gps-rotated", "heic")
        let before = try properties(heic).props
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary], "the fixture has a location")
        XCTAssertEqual((before[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
        let out = ImagePrep.prepare(heic, original: false)
        defer { FileStaging.discard([out]) }
        XCTAssertEqual(out.name, "photo-gps-rotated.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.url.path), "the HEIC copy is replaced")
        let (type, props) = try properties(out)
        XCTAssertEqual(type, UTType.jpeg.identifier)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        // 4032 × 3024 turned a quarter: 1500 × 2000, upright, with no orientation left to apply.
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1500)
        XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 2000)
        XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        let onDisk = try FileManager.default.attributesOfItem(atPath: out.url.path)[.size] as? NSNumber
        XCTAssertEqual(onDisk?.int64Value, out.size)
    }

    func testASmallJPEGKeepsItsPixelsAndLosesItsLocation() throws {
        let heic = try fixture("photo-gps-rotated", "heic")
        // Make a small upright JPEG with a location from the fixture.
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(heic.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 600,
        ] as CFDictionary))
        FileStaging.discard([heic])
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 40.4168, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 3.7038, kCGImagePropertyGPSLongitudeRef: "W"]
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let jpeg = try FileStaging.stage(data: data as Data, as: "small.jpg")
        XCTAssertNotNil(try properties(jpeg).props[kCGImagePropertyGPSDictionary])
        let out = ImagePrep.prepare(jpeg, original: false)
        defer { FileStaging.discard([out]) }
        let (type, props) = try properties(out)
        XCTAssertEqual(type, UTType.jpeg.identifier)
        XCTAssertEqual(out.name, "small.jpg")
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 600)
    }

    func testSendOriginalSendsTheBytesUntouched() throws {
        let heic = try fixture("photo-gps-rotated", "heic")
        defer { FileStaging.discard([heic]) }
        let before = try Data(contentsOf: heic.url)
        let out = ImagePrep.prepare(heic, original: true)
        XCTAssertEqual(out, heic)
        XCTAssertEqual(try Data(contentsOf: out.url), before)
    }
}
