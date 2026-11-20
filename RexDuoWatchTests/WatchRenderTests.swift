import Foundation
import GlanceModel
import GlanceUI
import SwiftUI
import Testing
import WidgetKit
@testable import RexDuoWatch

/// Draws the watch app's screens and every complication family in every state, on the watch
/// simulator, and checks each drew something. The pictures go to the test host's temporary
/// folder, under `watch-renders`, to be looked at:
/// `xcrun simctl get_app_container <watch sim> dev.abrahamgonzalez.rexduo.watchkitapp data` + `/tmp/watch-renders`.
///
/// A `List` and a navigation bar don't draw outside a running app, so the list is drawn here
/// as its rows under each other on the watch's black; the app itself is looked at with
/// `-glanceDemo <scenario>`. A corner's curved words are the system's to draw: the picture
/// shows them straight, beside the corner.
@MainActor
@Suite struct WatchRenderTests {
    private static let now = Date()
    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("watch-renders", isDirectory: true)
    /// The 46 mm watch's screen, in points.
    private static let width: CGFloat = 208

    /// The watch widgets' extension, where the mark is.
    private static var symbols: Bundle {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appendingPathComponent("RexDuoWatchWidgets.appex")) } ?? .main
    }

    private func reading(_ scenario: String) -> GlanceReading {
        switch scenario {
        case "none": .missing
        case "newer": GlanceReading(GlanceDemo.newerFile)
        default: GlanceDemo.snapshot(scenario, now: Self.now).map(GlanceReading.snapshot) ?? .missing
        }
    }

    @discardableResult
    private func save(_ view: some View, _ name: String) throws -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.uiImage, "\(name)")
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: Self.folder.appendingPathComponent(name + ".png"))
        return image
    }

    // MARK: The app's screens

    /// The first screen, with every row it lists under each other.
    private func list(_ scenario: String) -> some View {
        let screen = WatchScreen(reading(scenario), now: Self.now)
        let style = WatchStyle(screen.palette)
        return Group {
            switch screen.kind {
            case .message(let text):
                WatchMessageView(text: text, style: style).frame(height: 200)
            case .agents:
                VStack(alignment: .leading, spacing: 4) {
                    WatchHeaderView(screen: screen, style: style).padding(.horizontal, 4)
                    ForEach(screen.rows) { row in
                        WatchRowView(row: row, style: style)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(style.platter))
                    }
                    if screen.more > 0 {
                        Text("+\(screen.more) more").font(WatchStyle.place).foregroundStyle(style.secondary).padding(.horizontal, 8)
                    }
                    ForEach(screen.machines) { machine in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(machine.name).font(WatchStyle.words).foregroundStyle(style.fg)
                            Text(machine.words).font(WatchStyle.place).foregroundStyle(style.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(style.platter))
                        .opacity(machine.dimmed ? WatchStyle.dim : 1)
                    }
                }
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func detail(_ scenario: String, wristDown: Bool, redacted: Bool = false) -> some View {
        let screen = WatchScreen(reading(scenario), now: Self.now)
        let style = WatchStyle(screen.palette)
        return Group {
            if let row = screen.rows.first {
                WatchDetailBody(row: row, style: style, wristDown: wristDown)
            } else {
                Text("no agent waits in \(scenario)")
            }
        }
        .redacted(reason: redacted ? .privacy : [])
        .padding(6)
        .frame(width: Self.width)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func sheet(_ cells: [(String, AnyView)], columns: Int) -> some View {
        let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        VStack(alignment: .leading, spacing: 3) {
                            cell.1
                            Text(cell.0).font(.system(size: 9, design: .monospaced)).foregroundStyle(.gray)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.35))
    }

    @Test func theListDrawsEveryState() throws {
        var cells: [(String, AnyView)] = []
        for scenario in GlanceDemo.scenarios {
            let view = list(scenario)
            let image = try save(view, "list-\(scenario)")
            #expect(image.size.width >= Self.width && image.size.height > 60, "\(scenario)")
            cells.append((scenario, AnyView(view)))
        }
        try save(sheet(cells, columns: 5), "sheet-list")
    }

    @Test func theDetailScreenDrawsWristUpWristDownAndRedacted() throws {
        var cells: [(String, AnyView)] = []
        for scenario in ["one", "several", "long", "stale", "old", "machines", "light-in-dark"] {
            for (wristDown, word) in [(false, "up"), (true, "down")] {
                let view = detail(scenario, wristDown: wristDown)
                try save(view, "detail-\(scenario)-wrist-\(word)")
                cells.append(("\(scenario) wrist \(word)", AnyView(view)))
            }
        }
        // What the system hides where it asks for privacy: the name, the message, the place, the machine.
        let hidden = detail("one", wristDown: false, redacted: true)
        try save(hidden, "detail-one-redacted")
        cells.append(("one redacted", AnyView(hidden)))
        let gone = WatchGoneView(style: WatchStyle(.standardDark)).frame(width: Self.width, height: 100).background(Color.black)
        try save(gone, "detail-gone")
        cells.append(("no longer waiting", AnyView(gone)))
        try save(sheet(cells, columns: 4), "sheet-detail")
    }

    // MARK: Complications and the Smart Stack

    private enum Family: String, CaseIterable { case circular, corner, rectangular, inline }
    private enum Face: String, CaseIterable { case fullColor, accented, vibrant }

    private func complication(_ scenario: String, _ family: Family, face: Face, locked: Bool) -> some View {
        let entry = GlanceEntry(GlanceTimeline.entries(reading(scenario), now: Self.now)[0])
        let a = entry.digest.accessory(private: locked)
        let accent = WatchAccent.color(a, palette: entry.palette, fullColor: face == .fullColor)
        let mode: WidgetRenderingMode = switch face {
        case .fullColor: .fullColor
        case .accented: .accented
        case .vibrant: .vibrant
        }
        return Group {
            switch family {
            case .circular:
                GlanceCircularView(accessory: a, accent: accent, symbols: Self.symbols)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(.white.opacity(0.14)))
            case .corner:
                HStack(spacing: 6) {
                    WatchCornerView(accessory: a, accent: accent, symbols: Self.symbols)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white.opacity(0.14)))
                    // The words the face curves along its edge.
                    Text(a.cornerLabel ?? "").font(.system(size: 11, weight: .semibold))
                }
                .frame(width: 120, alignment: .leading)
            case .rectangular:
                // The Smart Stack draws this family, on its own platter.
                GlanceRectangularView(accessory: a, accent: accent, symbols: Self.symbols)
                    .frame(width: 176, height: 62)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.12)))
            case .inline:
                GlanceInlineView(accessory: a).font(.system(size: 14, weight: .semibold)).frame(width: 190, height: 20)
            }
        }
        .foregroundStyle(face == .accented ? Color(red: 0.55, green: 0.8, blue: 1) : .white)
        .padding(6)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .environment(\.widgetRenderingMode, mode)
    }

    @Test func everyComplicationFamilyDrawsEveryStateOnEveryKindOfFaceOpenAndPrivate() throws {
        for family in Family.allCases {
            var cells: [(String, AnyView)] = []
            for scenario in GlanceDemo.scenarios {
                for face in Face.allCases {
                    for locked in [false, true] where !locked || face == .fullColor {
                        let view = complication(scenario, family, face: face, locked: locked)
                        let word = "\(face.rawValue)\(locked ? "-private" : "")"
                        let image = try save(view, "complication-\(family.rawValue)-\(scenario)-\(word)")
                        #expect(image.size.width > 20 && image.size.height > 20)
                        cells.append(("\(scenario) \(word)", AnyView(view)))
                    }
                }
            }
            try save(sheet(cells, columns: family == .circular ? 8 : 4), "sheet-complication-\(family.rawValue)")
        }
    }

    @Test func aPrivateComplicationCarriesNoNameOrPlace() {
        for scenario in GlanceDemo.scenarios {
            let a = GlanceDigest(reading(scenario), now: Self.now).accessory(private: true)
            #expect(a.detail == nil, "\(scenario)")
        }
    }

    @Test func theCountTakesTheWaitingColorOnlyInFullColorWhileSomeoneWaits() {
        func accent(_ scenario: String, fullColor: Bool) -> Color? {
            let d = GlanceDigest(reading(scenario), now: Self.now)
            return WatchAccent.color(d.accessory(private: false), palette: reading(scenario).snapshot?.palette ?? .standard, fullColor: fullColor)
        }
        #expect(accent("several", fullColor: true) == GlanceColors(.standardDark).blocked)
        #expect(accent("light-in-dark", fullColor: true) == GlanceColors(.standardDark).blocked)
        #expect(accent("several", fullColor: false) == nil)
        for quiet in ["quiet", "working", "old", "offline", "none"] { #expect(accent(quiet, fullColor: true) == nil, "\(quiet)") }
    }

    @Test func theCornersWords() {
        func label(_ scenario: String) -> String? { GlanceDigest(reading(scenario), now: Self.now).accessory(private: false).cornerLabel }
        #expect(label("one") == "needs you" && label("several") == "need you" && label("working") == "working")
        #expect(label("quiet") == nil && label("none") == nil)
    }

    @Test func onlyAnEntryWithAWaitCountsInTheSmartStack() {
        func score(_ scenario: String) -> Float {
            GlanceEntry(GlanceTimeline.entries(reading(scenario), now: Self.now)[0]).relevance?.score ?? -1
        }
        #expect(score("several") == 2 && score("one") == 1)
        for quiet in ["quiet", "working", "old", "offline", "none", "newer", "unpaired"] { #expect(score(quiet) == 0, "\(quiet)") }
    }

    /// A picture is not empty: a view that drew nothing is one flat color.
    @Test func aDrawnScreenIsNotBlank() throws {
        let image = try save(list("several"), "check-list-several")
        let cg = try #require(image.cgImage)
        let data = try #require(cg.dataProvider?.data as Data?)
        var seen = Set<[UInt8]>()
        var i = 0
        while i + 4 <= data.count, i < 400_000 { seen.insert(Array(data[i..<i + 4])); i += 4 * 97 }
        #expect(seen.count > 8)
    }
}
