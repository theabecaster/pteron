#!/usr/bin/env swift
// Generates the launch art from Brand/launch-outline.svg and Brand/launch-art.png:
//
//   RexDuo/Resources/Assets.xcassets/LaunchMark.imageset/   the art at @2x and @3x
//   RexDuo/App/LaunchArt.swift                              its size, outline, zoom pivot and reach
//
// Run it by hand from anywhere after an art change, then run the app tests (LaunchArtTests pins
// the numbers, so a wrong regeneration fails):
//
//   swift -O Brand/make-launch-art.swift
//
// It stops, writing nothing, when the picture and the outline disagree (the gate below). It needs
// nothing installed beyond the Swift toolchain.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - What is decided here

/// The silhouette's area in square points. It is the area of the art this one replaced, so the
/// sticker is as large on screen as it was.
let targetArea = 12_255.0
/// Clear room around the silhouette in points, for the peel's blurred shadow.
let margin = 7.5
/// The zoom pivot's centre stays above this line (SVG units): in the head, not in the wing.
let headLimit = 520.0
/// Directions in the reach table.
let directions = 720
/// The gate: the picture's shape against the outline's, at @3x.
let minimumIoU = 0.995
let maximumEdgeOffset = 0.5
/// The launch screen's colour (the `LaunchBackground` colour set), for the contrast report.
let background = (r: 0x22 / 255.0, g: 0x27 / 255.0, b: 0x2e / 255.0)
let assetName = "LaunchMark"

// MARK: - Small tools

struct P { var x, y: Double }
struct Cubic { var a, b, c, d: P
    func at(_ t: Double) -> P {
        let u = 1 - t
        let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
        return P(x: w0 * a.x + w1 * b.x + w2 * c.x + w3 * d.x, y: w0 * a.y + w1 * b.y + w2 * c.y + w3 * d.y)
    }
}

func fail(_ why: String) -> Never {
    FileHandle.standardError.write(Data("make-launch-art: \(why)\n".utf8))
    exit(1)
}

func fixed(_ v: Double, _ places: Int) -> String { String(format: "%.\(places)f", v) }

let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let outlineURL = root.appendingPathComponent("Brand/launch-outline.svg")
let pictureURL = root.appendingPathComponent("Brand/launch-art.png")
let imagesetURL = root.appendingPathComponent("RexDuo/Resources/Assets.xcassets/\(assetName).imageset")
let swiftURL = root.appendingPathComponent("RexDuo/App/LaunchArt.swift")

// MARK: - 1. The outline

guard let svg = try? String(contentsOf: outlineURL, encoding: .utf8) else { fail("can't read \(outlineURL.path)") }

func attribute(_ name: String, after marker: String) -> String {
    guard let m = svg.range(of: marker), let open = svg.range(of: "\(name)=\"", range: m.upperBound..<svg.endIndex),
          let close = svg.range(of: "\"", range: open.upperBound..<svg.endIndex) else { fail("no \(name) after \(marker)") }
    return String(svg[open.upperBound..<close.lowerBound])
}

let viewBoxNumbers = attribute("viewBox", after: "<svg").split(separator: " ").compactMap { Double($0) }
guard viewBoxNumbers.count == 4 else { fail("the viewBox needs four numbers") }
let viewBox = (x: viewBoxNumbers[0], y: viewBoxNumbers[1], w: viewBoxNumbers[2], h: viewBoxNumbers[3])

/// The path's numbers as written, so the generated file repeats the SVG's digits.
var written: [[String]] = []
var cubics: [Cubic] = []
do {
    let d = attribute("d", after: "id=\"silhouette\"")
    var tokens: [String] = []
    var number = ""
    for ch in d {
        if ch.isLetter {
            if !number.isEmpty { tokens.append(number); number = "" }
            tokens.append(String(ch))
        } else if ch == " " || ch == "," {
            if !number.isEmpty { tokens.append(number); number = "" }
        } else {
            number.append(ch)
        }
    }
    if !number.isEmpty { tokens.append(number) }
    var i = 0
    func point() -> P {
        guard i + 1 < tokens.count, let x = Double(tokens[i]), let y = Double(tokens[i + 1]) else { fail("a number is missing in the path") }
        i += 2
        return P(x: x, y: y)
    }
    var start: P?, pen = P(x: 0, y: 0), closed = false
    while i < tokens.count {
        let command = tokens[i]
        i += 1
        switch command {
        case "M":
            guard start == nil else { fail("the silhouette must be one closed shape") }
            written.append([tokens[i], tokens[i + 1]])
            pen = point()
            start = pen
        case "C":
            // More triples may follow one C.
            repeat {
                guard start != nil, !closed else { fail("C outside the shape") }
                written.append(Array(tokens[i..<min(i + 6, tokens.count)]))
                let b = point(), c = point(), e = point()
                cubics.append(Cubic(a: pen, b: b, c: c, d: e))
                pen = e
            } while i < tokens.count && Double(tokens[i]) != nil
        case "Z":
            closed = true
        default:
            fail("the silhouette may use only absolute M, C and Z; found \(command)")
        }
    }
    guard let s = start, closed, !cubics.isEmpty else { fail("the silhouette isn't a closed shape") }
    guard abs(pen.x - s.x) < 1e-6, abs(pen.y - s.y) < 1e-6 else { fail("the last curve must end where the shape starts") }
}

/// The outline as short straight pieces: 64 a curve, well under a hundredth of a unit off.
let pieces = 64
var ring: [P] = []
for c in cubics { for k in 0..<pieces { ring.append(c.at(Double(k) / Double(pieces))) } }
let segments: [(P, P)] = ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) }

func inside(_ p: P) -> Bool {
    var odd = false
    for (a, b) in segments where (a.y > p.y) != (b.y > p.y) {
        if p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) { odd.toggle() }
    }
    return odd
}

/// Distance from a point to the outline.
func distance(_ p: P) -> Double {
    var best = Double.infinity
    for (a, b) in segments {
        let vx = b.x - a.x, vy = b.y - a.y, wx = p.x - a.x, wy = p.y - a.y
        let len = vx * vx + vy * vy
        let t = len > 0 ? min(max((wx * vx + wy * vy) / len, 0), 1) : 0
        let dx = wx - t * vx, dy = wy - t * vy
        best = min(best, dx * dx + dy * dy)
    }
    return best.squareRoot()
}

// MARK: - 2. Size and box

var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
for p in ring { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
var area = 0.0
for (a, b) in segments { area += a.x * b.y - b.x * a.y }
area = abs(area) / 2
/// Points per SVG unit at which the silhouette has the target area.
let unit = (targetArea / area).squareRoot()
// Whole points, rounded down, so the art sits on the pixel grid at @2x and @3x.
let width = ((maxX - minX) * unit + 2 * margin).rounded(.down)
let height = ((maxY - minY) * unit + 2 * margin).rounded(.down)
func tenth(_ v: Double) -> Double { (v * 10).rounded() / 10 }
let box = (x: tenth((minX + maxX) / 2 - width / unit / 2), y: tenth((minY + maxY) / 2 - height / unit / 2),
           w: tenth(width / unit), h: tenth(height / unit))

// MARK: - 3. The zoom pivot: the largest circle inside the head

func bestCircle() -> (centre: P, radius: Double) {
    // A coarse pass, then every half unit in the cells that can still hold the best: the distance
    // to the outline changes by at most the distance moved.
    let coarse = 8.0, fine = 0.5
    var cells: [(P, Double)] = []
    var best = 0.0
    var y = (minY / coarse).rounded(.down) * coarse
    while y < headLimit {
        var x = (minX / coarse).rounded(.down) * coarse
        while x <= maxX {
            let p = P(x: x, y: y)
            let d = inside(p) ? distance(p) : -distance(p)
            cells.append((p, d))
            best = max(best, d)
            x += coarse
        }
        y += coarse
    }
    let reach = coarse * 2.0.squareRoot() / 2
    var winner = (centre: P(x: 0, y: 0), radius: 0.0)
    let steps = Int(coarse / fine)
    for (cell, d) in cells where d + reach >= best {
        for iy in -steps / 2...steps / 2 {
            for ix in -steps / 2...steps / 2 {
                let p = P(x: cell.x + Double(ix) * fine, y: cell.y + Double(iy) * fine)
                guard p.y < headLimit, inside(p) else { continue }
                let r = distance(p)
                // Ties go to the first found, top to bottom, left to right: a repeatable choice.
                if r > winner.radius + 1e-9 { winner = (p, r) }
            }
        }
    }
    return winner
}
let circle = bestCircle()
let pivot = circle.centre
let pivotRadius = (circle.radius * 100).rounded(.down) / 100

// MARK: - 4. How far the shape reaches from the pivot, direction by direction

var extent: [Double] = []
for i in 0..<directions {
    let angle = 2 * Double.pi * Double(i) / Double(directions)
    let dx = cos(angle), dy = sin(angle)
    var first = Double.infinity
    for (a, b) in segments {
        // pivot + t * (dx, dy) == a + s * (b - a)
        let ex = b.x - a.x, ey = b.y - a.y
        let det = ex * dy - ey * dx
        guard abs(det) > 1e-12 else { continue }
        let t = (ex * (a.y - pivot.y) - ey * (a.x - pivot.x)) / det
        let s = (dx * (a.y - pivot.y) - dy * (a.x - pivot.x)) / det
        if t > 0, s >= 0, s <= 1 { first = min(first, t) }
    }
    guard first.isFinite else { fail("the pivot isn't inside the shape") }
    extent.append((first * 100).rounded(.down) / 100)
}

// MARK: - 5. The pictures

guard let source = CGImageSourceCreateWithURL(pictureURL as CFURL, nil),
      let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("can't read \(pictureURL.path)") }
guard picture.width == picture.height else { fail("the picture must be square, over the outline's viewBox") }
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// A premultiplied RGBA bitmap of `w` x `h` pixels with the box mapped onto it, y down.
func bitmap(_ w: Int, _ h: Int, draw: (CGContext, _ perUnitX: Double, _ perUnitY: Double) -> Void) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no bitmap") }
        // Core Graphics counts rows from the bottom; turn it over, so y goes down as in the SVG.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx, Double(w) / box.w, Double(h) / box.h)
    }
    return bytes
}

func render(scale: Int) -> (bytes: [UInt8], w: Int, h: Int) {
    let w = Int(width) * scale, h = Int(height) * scale
    let bytes = bitmap(w, h) { ctx, kx, ky in
        ctx.interpolationQuality = .high
        // Where the picture's square lies in the box. Outside it the bitmap stays clear.
        let rect = CGRect(x: (viewBox.x - box.x) * kx, y: (viewBox.y - box.y) * ky, width: viewBox.w * kx, height: viewBox.h * ky)
        // An image draws upright only in an unturned context: turn back around its own rect.
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(picture, in: rect)
    }
    return (bytes, w, h)
}

func outlineMask(scale: Int) -> [UInt8] {
    let w = Int(width) * scale, h = Int(height) * scale
    let bytes = bitmap(w, h) { ctx, kx, ky in
        let path = CGMutablePath()
        func q(_ p: P) -> CGPoint { CGPoint(x: (p.x - box.x) * kx, y: (p.y - box.y) * ky) }
        path.move(to: q(cubics[0].a))
        for c in cubics { path.addCurve(to: q(c.d), control1: q(c.b), control2: q(c.c)) }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
    }
    return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
}

// MARK: - 6. The gate: the picture's shape is the outline's

let three = render(scale: 3)
let two = render(scale: 2)
let shape = outlineMask(scale: 3)
var both = 0, either = 0, worstOffset = 0.0
do {
    let w = three.w, h = three.h
    let kx = Double(w) / box.w, ky = Double(h) / box.h
    for y in 0..<h {
        for x in 0..<w {
            let inPicture = three.bytes[(y * w + x) * 4 + 3] >= 128, inShape = shape[y * w + x] >= 128
            if inPicture && inShape { both += 1 }
            if inPicture || inShape { either += 1 }
            if inPicture != inShape {
                // A pixel the two disagree on lies between their edges: its centre's distance to
                // the outline is how far apart the edges are there, in pixels.
                let p = P(x: box.x + (Double(x) + 0.5) / kx, y: box.y + (Double(y) + 0.5) / ky)
                worstOffset = max(worstOffset, distance(p) * kx)
            }
        }
    }
}
let iou = Double(both) / Double(max(either, 1))

/// WCAG contrast of the art just inside its edge against the launch screen's colour.
func contrasts() -> [Double] {
    func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) }
    let back = luminance(background.r, background.g, background.b)
    let w = three.w, h = three.h
    let kx = Double(w) / box.w, ky = Double(h) / box.h
    var out: [Double] = []
    for i in stride(from: 0, to: ring.count, by: 4) {
        let a = ring[i], b = ring[(i + 1) % ring.count]
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 0 else { continue }
        // Two pixels in from the edge, on whichever side is inside.
        var nx = -(b.y - a.y) / len * 2 / kx, ny = (b.x - a.x) / len * 2 / ky
        if !inside(P(x: a.x + nx, y: a.y + ny)) { nx = -nx; ny = -ny }
        let x = Int((a.x + nx - box.x) * kx), y = Int((a.y + ny - box.y) * ky)
        guard x >= 0, y >= 0, x < w, y < h else { continue }
        let o = (y * w + x) * 4
        let alpha = Double(three.bytes[o + 3]) / 255
        guard alpha > 0.98 else { continue }
        let l = luminance(Double(three.bytes[o]) / 255 / alpha, Double(three.bytes[o + 1]) / 255 / alpha, Double(three.bytes[o + 2]) / 255 / alpha)
        out.append((max(l, back) + 0.05) / (min(l, back) + 0.05))
    }
    return out.sorted()
}
let edge = contrasts()

print("""
silhouette  \(fixed(maxX - minX, 1)) x \(fixed(maxY - minY, 1)) units, x \(fixed(minX, 1))-\(fixed(maxX, 1)), y \(fixed(minY, 1))-\(fixed(maxY, 1))
scale       \(fixed(unit, 5)) pt a unit, area \(fixed(area * unit * unit, 0)) pt2
art         \(Int(width)) x \(Int(height)) pt, box (\(box.x), \(box.y), \(box.w), \(box.h))
margins     \(fixed((minX - box.x) * unit, 2)) left, \(fixed((box.x + box.w - maxX) * unit, 2)) right, \(fixed((minY - box.y) * unit, 2)) top, \(fixed((box.y + box.h - maxY) * unit, 2)) bottom (pt)
pivot       (\(pivot.x), \(pivot.y)) r \(pivotRadius) units = \(fixed(pivotRadius * unit, 1)) pt
reach       \(fixed(extent.min() ?? 0, 2)) to \(fixed(extent.max() ?? 0, 2)) units over \(directions) directions
gate        IoU \(fixed(iou, 5)) (at least \(minimumIoU)), edge offset \(fixed(worstOffset, 3)) px (at most \(maximumEdgeOffset))
contrast    edge against the launch screen: minimum \(fixed(edge.first ?? 0, 2)):1, median \(fixed(edge.isEmpty ? 0 : edge[edge.count / 2], 2)):1
""")
if let least = edge.first, least < 3 { print("warning: part of the edge is under 3:1 against the launch screen") }
guard iou >= minimumIoU, worstOffset <= maximumEdgeOffset else {
    fail("the picture and the outline disagree; nothing written")
}

// MARK: - 7. Write

func writePNG(_ image: (bytes: [UInt8], w: Int, h: Int), to url: URL) {
    var bytes = image.bytes
    let made: CGImage? = bytes.withUnsafeMutableBytes { buf in
        CGContext(data: buf.baseAddress, width: image.w, height: image.h, bitsPerComponent: 8, bytesPerRow: image.w * 4,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    guard let made, let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("can't write \(url.path)")
    }
    CGImageDestinationAddImage(dest, made, nil)
    guard CGImageDestinationFinalize(dest) else { fail("can't write \(url.path)") }
}

try? FileManager.default.createDirectory(at: imagesetURL, withIntermediateDirectories: true)
writePNG(two, to: imagesetURL.appendingPathComponent("\(assetName)@2x.png"))
writePNG(three, to: imagesetURL.appendingPathComponent("\(assetName)@3x.png"))
let contents = """
{
  "images" : [
    { "idiom" : "universal", "scale" : "1x" },
    { "filename" : "\(assetName)@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "\(assetName)@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
do { try contents.write(to: imagesetURL.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8) } catch { fail("\(error)") }

var path = "        b.move(to: p(\(written[0][0]), \(written[0][1])))\n"
for c in written.dropFirst() {
    path += "        b.addCurve(to: p(\(c[4]), \(c[5])), control1: p(\(c[0]), \(c[1])), control2: p(\(c[2]), \(c[3])))\n"
}
var table = ""
for row in stride(from: 0, to: extent.count, by: 10) {
    table += "        " + extent[row..<min(row + 10, extent.count)].map { fixed($0, 2) }.joined(separator: ", ") + ",\n"
}
let code = """
// Generated by Brand/make-launch-art.swift from Brand/launch-outline.svg and Brand/launch-art.png.
// Don't edit: change the art or the script and run it again.

import CoreGraphics

/// The launch art: the picture on the static launch screen, which the splash peels off, and the
/// shape of the hole it leaves. Lengths marked "SVG units" are in the outline file's coordinates;
/// `point(_:_:)` turns them into points from the art's top-left corner.
enum LaunchArt {
    /// The image in the asset catalog, also named as the launch screen's image in Info.plist.
    static let assetName = "\(assetName)"
    /// The image's size in points.
    static let size = CGSize(width: \(Int(width)), height: \(Int(height)))
    /// What the image shows of the outline file (SVG units), centred on the silhouette.
    static let box = CGRect(x: \(box.x), y: \(box.y), width: \(box.w), height: \(box.h))
    /// Centre and radius of the largest circle inside the head (SVG units). The hole grows around
    /// the centre.
    static let pivot = CGPoint(x: \(pivot.x), y: \(pivot.y))
    static let pivotRadius: CGFloat = \(fixed(pivotRadius, 2))
    /// How far the silhouette reaches from the pivot before its edge is first met (SVG units), in
    /// `extent.count` evenly spaced directions: entry `i` looks along the angle `2π i / count`,
    /// from the x axis toward the y axis, which points down.
    static let extent: [CGFloat] = [
\(table)    ]

    /// Points per SVG unit.
    static let pointsPerUnit = size.width / box.width

    /// A place in the outline file as a point of the art (origin at its top-left corner).
    static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: (x - box.minX) * size.width / box.width, y: (y - box.minY) * size.height / box.height)
    }

    /// The silhouette in points (origin at the art's top-left corner): the body alone, since the
    /// eye and the mouth lie inside it. Made and read on the main thread, which hands the
    /// finished path on where another thread needs it.
    @MainActor static let silhouette: CGPath = {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { point(x, y) }
        let b = CGMutablePath()
\(path)        b.closeSubpath()
        return b
    }()
}

"""
do { try code.write(to: swiftURL, atomically: true, encoding: .utf8) } catch { fail("\(error)") }
print("wrote \(imagesetURL.path) and \(swiftURL.path)")
