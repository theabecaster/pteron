import Foundation
import GlanceUI
import Testing
import UIKit
@testable import PteronWatch

/// The agents' marks (`AgentGlyph`) are in the watch app's bundle and its complications'.
@Suite struct WatchGlyphTests {
    @Test func everyMarkIsInTheWatchAppAndItsComplications() throws {
        let complications = try #require(Bundle.main.builtInPlugInsURL
            .flatMap { Bundle(url: $0.appendingPathComponent("PteronWatchWidgets.appex")) }, "the complications are embedded in the watch app")
        for kind in AgentGlyph.marked {
            for (bundle, name) in [(Bundle.main, "watch app"), (complications, "complications")] {
                let image = UIImage(named: "agent.\(kind)", in: bundle, with: nil)
                #expect(image != nil, "agent.\(kind) in the \(name)")
                #expect(image?.isSymbolImage == true, "agent.\(kind) in the \(name) is a symbol")
            }
        }
    }
}
