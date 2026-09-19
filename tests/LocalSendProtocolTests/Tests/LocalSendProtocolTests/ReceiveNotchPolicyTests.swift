import XCTest
@testable import LocalSendProtocol

/// The notch hand-back rules. These bugs are why this logic is pure: the notch
/// used to stay expanded after an answered prompt, and collapsing it too eagerly
/// (on the instant between "accepted" and "receiving") broke the same flow from
/// the other side.
final class ReceiveNotchPolicyTests: XCTestCase {
    func testACardAlwaysHoldsTheNotch() {
        for inactiveFor in [0.0, 1.0, 60.0] {
            let decision = ReceiveNotchPolicy.decide(cardVisible: true, inactiveFor: inactiveFor)
            XCTAssertTrue(decision.holdsNotch, "inactiveFor=\(inactiveFor)")
            XCTAssertFalse(decision.concludes)
        }
    }

    /// Accepting passes through an inactive instant; concluding on it consumed the
    /// ownership flag and the notch then never collapsed after the transfer.
    func testTheInstantBetweenAcceptAndReceivingDoesNotConclude() {
        let decision = ReceiveNotchPolicy.decide(cardVisible: false, inactiveFor: 0.05)
        XCTAssertTrue(decision.holdsNotch, "the token must survive the accept instant")
        XCTAssertFalse(decision.concludes)
    }

    func testTheGraceIsInclusiveAtItsBoundary() {
        let atBoundary = ReceiveNotchPolicy.decide(cardVisible: false, inactiveFor: ReceiveNotchPolicy.inactivityGrace)
        XCTAssertFalse(atBoundary.concludes)
        let pastBoundary = ReceiveNotchPolicy.decide(cardVisible: false, inactiveFor: ReceiveNotchPolicy.inactivityGrace + 0.1)
        XCTAssertTrue(pastBoundary.concludes)
        XCTAssertFalse(pastBoundary.holdsNotch)
    }

    /// The sequence an accepted transfer actually goes through: prompt, accept
    /// (inactive for an instant), progress, completion, then gone.
    func testAnAcceptedTransferIsOnlyConcludedOnceItIsReallyOver() {
        var concludedAt: [Double] = []
        let timeline: [(cardVisible: Bool, inactiveFor: Double)] = [
            (true, 0),          // the prompt
            (false, 0.05),      // accepted: the session does not exist yet
            (true, 0),          // receiving
            (true, 0),          // completion card
            (false, 1.0),       // card just cleared
            (false, 2.0),       // still gone
        ]
        for (index, step) in timeline.enumerated() {
            if ReceiveNotchPolicy.decide(cardVisible: step.cardVisible, inactiveFor: step.inactiveFor).concludes {
                concludedAt.append(Double(index))
            }
        }
        XCTAssertEqual(concludedAt, [5], "only the last step is the end of the flow")
    }

    func testANotchThisFlowOpenedIsHandedBack() {
        XCTAssertTrue(
            ReceiveNotchPolicy.shouldClose(ownsNotch: true, notchOpen: true, hovering: false, preventedByOthers: false)
        )
    }

    /// An automatically accepted transfer never opened the notch, so it must not
    /// close one the user opened for something else (music, the shelf).
    func testANotchTheUserOpenedIsLeftAlone() {
        XCTAssertFalse(
            ReceiveNotchPolicy.shouldClose(ownsNotch: false, notchOpen: true, hovering: false, preventedByOthers: false)
        )
    }

    func testHoveringOrAnotherOwnerBlocksTheClose() {
        XCTAssertFalse(
            ReceiveNotchPolicy.shouldClose(ownsNotch: true, notchOpen: true, hovering: true, preventedByOthers: false)
        )
        XCTAssertFalse(
            ReceiveNotchPolicy.shouldClose(ownsNotch: true, notchOpen: true, hovering: false, preventedByOthers: true)
        )
    }

    func testAClosedNotchIsNotClosedAgain() {
        XCTAssertFalse(
            ReceiveNotchPolicy.shouldClose(ownsNotch: true, notchOpen: false, hovering: false, preventedByOthers: false)
        )
    }
}
