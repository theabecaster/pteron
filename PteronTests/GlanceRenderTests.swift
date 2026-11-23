import Foundation
import GlanceModel
import GlanceUI
import SwiftUI
import Testing
import WidgetKit
@testable import Pteron

/// Draws the widgets' views (compiled into the tests from `PteronWidgets/Views`) in every size,
/// state, color scheme and rendering mode, and checks each drew something. The pictures go to
/// the test host's temporary folder, under `glance-renders`, to be looked at:
/// `xcrun simctl get_app_container <sim> dev.abrahamgonzalez.rexduo data` + `/tmp/glance-renders`.
@MainActor
@Suite struct GlanceRenderTests {
    /// The real time: the wait times in the pictures count from the system's clock.
    private static let now = Date()
    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glance-renders", isDirectory: true)

    /// The extension, where the custom symbols are.
    private static var symbols: Bundle {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appendingPathComponent("PteronWidgets.appex")) } ?? .main
    }

    private func digest(_ scenario: String) -> GlanceDigest {
        switch scenario {
        case "none": return .placeholder
        case "newer": return GlanceDigest(GlanceReading(GlanceDemo.newerFile), now: Self.now)
        default: return GlanceDigest(GlanceDemo.snapshot(scenario, now: Self.now).map(GlanceReading.snapshot) ?? .missing, now: Self.now)
        }
    }

    private func palette(_ scenario: String) -> GlanceSnapshot.Palette {
        GlanceDemo.snapshot(scenario, now: Self.now)?.palette ?? .standard
    }

    private func save(_ view: some View, _ name: String, scale: CGFloat = 3) throws -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try #require(renderer.uiImage, "\(name)")
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: Self.folder.appendingPathComponent(name + ".png"))
        return image
    }

    /// A Home Screen size as the system frames it on a 6.3" iPhone (measured on the simulator).
    private func home(_ scenario: String, _ size: GlanceHomeView.Size, system: ColorScheme, mode: WidgetRenderingMode = .fullColor,
                      locked: Bool = false) -> some View {
        let colors = GlanceColors.pick(palette(scenario), system: system)
        let style = GlanceStyle(colors: colors, mode: mode, symbols: Self.symbols)
        let d = digest(scenario)
        let frame: CGSize = switch size {
        case .small: CGSize(width: 164, height: 164)
        case .medium: CGSize(width: 350, height: 164)
        case .large: CGSize(width: 350, height: 365)
        }
        return GlanceHomeView(digest: d, size: size, style: style)
            .redacted(reason: locked ? .privacy : [])
            .padding(16)
            .frame(width: frame.width, height: frame.height)
            .background {
                if mode == .fullColor {
                    GlanceCanvas(digest: d, style: style).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                } else {
                    // Tinted and clear widgets sit on the system's glass.
                    Color(white: 0.16)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                if mode == .fullColor, let glow = d.glow {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(colors.state(glow).opacity(0.7), lineWidth: 1.5)
                }
            }
            .environment(\.colorScheme, mode == .fullColor ? colors.scheme : .dark)
            .environment(\.widgetRenderingMode, mode)
    }

    private enum Accessory: String, CaseIterable { case circular, rectangular, inline }

    /// A Lock Screen accessory over a wallpaper-like ground, as the vibrant mode draws it.
    private func accessory(_ scenario: String, _ kind: Accessory, locked: Bool) -> some View {
        accessory(digest(scenario), kind, locked: locked)
    }

    private func accessory(_ d: GlanceDigest, _ kind: Accessory, locked: Bool) -> some View {
        let a = d.accessory(private: locked)
        return Group {
            switch kind {
            case .circular:
                GlanceCircularView(accessory: a, symbols: Self.symbols)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(.white.opacity(0.18)))
            case .rectangular:
                GlanceRectangularView(accessory: a, symbols: Self.symbols).frame(width: 172, height: 72)
            case .inline:
                GlanceInlineView(accessory: a).font(.system(size: 17, weight: .semibold)).frame(width: 300, height: 26)
            }
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.36), Color(red: 0.45, green: 0.3, blue: 0.4)],
                                   startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
        .environment(\.widgetRenderingMode, .vibrant)
    }

    /// Several pictures under each other with their names, to look at one state across sizes.
    private func sheet(_ cells: [(String, AnyView)], columns: Int) -> some View {
        let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        VStack(alignment: .leading, spacing: 4) {
                            cell.1
                            Text(cell.0).font(.system(size: 10, design: .monospaced)).foregroundStyle(.gray)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(white: 0.5))
    }

    private static let scenarios = GlanceDemo.scenarios

    @Test func everyHomeSizeDrawsEveryStateInLightAndDark() throws {
        for (size, name, columns) in [(GlanceHomeView.Size.small, "small", 5), (.medium, "medium", 3), (.large, "large", 3)] {
            for (system, word) in [(ColorScheme.dark, "dark"), (.light, "light")] {
                var cells: [(String, AnyView)] = []
                for scenario in Self.scenarios {
                    let view = home(scenario, size, system: system)
                    let image = try save(view, "\(name)-\(scenario)-\(word)")
                    #expect(image.size.width > 100 && image.size.height > 100)
                    cells.append((scenario, AnyView(view)))
                }
                _ = try save(sheet(cells, columns: columns), "sheet-\(name)-\(word)")
            }
        }
    }

    @Test func tintedVibrantAndLockedDraw() throws {
        for (size, name, columns) in [(GlanceHomeView.Size.small, "small", 5), (.medium, "medium", 3), (.large, "large", 3)] {
            var cells: [(String, AnyView)] = []
            for scenario in ["several", "one", "working", "error", "quiet", "empty", "stale", "old", "unpaired", "none"] {
                for (mode, word) in [(WidgetRenderingMode.accented, "accented"), (.vibrant, "vibrant")] {
                    let view = home(scenario, size, system: .dark, mode: mode)
                    _ = try save(view, "\(name)-\(scenario)-\(word)")
                    cells.append(("\(scenario) \(word)", AnyView(view)))
                }
            }
            // The phone is locked: what is private is redacted, the counts stay.
            for scenario in ["several", "machines"] {
                for (system, word) in [(ColorScheme.dark, "dark"), (.light, "light")] {
                    let view = home(scenario, size, system: system, locked: true)
                    _ = try save(view, "\(name)-\(scenario)-\(word)-locked")
                    cells.append(("\(scenario) \(word) locked", AnyView(view)))
                }
            }
            _ = try save(sheet(cells, columns: columns), "sheet-\(name)-modes", scale: 2)
        }
    }

    @Test func everyAccessoryDrawsEveryStateOpenAndLocked() throws {
        for kind in Accessory.allCases {
            var cells: [(String, AnyView)] = []
            for scenario in Self.scenarios {
                for locked in [false, true] {
                    let view = accessory(scenario, kind, locked: locked)
                    let word = locked ? "locked" : "open"
                    _ = try save(view, "accessory-\(kind.rawValue)-\(scenario)-\(word)")
                    cells.append(("\(scenario) \(word)", AnyView(view)))
                }
            }
            _ = try save(sheet(cells, columns: kind == .circular ? 8 : kind == .rectangular ? 4 : 2), "sheet-accessory-\(kind.rawValue)")
        }
    }

    /// A picture is not empty: a view that drew nothing is one flat color.
    @Test func aDrawnWidgetIsNotBlank() throws {
        let image = try save(home("several", .medium, system: .dark), "check-several-medium")
        #expect(try colors(image) > 8)
        // Nor is a calm one: Glide and its line fill it.
        for scenario in ["quiet", "empty", "unpaired", "none"] {
            for size in [GlanceHomeView.Size.small, .medium, .large] {
                #expect(try colors(try save(home(scenario, size, system: .dark), "check-\(scenario)")) > 8, "\(scenario) \(size)")
            }
        }
    }

    private func colors(_ image: UIImage) throws -> Int {
        let cg = try #require(image.cgImage)
        let data = try #require(cg.dataProvider?.data as Data?)
        return Set(data.chunked(4)).count
    }

    // MARK: Hazards

    /// Tinted and clear Home Screens, and StandBy at night: the system colors the widget, so
    /// nothing may rely on a color, and no text is drawn under 60%.
    @Test func tintedAndVibrantTextStaysAtSixtyPercentOrMore() throws {
        let colors = GlanceColors.pick(.standard, system: .dark)
        let env = EnvironmentValues()
        for mode in [WidgetRenderingMode.accented, .vibrant] {
            let style = GlanceStyle(colors: colors, mode: mode, symbols: Self.symbols)
            for (name, color) in [("fg", style.fg), ("secondary", style.secondary), ("tertiary", style.tertiary)] {
                #expect(color.resolve(in: env).opacity >= 0.6, "\(name) \(mode)")
            }
            #expect(style.dim >= 0.6)
            for scenario in ["several", "working", "quiet", "empty", "unpaired", "none"] {
                for size in [GlanceHomeView.Size.small, .medium, .large] {
                    let image = try save(home(scenario, size, system: .dark, mode: mode), "check-\(scenario)-\(mode)")
                    #expect(try self.colors(image) > 4, "\(scenario) \(size) \(mode)")
                }
            }
        }
        // Full color too: the stale share is 60%, and the headline of an old snapshot is no warning.
        let full = GlanceStyle(colors: colors, mode: .fullColor, symbols: Self.symbols)
        #expect(full.dim == 0.6)
        #expect(full.headline(digest("old")) == full.fg && full.headline(digest("offline")) == full.secondary)
        #expect(full.headline(digest("several")) == colors.blocked && full.headline(digest("working")) == colors.working)
    }

    /// The Lock Screen accessories draw exactly what they drew before the tiles: the same
    /// pixels with and without `busy` in the file.
    @Test func theLockScreenAccessoriesIgnoreTheTiles() throws {
        for scenario in Self.scenarios {
            guard var bare = GlanceDemo.snapshot(scenario, now: Self.now) else { continue }
            for i in bare.machines.indices { bare.machines[i].busy = nil }
            let with = digest(scenario), without = GlanceDigest(bare, now: Self.now)
            for locked in [false, true] {
                #expect(with.accessory(private: locked) == without.accessory(private: locked), "\(scenario)")
                for kind in Accessory.allCases {
                    let a = try #require(ImageRenderer(content: accessory(with, kind, locked: locked)).uiImage?.pngData())
                    let b = try #require(ImageRenderer(content: accessory(without, kind, locked: locked)).uiImage?.pngData())
                    #expect(a == b, "\(scenario) \(kind) \(locked)")
                }
            }
        }
    }

    /// The longest names at the largest text the widget allows stay inside every size: they
    /// truncate or scale, never push the widget's content out.
    @Test func longNamesAtTheLargestTextStayInside() throws {
        var machines = try #require(GlanceDemo.snapshot("machines", now: Self.now))
        for i in machines.machines.indices { machines.machines[i].name = "A machine with a very long name indeed \(i)" }
        let cases: [(String, GlanceDigest)] = [("long", digest("long")), ("long-machines", GlanceDigest(machines, now: Self.now)),
                                               ("several", digest("several")), ("empty", digest("empty")), ("working", digest("working"))]
        let style = GlanceStyle(colors: GlanceColors.pick(.standard, system: .dark), mode: .fullColor, symbols: Self.symbols)
        for (name, d) in cases {
            for size in [GlanceHomeView.Size.small, .medium, .large] {
                let room: CGSize = switch size {
                case .small: CGSize(width: 132, height: 132)
                case .medium: CGSize(width: 318, height: 132)
                case .large: CGSize(width: 318, height: 333)
                }
                for type in [DynamicTypeSize.xxLarge, .accessibility5] {
                    let view = GlanceHomeView(digest: d, size: size, style: style).environment(\.dynamicTypeSize, type)
                    let fit = UIHostingController(rootView: view).sizeThatFits(in: room)
                    #expect(fit.width <= room.width + 0.5 && fit.height <= room.height + 0.5, "\(name) \(size) \(type): \(fit)")
                }
                // Past xxLarge nothing grows: the largest text draws as xxLarge does.
                func png(_ type: DynamicTypeSize) -> Data? {
                    let r = ImageRenderer(content: GlanceHomeView(digest: d, size: size, style: style)
                        .environment(\.dynamicTypeSize, type).frame(width: room.width, height: room.height))
                    return r.uiImage?.pngData()
                }
                #expect(png(.xxLarge) == png(.accessibility5), "\(name) \(size)")
                _ = try save(GlanceHomeView(digest: d, size: size, style: style).environment(\.dynamicTypeSize, .accessibility5)
                    .padding(16).frame(width: room.width + 32, height: room.height + 32)
                    .background(GlanceCanvas(digest: d, style: style)), "largest-\(name)-\(size)")
            }
        }
    }

    /// Motion only on a change, never with the screen dimmed or in StandBy at night, and a
    /// fade with Reduce Motion.
    @Test func motionIsShortAndStillWhereItShouldBe() {
        #expect(GlanceMotion(reduceMotion: false, luminanceReduced: false, mode: .fullColor) == .full)
        #expect(GlanceMotion(reduceMotion: false, luminanceReduced: false, mode: .accented) == .full)
        #expect(GlanceMotion(reduceMotion: true, luminanceReduced: false, mode: .fullColor) == .fade)
        #expect(GlanceMotion(reduceMotion: false, luminanceReduced: true, mode: .fullColor) == .still)
        #expect(GlanceMotion(reduceMotion: false, luminanceReduced: false, mode: .vibrant) == .still)
        #expect(GlanceMotion.still.animation == nil)
        #expect(GlanceMotion.full.animation != nil && GlanceMotion.fade.animation != nil)
        #expect(GlanceMotion.longest <= 0.4)
    }
}

private extension Data {
    func chunked(_ n: Int) -> [[UInt8]] {
        stride(from: 0, to: count - n + 1, by: n * 97).map { Array(self[$0..<$0 + n]) }
    }
}
