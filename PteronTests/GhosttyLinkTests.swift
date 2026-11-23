import XCTest
@testable import Pteron

/// Tests reach libghostty-vt through the app's Swift types only. The library is linked into the
/// app, so a test that calls a C function the app doesn't use fails to link.
final class GhosttyLinkTests: XCTestCase {
    func testLibraryLinksAndReportsAVersion() {
        XCTAssertFalse(GhosttyBuild.version.isEmpty)
    }
}
