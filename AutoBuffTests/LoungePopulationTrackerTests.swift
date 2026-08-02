import XCTest
@testable import AutoBuff

final class LoungePopulationTrackerTests: XCTestCase {
    func testIncreaseRequiresTwoMatchingFrames() {
        var tracker = LoungePopulationTracker()
        let one = LoungeMarkerCounts(yellow: 1, orange: 0)
        let two = LoungeMarkerCounts(yellow: 1, orange: 1)

        XCTAssertNil(tracker.observe(one))
        XCTAssertNil(tracker.observe(one))
        XCTAssertNil(tracker.observe(two))

        let change = tracker.observe(two)
        XCTAssertEqual(change?.previous, one)
        XCTAssertEqual(change?.current, two)
        XCTAssertEqual(change?.increased, true)
    }

    func testDecreaseThenIncreaseStillTriggers() {
        var tracker = LoungePopulationTracker()
        let three = LoungeMarkerCounts(yellow: 1, orange: 2)
        let two = LoungeMarkerCounts(yellow: 1, orange: 1)

        XCTAssertNil(tracker.observe(three))
        XCTAssertNil(tracker.observe(three))
        XCTAssertNil(tracker.observe(two))
        XCTAssertEqual(tracker.observe(two)?.increased, false)
        XCTAssertNil(tracker.observe(three))
        XCTAssertEqual(tracker.observe(three)?.increased, true)
    }

    func testSingleFrameDropDoesNotChangeBaseline() {
        var tracker = LoungePopulationTracker()
        let normal = LoungeMarkerCounts(yellow: 1, orange: 2)
        let dropped = LoungeMarkerCounts(yellow: 0, orange: 1)

        XCTAssertNil(tracker.observe(normal))
        XCTAssertNil(tracker.observe(normal))
        XCTAssertNil(tracker.observe(dropped))
        XCTAssertNil(tracker.observe(normal))
        XCTAssertEqual(tracker.baseline, normal)
    }
}
