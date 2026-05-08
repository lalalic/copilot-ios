import XCTest
@testable import Feedback

final class FeedbackTests: XCTestCase {

    func testAnonIdIsStableAcrossCalls() {
        // Use a unique suite per test run so we don't cross-pollute.
        let suite = "test-anon-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "\(suite).anonId") }

        let a = Feedback.anonId(suite: suite)
        let b = Feedback.anonId(suite: suite)
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b)
    }

    func testSubmitRejectsHttpEndpoint() async {
        let r = await Feedback.submit(
            endpoint: URL(string: "http://example.com/issues")!,
            app: "test-app",
            title: "x", body: "y",
            kind: .bug, source: .user)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error, "Couldn't send feedback right now.")
    }
}
