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
        XCTAssertFalse(ReceiveSessionPolicy.onlyFailuresRemain(fileIDs: files, failedFileIDs: failed))

        files.remove("b")  // B stored
        XCTAssertFalse(
            ReceiveSessionPolicy.isReceiving(fileIDs: files, failedFileIDs: failed),
            "the failed file must not keep the session receiving"
        )
        XCTAssertTrue(ReceiveSessionPolicy.onlyFailuresRemain(fileIDs: files, failedFileIDs: failed))
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

    // MARK: cancel

    /// A cancel that arrives when nothing is running must be a no-op: the flag it
    /// sets is consumed by the failure path, so it used to survive and suppress the
    /// next transfer's failure card.
    func testACancelNeedsSomethingToCancel() {
        XCTAssertTrue(ReceiveSessionPolicy.canCancel(isReceiving: true, hasSession: false))
        XCTAssertTrue(ReceiveSessionPolicy.canCancel(isReceiving: false, hasSession: true))
        XCTAssertFalse(ReceiveSessionPolicy.canCancel(isReceiving: false, hasSession: false))
    }

    // MARK: cancel flags

    /// The sticky-flag bug: a cancel that arrived when nothing was left to abort
    /// stayed set, and the next transfer's failure card was silently suppressed.
    func testStartingAnUploadClearsCarriedOverCancelFlags() {
        var flags = ReceiveUploadFlags()
        flags.requestCancel()          // nothing was in flight; the flag lingered
        XCTAssertTrue(flags.userCancelled)
        flags.beginUpload()            // the next transfer starts
        XCTAssertFalse(flags.userCancelled)
        XCTAssertFalse(flags.cancelRequested)
        // With the flags cleared, the next transfer's failure is reported normally —
        // which is the fix: it used to be suppressed by the carried-over flag.
        XCTAssertTrue(ReceiveSessionPolicy.recordsFailureCard(userCancelled: flags.userCancelled))
    }

    func testConsumingAUserCancelClearsBothFlags() {
        var flags = ReceiveUploadFlags()
        flags.requestCancel()
        XCTAssertTrue(flags.consumeUserCancelled())
        XCTAssertFalse(flags.userCancelled)
        XCTAssertFalse(flags.cancelRequested)
        XCTAssertFalse(flags.consumeUserCancelled(), "a second consume reports nothing")
    }

    // MARK: failure attribution

    /// A sender's /cancel can race a failing upload; the card must not outlive the
    /// session it belonged to.
    func testAFailureForAGoneSessionIsIgnored() {
        XCTAssertFalse(
            ReceiveSessionPolicy.recordsFailure(fileID: "a", sessionFileIDs: [], sessionActive: false)
        )
        XCTAssertFalse(
            ReceiveSessionPolicy.recordsFailure(fileID: "a", sessionFileIDs: ["b"], sessionActive: true)
        )
        XCTAssertTrue(
            ReceiveSessionPolicy.recordsFailure(fileID: "a", sessionFileIDs: ["a", "b"], sessionActive: true)
        )
    }

    func testSessionIdentityCheck() {
        XCTAssertTrue(ReceiveSessionPolicy.isCurrentSession("s1", expected: "s1"))
        XCTAssertFalse(ReceiveSessionPolicy.isCurrentSession("s2", expected: "s1"))
        XCTAssertFalse(ReceiveSessionPolicy.isCurrentSession(nil, expected: "s1"))
    }

    // MARK: upload cancellations

    /// The registry M-4 relies on: a cancel must reach every upload in flight, and
    /// one upload finishing must not clear another's entry (it used to be a single
    /// slot, so concurrent uploads clobbered each other).
    func testEveryUploadInFlightCanBeCancelled() {
        var registry = ActiveUploadCancellations()
        var cancelled: Set<String> = []
        registry.register(fileID: "a") { cancelled.insert("a") }
        registry.register(fileID: "b") { cancelled.insert("b") }
        XCTAssertEqual(registry.count, 2)

        XCTAssertEqual(registry.cancelAll(), 2)
        XCTAssertEqual(cancelled, ["a", "b"])
        XCTAssertEqual(registry.count, 0, "cancelAll also forgets them")
    }

    func testOneUploadFinishingLeavesTheOtherRegistered() {
        var registry = ActiveUploadCancellations()
        var cancelled: Set<String> = []
        registry.register(fileID: "a") { cancelled.insert("a") }
        registry.register(fileID: "b") { cancelled.insert("b") }

        registry.clear(fileID: "a")  // the first upload ended on its own
        XCTAssertEqual(registry.count, 1)

        XCTAssertEqual(registry.cancelAll(), 1)
        XCTAssertEqual(cancelled, ["b"], "the finished upload must not be cancelled")
    }

    func testReRegisteringTheSameFileReplacesTheEntry() {
        var registry = ActiveUploadCancellations()
        var first = 0
        var second = 0
        registry.register(fileID: "a") { first += 1 }
        registry.register(fileID: "a") { second += 1 }  // a retry of the same file

        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry.cancelAll(), 1)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    func testCancellingWithNothingInFlightIsHarmless() {
        var registry = ActiveUploadCancellations()
        XCTAssertEqual(registry.cancelAll(), 0)
        XCTAssertEqual(registry.count, 0)
    }

    // MARK: slot release

    func testOnlyFailuresRemainIsDetected() {
        XCTAssertTrue(ReceiveSessionPolicy.onlyFailuresRemain(fileIDs: ["a"], failedFileIDs: ["a"]))
        XCTAssertTrue(ReceiveSessionPolicy.onlyFailuresRemain(fileIDs: ["a", "b"], failedFileIDs: ["a", "b"]))
    }

    func testAFailedFileDoesNotMeanOnlyFailuresRemain() {
        XCTAssertFalse(ReceiveSessionPolicy.onlyFailuresRemain(fileIDs: ["a", "b"], failedFileIDs: ["a"]))
        XCTAssertFalse(ReceiveSessionPolicy.onlyFailuresRemain(fileIDs: [], failedFileIDs: []))
    }
}
