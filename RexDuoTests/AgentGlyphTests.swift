import Foundation
import GlanceUI
import RexKit
import SwiftUI
import Testing
import UIKit
@testable import RexDuo

/// The agents' marks (`AgentGlyph`): every one is in the app's bundle and the widgets', is a
/// symbol that sizes like the SF Symbols it replaced, and the rest fall back to their symbol.
/// The pictures go to the test host's temporary folder, under `agent-marks`, to be looked at.
@MainActor
@Suite struct AgentGlyphTests {
    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-marks", isDirectory: true)

    private static var widgets: Bundle? {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appendingPathComponent("RexDuoWidgets.appex")) }
    }

    @Test func everyMarkIsInTheAppAndTheWidgets() throws {
        let widgets = try #require(Self.widgets, "the widgets' extension is embedded in the app")
        for kind in AgentGlyph.marked {
            for (bundle, name) in [(Bundle.main, "app"), (widgets, "widgets")] {
                let image = UIImage(named: "agent.\(kind)", in: bundle, with: nil)
                #expect(image != nil, "agent.\(kind) in the \(name)")
                #expect(image?.isSymbolImage == true, "agent.\(kind) in the \(name) is a symbol")
            }
        }
    }

    @Test func everyKindHasAMarkOrKeepsItsSymbol() {
        // A mark only for a kind the app knows, and every kind but Amp (a wordmark only) has one.
        #expect(Set(AgentKind.allCases.map(\.rawValue)).isSuperset(of: AgentGlyph.marked))
        for kind in AgentKind.allCases {
            let name = AgentGlyph.name(agent: kind)
            if kind == .amp {
                #expect(name == kind.symbol)
            } else {
                #expect(name == "agent.\(kind.rawValue)")
            }
        }
        #expect(AgentGlyph.name(agent: nil) == "terminal")
        #expect(AgentGlyph.name(agent: nil, fallback: "cpu") == "cpu")
    }

    /// A mark at a font's size is about as tall and wide as the SF Symbols it replaced, so no
    /// row, ring or tile changes its layout.
    @Test func aMarkSizesLikeTheSymbols() throws {
        let config = UIImage.SymbolConfiguration(pointSize: 100, weight: .bold)
        let reference = try #require(UIImage(systemName: "cpu", withConfiguration: config)).size
        for kind in AgentGlyph.marked {
            let size = try #require(UIImage(named: "agent.\(kind)", in: .main, with: config)).size
            #expect(abs(size.height - reference.height) / reference.height < 0.2, "\(kind) height \(size.height) vs \(reference.height)")
            #expect(size.width < reference.width * 1.1 && size.width > reference.width * 0.6, "\(kind) width \(size.width)")
        }
    }

    // MARK: Pictures

    private static let kinds: [AgentKind?] = AgentKind.allCases + [nil]

    private func save(_ view: some View, _ name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try #require(renderer.uiImage, "\(name)")
        #expect(image.size.width > 100)
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: Self.folder.appendingPathComponent(name + ".png"))
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 9, design: .monospaced)).foregroundStyle(.gray)
    }

    /// Every kind: the SF Symbol it had, then its mark, at 12 and 34 pt next to text of that size.
    @Test func drawsEveryMarkBesideItsOldSymbol() throws {
        for (scheme, word) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let fg: Color = scheme == .light ? .black : .white
            let sheet = VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.kinds.enumerated()), id: \.offset) { _, kind in
                    HStack(spacing: 18) {
                        label(kind?.rawValue ?? "none").frame(width: 60, alignment: .leading)
                        ForEach([12.0, 34.0], id: \.self) { pt in
                            HStack(spacing: 6) {
                                Image(systemName: kind?.symbol ?? "terminal")
                                Text("Ag")
                                AgentGlyph.image(agent: kind)
                            }
                            .font(.system(size: pt, weight: .bold))
                            .foregroundStyle(fg)
                        }
                    }
                }
            }
            .padding(16)
            .background(scheme == .light ? Color.white : Color.black)
            try save(sheet, "marks-\(word)")
        }
    }

    /// The sidebar's Agents rows (`AgentRowLabel`'s tile and name) and the agent board, for every
    /// kind, in a dark and a light theme.
    @Test func drawsTheSidebarsTilesAndTheBoard() throws {
        for id in ["github-dark-dimmed", "github-light-default"] {
            let theme = ThemeStore.theme(id)
            let rows = VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.kinds.enumerated()), id: \.offset) { _, kind in
                    HStack(alignment: .top, spacing: 9) {
                        ZStack {
                            TabRowLabel.tile(kind).fill(TabRowLabel.tint(kind, theme).opacity(0.9))
                            AgentGlyph.image(agent: kind, fallback: "cpu")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.bg)
                        }
                        .frame(width: 18, height: 18)
                        .padding(.top, 1)
                        Text(kind?.displayName ?? "Program").font(.subheadline.weight(.semibold)).foregroundStyle(theme.fg)
                    }
                }
            }
            .padding(14)
            .frame(width: 200, alignment: .leading)
            .background(theme.chrome.sidebar)
            try save(rows, "sidebar-\(id)")

            // The board as `-boardDemo kinds` shows it, in a portrait and a landscape window.
            #if DEBUG
            let machines = try #require(BoardDemo.machines("kinds", now: Date()))
            for (w, h, shape) in [(390.0, 640.0, "portrait"), (720.0, 400.0, "landscape")] {
                try save(AgentBoardView(machines: machines, theme: theme, onOpen: { _ in }, onMore: {})
                    .frame(width: w, height: h).background(theme.chrome.sidebar)
                    .environment(\.colorScheme, theme.isDark ? .dark : .light), "board-\(id)-\(shape)")
            }
            #endif
        }
    }
}
