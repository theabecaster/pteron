import Foundation
import GlanceModel
import GlanceUI
import SwiftUI
import Testing
import WidgetKit
@testable import RexDuo

/// Draws the widgets' views (compiled into the tests from `RexDuoWidgets/Views`) in every size,
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
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appendingPathComponent("RexDuoWidgets.appex")) } ?? .main
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

    private func save(_ view: some View, _ name: String) throws -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
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
                    colors.canvas.overlay { GlanceEdge(digest: d, style: style).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)) }
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
        let a = digest(scenario).accessory(private: locked)
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
            for scenario in ["several", "one", "working", "quiet", "stale", "old", "none"] {
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
            _ = try save(sheet(cells, columns: columns), "sheet-\(name)-modes")
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
        let cg = try #require(image.cgImage)
        let data = try #require(cg.dataProvider?.data as Data?)
        #expect(Set(data.prefix(400_000).chunked(4)).count > 8)
    }
}

private extension Data {
    func chunked(_ n: Int) -> [[UInt8]] {
        stride(from: 0, to: count - n + 1, by: n * 97).map { Array(self[$0..<$0 + n]) }
    }
}
