import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a picked, pasted or dropped image into what is sent: HEIC, HEIF and every other still
/// format become JPEG (PNG when the image is a PNG or has transparency), a photo larger than
/// `maxLongEdge` is scaled down, and location and other metadata are left out. Everything goes
/// through ImageIO thumbnails, never a full decode into a `UIImage`, and the EXIF orientation is
/// applied to the pixels. "Send Original" skips all of it.
///
/// It fails closed. A copy is checked for location after it is made; an image that can't be
/// stripped is drawn again, and one that can't be drawn either comes back as `locationKept`, so
/// the user is asked before it goes as it is. Videos and other files that aren't still images go
/// as they are, as the attach menu says.
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
        /// Send the bytes as they are: "Send Original", or not a still image (a video, a document,
        /// a moving GIF).
        case keep
        /// Same pixels and format, without location: a small, upright JPEG or PNG.
        case stripLocation
        /// Draw it again at most `maxEdge` pixels on its long side, in `format`, oriented.
        case render(Format, maxEdge: Int)
    }

    /// What became of a file.
    enum Result: Equatable {
        /// Ready to send: prepared, or not an image, or an original the user asked for.
        case ready(StagedFile)
        /// An image whose location couldn't be removed. It goes only if the user says so.
        case locationKept(StagedFile)

        var file: StagedFile {
            switch self { case .ready(let f), .locationKept(let f): return f }
        }
    }

    /// What to do with an image of `type`, `width` × `height` pixels, with this EXIF orientation,
    /// `frames` images in its file, and transparency or not.
    static func plan(type: UTType?, width: Int, height: Int, orientation: Int = 1, frames: Int = 1,
                     alpha: Bool = false, original: Bool) -> Plan {
        guard !original, let type, type.conforms(to: .image) else { return .keep }
        // A moving GIF would lose its motion; a GIF holds no location (no EXIF, no IPTC).
        if type.conforms(to: .gif), frames > 1 { return .keep }
        guard width > 0, height > 0 else { return .render(alpha ? .png : .jpeg, maxEdge: maxLongEdge) }
        let longEdge = max(width, height)
        let edge = min(longEdge, maxLongEdge)
        if type.conforms(to: .png) {
            return longEdge > maxLongEdge || orientation != 1 || frames > 1 ? .render(.png, maxEdge: edge) : .stripLocation
        }
        if type.conforms(to: .jpeg) {
            return longEdge > maxLongEdge || orientation != 1 || frames > 1 ? .render(.jpeg, maxEdge: edge) : .stripLocation
        }
        // HEIC, HEIF (one image or several), TIFF, RAW, WebP, BMP, a still GIF and the rest.
        return .render(alpha ? .png : .jpeg, maxEdge: edge)
    }

    /// The size an image has after `plan`'s scaling: the long side at most `maxEdge`, the aspect kept.
    static func scaled(width: Int, height: Int, maxEdge: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > maxEdge, long > 0 else { return (width, height) }
        let k = Double(maxEdge) / Double(long)
        return (max(1, Int((Double(width) * k).rounded())), max(1, Int((Double(height) * k).rounded())))
    }

    /// The prepared copy of `file`, which replaces it, or `file` itself when it goes as it is.
    static func prepare(_ file: StagedFile, original: Bool) -> Result {
        let type = UTType(filenameExtension: (file.name as NSString).pathExtension)
        guard !original else { return .ready(file) }
        guard let src = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeID = CGImageSourceGetType(src) as String? else {
            // Not readable as an image. If its name says it is one, it can't be shown to be clean.
            return type?.conforms(to: .image) == true ? .locationKept(file) : .ready(file)
        }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let number = { (k: CFString) in (props[k] as? NSNumber)?.intValue }
        let plan = plan(type: UTType(typeID), width: number(kCGImagePropertyPixelWidth) ?? 0,
                        height: number(kCGImagePropertyPixelHeight) ?? 0,
                        orientation: number(kCGImagePropertyOrientation) ?? 1, frames: CGImageSourceGetCount(src),
                        alpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false, original: false)
        switch plan {
        case .keep:
            return .ready(file)
        case .stripLocation:
            if let out = stripped(src, type: typeID), isClean(out), let staged = try? FileStaging.stage(data: out, as: file.name) {
                FileStaging.discard([file])
                return .ready(staged)
            }
            // Couldn't be stripped in place: draw it again instead.
            let format: Format = UTType(typeID)?.conforms(to: .png) == true ? .png : .jpeg
            return render(file, src, index: index, format: format, maxEdge: maxLongEdge)
        case .render(let format, let maxEdge):
            return render(file, src, index: index, format: format, maxEdge: maxEdge)
        }
    }

    private static func render(_ file: StagedFile, _ src: CGImageSource, index: Int, format: Format, maxEdge: Int) -> Result {
        guard let out = rendered(src, index: index, format: format, maxEdge: maxEdge), isClean(out),
              let staged = try? FileStaging.stage(data: out, as: UploadName.withExtension(file.name, format.ext)) else {
            return .locationKept(file)
        }
        FileStaging.discard([file])
        return .ready(staged)
    }

    /// The same image without GPS and other metadata, without decoding it.
    private static func stripped(_ src: CGImageSource, type: String) -> Data? {
        guard CGImageSourceGetCount(src) == 1 else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) else { return nil }
        return data as Data
    }

    /// The image drawn again, oriented and scaled, with no metadata but its color profile. A JPEG
    /// over `targetBytes` is encoded again at lower qualities; a PNG is scaled down further.
    private static func rendered(_ src: CGImageSource, index: Int, format: Format, maxEdge: Int) -> Data? {
        var edge = maxEdge
        while true {
            let thumb: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, index, thumb as CFDictionary) else { return nil }
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

    /// Whether an encoded image is free of location: no GPS or IPTC block, and no XMP property that
    /// names a place or a position.
    static func isClean(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        for i in 0..<CGImageSourceGetCount(src) {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
            if props[kCGImagePropertyGPSDictionary] != nil || props[kCGImagePropertyIPTCDictionary] != nil { return false }
            if let meta = CGImageSourceCopyMetadataAtIndex(src, i, nil), hasLocationTag(meta) { return false }
        }
        return true
    }

    /// Words in the names of XMP properties that hold a place or a position (`exif:GPSLatitude`,
    /// `photoshop:City`, `Iptc4xmpCore:Location`, `Iptc4xmpExt:LocationShown`).
    static let locationWords = ["gps", "city", "country", "state", "location", "sublocation", "province"]

    private static func hasLocationTag(_ meta: CGImageMetadata) -> Bool {
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { _, tag in
            let name = (CGImageMetadataTagCopyName(tag) as String? ?? "").lowercased()
            if locationWords.contains(where: { name.contains($0) }) { found = true }
            return !found
        }
        return found
    }
}
