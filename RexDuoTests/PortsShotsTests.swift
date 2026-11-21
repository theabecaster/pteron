import RexKit
import SwiftUI
import Testing
import UIKit
@testable import RexDuo

/// Draws a computer's ports list (`PortsListFrame`, `PortRowFace`, `PortsSheetFrame`: the views
/// the app shows) in each state a row can be in, Light and Dark, at an iPhone's width and the
/// folded Duo's, and checks each drew. No server and no Beacon: the rows are given their state.
/// The pictures go to the test host's temporary folder, under `ports-shots`, to be looked at:
/// `xcrun simctl get_app_container <sim> dev.abrahamgonzalez.rexduo data` + `/tmp/ports-shots`.
///
/// A popover's own frame and a context menu's are the system's and can't be drawn from a test:
/// the list stands on a card of the popover's size and color, and the menu's items
/// (`PortRowMenu`, the very view the row's menu holds) are listed beside their row.
@MainActor
@Suite struct PortsShotsTests {
    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ports-shots", isDirectory: true)
    private static let phone = CGSize(width: 402, height: 874)
    private static let duoFolded = CGSize(width: 382, height: 780)

    private static func theme(dark: Bool) -> TermTheme {
        ThemeStore.theme(dark ? Prefs.defaultDarkTheme : Prefs.defaultLightTheme)
    }

    private func row(_ port: Int, _ program: String, folder: String, pid: Int) -> PortRow {
        PortRow(sessionID: "session:1", blockID: "block:\(port)",
                entry: PortEntry(port: port, dialHost: "127.0.0.1", process: program, pid: pid, program: program, folder: "/home/alex/\(folder)"))
    }

    private func command(_ text: String) -> RestartCommand {
        RestartCommand(text: text, shellPID: 60, leaderPID: 70)
    }

    private static let long = "node ./node_modules/.bin/vite dev --host 127.0.0.1 --port 5173 --strictPort --open /dashboard/settings --mode development "
        + "--config ./config/vite.local.config.ts --logLevel info --clearScreen false --cors --force"

    /// Every state in one list, as the popover would hold them.
    private func rows(_ theme: TermTheme, only: Set<String>? = nil, longCommand: Bool = false) -> some View {
        let all = PortRowFace.Offers(browse: true, restart: true, stop: true)
        let states: [(String, PortRow, PortActions.Note?, PortRowFace.Offers)] = [
            ("plain", row(3000, "next", folder: "anchor", pid: 7), nil, all),
            ("confirm", row(5173, "vite", folder: "web", pid: 8), .confirm(command(longCommand ? Self.long : "npm run dev")), PortRowFace.Offers(browse: true)),
            ("restarting", row(8000, "python3", folder: "site", pid: 9), .restarting, PortRowFace.Offers(browse: true)),
            ("failed", row(4000, "node", folder: "api", pid: 10), .restartFailed, PortRowFace.Offers(browse: true)),
            ("still", row(6006, "storybook", folder: "ui", pid: 11), .stillRunning, all),
            ("stopping", row(8080, "bun", folder: "edge", pid: 12), .stopping, PortRowFace.Offers(browse: true, restart: false, stop: false)),
            ("browser", row(4321, "astro", folder: "docs", pid: 13), .inBrowser, all),
        ]
        return ForEach(states.filter { only?.contains($0.0) ?? true }, id: \.0) { s in
            PortRowFace(row: s.1, note: s.2, offers: s.3, acts: PortRowFace.Acts(), dim: false, theme: theme)
        }
    }

    /// The list on a card of the popover's size, over the sidebar's color.
    private func popover(_ theme: TermTheme, only: Set<String>? = nil, longCommand: Bool = false, menu: Bool = false,
                         top: CGFloat = 70) -> some View {
        VStack(spacing: 16) {
            PortsListFrame(title: "Ports", isEmpty: false, theme: theme) { rows(theme, only: only, longCommand: longCommand) }
                .frame(width: 300)
                .fixedSize(horizontal: false, vertical: true)
                .background(theme.chrome.sidebar)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.fg.opacity(0.12)))
            if menu {
                // The row's menu, item by item: what a long press on the row lists.
                VStack(alignment: .leading, spacing: 0) {
                    PortRowMenu(offers: PortRowFace.Offers(browse: true, restart: true, stop: true), acts: PortRowFace.Acts())
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.plain)
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                .frame(width: 250)
                .background(theme.chrome.sidebar)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.fg.opacity(0.12)))
                .foregroundStyle(theme.fg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, top)
        .background(theme.chrome.canvas)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    /// Draws `view` in a window of `size` and saves it. Returns how many different colors a
    /// coarse sample of it holds: a view that drew nothing has one.
    private func shoot(_ view: some View, _ name: String, size: CGSize, dark: Bool,
                       category: UIContentSizeCategory = .large) async throws -> Int {
        let window = Hosted.window(view, size: size, category: category)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        defer { window.isHidden = true }
        try? await Task.sleep(for: .milliseconds(400))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: Self.folder.appendingPathComponent(name + ".png"))
        let cg = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try #require(CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: cg.height, by: 7) {
            for x in stride(from: 0, to: cg.width, by: 7) {
                let i = (y * cg.width + x) * 4
                colors.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
            }
        }
        return colors.count
    }

    @Test(arguments: [false, true])
    func theListInEveryState(dark: Bool) async throws {
        let theme = Self.theme(dark: dark), tone = dark ? "dark" : "light"
        #expect(try await shoot(popover(theme), "popover-states-17pro-\(tone)", size: Self.phone, dark: dark) > 8)
        #expect(try await shoot(popover(theme), "popover-states-duo-folded-\(tone)", size: Self.duoFolded, dark: dark) > 8)
        #expect(try await shoot(popover(theme, only: ["plain"], menu: true), "row-menu-17pro-\(tone)", size: Self.phone, dark: dark) > 8)
        #expect(try await shoot(popover(theme, only: ["plain", "confirm"], longCommand: true), "restart-long-command-17pro-\(tone)",
                                size: Self.phone, dark: dark) > 8)
        // The largest text size: the question, then the rows that say how a Restart went.
        let largest = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        for (name, size) in [("17pro", Self.phone), ("duo-folded", Self.duoFolded)] {
            #expect(try await shoot(popover(theme, only: ["confirm"], top: 20), "restart-question-largest-type-\(name)-\(tone)",
                                    size: size, dark: dark, category: largest) > 8)
            #expect(try await shoot(popover(theme, only: ["restarting", "failed", "still"], top: 20), "restart-states-largest-type-\(name)-\(tone)",
                                    size: size, dark: dark, category: largest) > 8)
        }
    }

    @Test(arguments: [false, true])
    func theSheetOfTabMode(dark: Bool) async throws {
        let theme = Self.theme(dark: dark)
        let sheet = PortsSheetFrame(theme: theme, done: {}) {
            PortsListFrame(title: "Desk", isEmpty: false, theme: theme) { rows(theme) }
        }
        #expect(try await shoot(sheet, "tab-mode-sheet-17pro-\(dark ? "dark" : "light")", size: Self.phone, dark: dark) > 8)
    }

    @Test func aListWithNoPortSaysSo() async throws {
        let theme = Self.theme(dark: true)
        let empty = PortsListFrame(title: "Ports", isEmpty: true, theme: theme) { EmptyView() }
            .background(theme.chrome.sidebar)
        #expect(try await shoot(empty, "popover-empty-dark", size: CGSize(width: 300, height: 120), dark: true) > 2)
    }
}
