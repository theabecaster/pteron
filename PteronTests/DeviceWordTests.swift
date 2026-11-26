import Testing
@testable import Pteron

struct DeviceWordTests {
    @Test func theWordIsNeverEmpty() {
        #expect(!DeviceWord.current.isEmpty)
        #expect(["iPhone", "iPad"].contains(DeviceWord.current))
    }

    @Test func modelsMapToTheirDevice() {
        #expect(DeviceWord.word(forModel: "iPhone18,1") == "iPhone")
        #expect(DeviceWord.word(forModel: "iPad16,3") == "iPad")
        #expect(DeviceWord.word(forModel: "Mac15,6") == "iPad")
        #expect(DeviceWord.word(forModel: "") == "iPhone")
        #expect(DeviceWord.word(forModel: "arm64") == "iPhone")
    }
}
