import XCTest
@testable import LocalSendProtocol

/// The receive session rules that were each a shipped bug once.
final class ReceiveSessionPolicyTests: XCTestCase {
    // MARK: card priority

    func testAPendingRequestWinsOverEverything() {
        XCTAssertEqual(
            ReceiveSessionPolicy.card(pendingRequest: true, failure: true, receiving: true, completion: true),
            .request
        )
    }

    /// The failure card used to render behind a progress card that was never going
    /// to move, so a failed transfer looked like it was still arriving.
    func testAFailureBeatsProgress() {
        XCTAssertEqual(
            ReceiveSessionPolicy.card(pendingRequest: false, failure: true, receiving: true, completion: false),
            .failure
        )
    }

    func testTheRemainingOrder() {
        XCTAssertEqual(
            ReceiveSessionPolicy.card(pendingRequest: false, failure: false, receiving: true, completion: true),
            .progress
        )
        XCTAssertEqual(
            ReceiveSessionPolicy.card(pendingRequest: false, failure: false, receiving: false, completion: true),
            .completion
        )
        XCTAssertEqual(
            ReceiveSessionPolicy.card(pendingRequest: false, failure: false, receiving: false, completion: false),
            .none
        )
    }

    // MARK: still receiving

    func testAPendingFileKeepsTheSessionReceiving() {
        XCTAssertTrue(ReceiveSessionPolicy.isReceiving(fileIDs: ["a", "b"], failedFileIDs: ["a"]))
    }

    /// A failed file stays in the session for its retry window; counting it kept the
    /// progress card up with nothing left to arrive.
    func testOnlyFailedFilesLeftMeansNotReceiving() {
        XCTAssertFalse(ReceiveSessionPolicy.isReceiving(fileIDs: ["a"], failedFileIDs: ["a"]))
        XCTAssertFalse(ReceiveSessionPolicy.isReceiving(fileIDs: [], failedFileIDs: []))
    }

    /// The two-file session that exposed the bug: A fails, B is stored, and the
    /// session must stop being "receiving" and hand the slot back.
    func testTwoFileSessionWhereTheFirstFails() {
        var files: Set<String> = ["a", "b"]
        let failed: Set<String> = ["a"]

        XCTAssertTrue(ReceiveSessionPolicy.isReceiving(fileIDs: files, failedFileIDs: []))
        XCTAssertTrue(ReceiveSessionPolicy.isReceiving(fileIDs: files, failedFileIDs: failed), "B is still to come")
        XCTAssertFalse(ReceiveSessionPolicy.releasesSlotImmediately(fileIDs: files, failedFileIDs: failed))

        files.remove("b")  // B stored
        XCTAssertFalse(
            ReceiveSessionPolicy.isReceiving(fileIDs: files, failedFileIDs: failed),
            "the failed file must not keep the session receiving"
        )
        XCTAssertTrue(ReceiveSessionPolicy.releasesSlotImmediately(fileIDs: files, failedFileIDs: failed))
    }

    // MARK: failure card

    func testAnOrdinaryFailureIsReported() {
        XCTAssertTrue(ReceiveSessionPolicy.recordsFailureCard(userCancelled: false))
    }

    /// A cancel the user asked for must not raise a failure card — and, because the
    /// flag was sticky once, must not suppress the next transfer's either.
    func testAUserCancelIsNotAFailure() {
        XCTAssertFalse(ReceiveSessionPolicy.recordsFailureCard(userCancelled: true))
    }

    // MARK: slot release

    func testTheSlotGoesBackWhenOnlyFailuresRemain() {
        XCTAssertTrue(ReceiveSessionPolicy.releasesSlotImmediately(fileIDs: ["a"], failedFileIDs: ["a"]))
        XCTAssertTrue(ReceiveSessionPolicy.releasesSlotImmediately(fileIDs: ["a", "b"], failedFileIDs: ["a", "b"]))
    }

    func testTheSlotIsKeptWhileSomethingCanStillArrive() {
        XCTAssertFalse(ReceiveSessionPolicy.releasesSlotImmediately(fileIDs: ["a", "b"], failedFileIDs: ["a"]))
        XCTAssertFalse(ReceiveSessionPolicy.releasesSlotImmediately(fileIDs: [], failedFileIDs: []))
    }
}
