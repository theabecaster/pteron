import Foundation
import XCTest
@testable import RexKit

/// A system callback that comes twice resumes its continuation once. Build 2611201727 crashed
/// at Try Again because URLSession called a data socket's pong handler a second time, with an
/// error, and the ping resumed its checked continuation again.
final class ResumeOnceTests: XCTestCase {
    /// Calls the pong handler with each of `calls` in turn, as URLSession did.
    private final class TwiceAnsweringTask: PongSending, @unchecked Sendable {
        // `@unchecked`: `calls` is set before the ping and only read on `queue` after.
        let calls: [Error?]
        private let queue = DispatchQueue(label: "test.twice-pong")
        init(_ calls: [Error?]) { self.calls = calls }

        func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
            let calls = calls
            queue.async { for c in calls { pongReceiveHandler(c) } }
        }
    }

    func testPongThenErrorReturns() async throws {
        let task = TwiceAnsweringTask([nil, URLError(.networkConnectionLost)])
        try await task.awaitPong()
    }

    func testErrorThenPongThrowsTheFirstError() async {
        let task = TwiceAnsweringTask([URLError(.timedOut), nil, URLError(.cancelled)])
        do {
            try await task.awaitPong()
            XCTFail("the ping succeeded")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testOnlyTheFirstResumeCounts() async throws {
        let got: Int = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
            let once = ResumeOnce(c)
            DispatchQueue.global().async {
                once.resume(returning: 1)
                once.resume(throwing: URLError(.cancelled))
                once.resume(returning: 2)
            }
        }
        XCTAssertEqual(got, 1)
    }
}
