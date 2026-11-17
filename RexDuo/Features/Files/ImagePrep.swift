import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a picked photo into what is sent: HEIC and HEIF become JPEG, PNG stays PNG (screenshots),
/// a photo larger than `maxLongEdge` is scaled down, and location and other metadata are left out.
/// Everything goes through ImageIO thumbnails, never a full decode into a `UIImage`, and the EXIF
/// orientation is applied to the pixels. "Send Original" skips all of it.
///
/// `plan` is pure and tested; `prepare` runs it, off the main thread.
enum ImagePrep {
    static let maxLongEdge = 2000
    /// About the most a photo should weigh once prepared.
    static let targetBytes = 5_000_000
    static let jpegQuality = 0.85
    /// Lower qualities tried, in turn, for a JPEG still over `targetBytes`.
    static let fallbackQualities = [0.7, 0.55]

    enum Format: Equatable {
        case jpeg, png

        var type: UTType { self == .jpeg ? .jpeg : .png }
        var ext: String { self == .jpeg ? "jpg" : "png" }
    }

    enum Plan: Equatable {
        /// Send the bytes as they are: not a still image ImageIO writes, or "Send Original".
        case keep
        /// Same pixels and format, without location: a JPEG or PNG that is small enough.
        case stripLocation
        /// Draw it again at most `maxEdge` pixels on its long side, in `format`, oriented.
        case render(Format, maxEdge: Int)
    }

    /// What to do with an image of `type`, `width` × `height` pixels, with this EXIF orientation.
    static func plan(type: UTType?, width: Int, height: Int, orientation: Int = 1, original: Bool) -> Plan {
        guard !original, let type, width > 0, height > 0 else { return .keep }
        let format: Format
        if type.conforms(to: .heic) || type.conforms(to: .heif) {
            format = .jpeg
        } else if type.conforms(to: .jpeg) {
            format = .jpeg
        } else if type.conforms(to: .png) {
            format = .png
        } else {
            // GIF (may move), WebP, RAW, a document: as they are.
            return .keep
        }
        let longEdge = max(width, height)
        let converts = !(type.conforms(to: .jpeg) || type.conforms(to: .png))
        if converts || longEdge > maxLongEdge || orientation != 1 {
            return .render(format, maxEdge: min(longEdge, maxLongEdge))
        }
        return .stripLocation
    }

    /// The size an image has after `plan`'s scaling: the long side at most `maxEdge`, the aspect kept.
    static func scaled(width: Int, height: Int, maxEdge: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > maxEdge, long > 0 else { return (width, height) }
        let k = Double(maxEdge) / Double(long)
        return (max(1, Int((Double(width) * k).rounded())), max(1, Int((Double(height) * k).rounded())))
    }

    /// The prepared copy of `file`, which replaces it; `file` itself when it is sent as it is or
    /// can't be read as an image.
    static func prepare(_ file: StagedFile, original: Bool) -> StagedFile {
        guard let src = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeID = CGImageSourceGetType(src) as String?,
              CGImageSourceGetCount(src) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return file }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let plan = plan(type: UTType(typeID), width: width, height: height, orientation: orientation, original: original)
        let out: Data?
        var name = file.name
        switch plan {
        case .keep:
            return file
        case .stripLocation:
            out = stripped(src, type: typeID)
        case .render(let format, let maxEdge):
            out = rendered(src, format: format, maxEdge: maxEdge)
            name = UploadName.withExtension(file.name, format.ext)
        }
        guard let out, let staged = try? FileStaging.stage(data: out, as: name) else { return file }
        FileStaging.discard([file])
        return staged
    }

    /// The same image without GPS and other metadata, without decoding it.
    private static func stripped(_ src: CGImageSource, type: String) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) else { return nil }
        return data as Data
    }

    /// The image drawn again, oriented and scaled, with no metadata but its color profile. A JPEG
    /// over `targetBytes` is encoded again at lower qualities; a PNG is scaled down further.
    private static func rendered(_ src: CGImageSource, format: Format, maxEdge: Int) -> Data? {
        var edge = maxEdge
        while true {
            let thumb: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary) else { return nil }
            if format == .jpeg {
                var best: Data?
                for q in [jpegQuality] + fallbackQualities {
                    best = encode(image, format: format, quality: q)
                    if let b = best, b.count <= targetBytes { return b }
                }
                return best
            }
            guard let png = encode(image, format: format, quality: 1) else { return nil }
            if png.count <= targetBytes || edge <= 800 { return png }
            edge = edge * 3 / 4
        }
    }

    private static func encode(_ image: CGImage, format: Format, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
