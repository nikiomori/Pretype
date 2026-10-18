import XCTest
@testable import Pretype

/// Who holds the one query slot: a completion or a reply, superseded by the
/// next, freed only by its own task, and deduped while its ghost lives.
final class QuerySlotTests: XCTestCase {
    private func idle() -> Task<Void, Never> { Task {} }

    func testTheNextQueryCancelsTheOneInFlight() {
        var slot = QuerySlot()
        var first: Task<Void, Never>?
        slot.start(.completion(before: "Hi ", after: "")) { _ in
            first = idle()
            return first ?? idle()
        }
        slot.start(.reply) { _ in idle() }
        XCTAssertEqual(first?.isCancelled, true)
        XCTAssertTrue(slot.isReply)
        slot.cancel()
        XCTAssertNil(slot.current, "freed, not just cancelled")
    }

    // A finishing task frees the slot only while it still holds it: a stale
    // stream ending must not clear the query that replaced it.
    func testOnlyItsOwnTaskFreesTheSlot() {
        var slot = QuerySlot()
        var ids: [Int] = []
        slot.start(.completion(before: "Hi ", after: "")) { ids.append($0); return idle() }
        slot.start(.completion(before: "Hi t", after: "")) { ids.append($0); return idle() }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
        slot.finish(ids[0])
        XCTAssertEqual(slot.current?.id, ids[1])
        slot.finish(ids[1])
        XCTAssertNil(slot.current)
    }

    // One edit reaches the pipeline twice: the second finds its query running.
    // Once the ghost it streams into is retired, the same text queries again.
    // A reply is never a completion's dedupe, retired or not.
    func testDedupeLastsWhileTheGhostDoes() {
        var slot = QuerySlot()
        slot.start(.completion(before: "Hi ", after: "!")) { _ in idle() }
        XCTAssertTrue(slot.isRunning(before: "Hi ", after: "!"))
        XCTAssertFalse(slot.isRunning(before: "Hi ", after: ""))
        XCTAssertFalse(slot.isRunning(before: "Hi t", after: "!"))
        slot.ghostRetired()
        XCTAssertEqual(slot.current?.kind, .retired)
        XCTAssertFalse(slot.isRunning(before: "Hi ", after: "!"))

        slot.start(.reply) { _ in idle() }
        slot.ghostRetired()
        XCTAssertTrue(slot.isReply)
    }
}
