import Testing
@testable import GlanceModel

@Suite struct BrandTests {
    /// The one place in Swift that spells the name besides the constant. Every other test reads
    /// `Brand`, so without this pin they would pass whatever the name was.
    @Test func theNameIsPinned() {
        #expect(Brand.appName == "Pteron")
    }

    @Test func beaconIsNamedAfterTheApp() {
        #expect(Brand.beaconName == Brand.appName + " Beacon")
    }
}
