import Foundation
import GlanceModel
import Testing
import UIKit
@testable import Pteron

/// The name and the launch art are each said in one place in code (`Brand`, `LaunchArt`) and
/// repeated where code can't reach: the Info.plists, the installer, the acknowledgements. These
/// hold the copies to the source. `GlanceModel`'s own tests pin the name itself.
@MainActor
struct BrandTests {
    private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

    @Test func theHomeScreenNameIsTheBrands() {
        #expect(info("CFBundleDisplayName") as? String == Brand.appName)
    }

    @Test func theControlsExtensionCarriesTheSameName() throws {
        let plist = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("PteronWidgets.appex/Info.plist"))
        let values = try #require(NSDictionary(contentsOf: plist))
        #expect(values["CFBundleDisplayName"] as? String == Brand.appName)
    }

    @Test func theCameraPromptStartsWithTheName() throws {
        let text = try #require(info("NSCameraUsageDescription") as? String)
        #expect(text.hasPrefix(Brand.appName + " uses the camera"))
    }

    @Test func theLaunchScreenShowsTheLaunchArt() throws {
        let screen = try #require(info("UILaunchScreen") as? [String: Any])
        #expect(screen["UIImageName"] as? String == LaunchArt.assetName)
        #expect(UIImage(named: LaunchArt.assetName) != nil)
    }

    @Test func theAcknowledgementsStartWithTheName() throws {
        let url = try #require(Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: " ").first.map(String.init) == Brand.appName)
    }

    /// The name is written out in a string literal in two Swift files, the constant and the test
    /// that pins it. Every other file, the tests' expectations included, reads the constant.
    /// Identifiers, module names and paths may carry the name (`PteronWidgets`, `PteronTests.`,
    /// `Pteron/State/…`), so only a quoted run with the name as a whole word counts, outside comments. This
    /// file holds the rule and its folder list, and CalmRuleTests lists folders, so both are skipped.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: sourceTree.appendingPathComponent("project.yml").path),
                   "the source tree is not on this machine"))
    func theNameIsWrittenInTwoSwiftStringLiterals() throws {
        let literal = try NSRegularExpression(pattern: "\"[^\"\\n]*(?<![/.\\w])\(Brand.appName)(?![./\\w])[^\"\\n]*\"")
        var found: [String] = []
        for folder in ["Pteron", "PteronWidgets", "PteronTests", "Packages"] {
            let files = try #require(FileManager.default.enumerator(at: Self.sourceTree.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" && !file.path.contains("/.build/") && file.path != #filePath && file.lastPathComponent != "CalmRuleTests.swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                if literal.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil { found.append(file.lastPathComponent) }
            }
        }
        #expect(found.sorted() == ["Brand.swift", "BrandTests.swift"])
    }

    private nonisolated static let sourceTree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    // MARK: The bundled installer

    /// The one line of the installer that sets `name`, without its quotes.
    private func installerValue(_ name: String) throws -> String {
        let url = try #require(Bundle.main.url(forResource: "setup", withExtension: "sh"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("\(name)=") }
        try #require(lines.count == 1, "\(name) is set on \(lines.count) lines")
        return lines[0].dropFirst(name.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private nonisolated static let installerIsBundled = Bundle.main.url(forResource: "setup", withExtension: "sh") != nil

    @Test(.enabled(if: installerIsBundled, "this build has no installer"))
    func theInstallerCallsBeaconWhatTheAppDoes() throws {
        #expect(try installerValue("BEACON") == Brand.beaconName)
    }

    /// The app hands the installer the hash of one file of a release, and the installer looks
    /// for the files by name, the newest first: the two must mean the same files.
    @Test(.enabled(if: installerIsBundled, "this build has no installer"))
    func theInstallerLooksForTheZipTheAppHashes() throws {
        #expect(try installerValue("MAC_ASSETS").split(separator: " ").map(String.init)
            == [HelperRelease.macAppAsset, HelperRelease.macBeaconAsset, HelperPlatform.mac.asset])
        #expect(try installerValue("MAC_ENTRIES").split(separator: " ").map(String.init)
            == [HelperRelease.macAppKey, HelperRelease.macBeaconKey, HelperPlatform.mac.rawValue])
    }
}
