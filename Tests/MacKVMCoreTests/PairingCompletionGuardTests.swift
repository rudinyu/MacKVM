import XCTest
@testable import MacKVMCore

final class PairingCompletionGuardTests: XCTestCase {
    func testMatchingRequestPeerAndGenerationPermitsCompletion() {
        let requestID = UUID()
        let peerID = UUID()
        let guardToken = PairingCompletionGuard(
            requestID: requestID,
            peerID: peerID,
            generation: 4
        )

        XCTAssertTrue(guardToken.permits(currentGeneration: 4))
    }

    func testForgetGenerationOrIdentityMismatchRejectsCompletion() {
        let requestID = UUID()
        let peerID = UUID()
        let guardToken = PairingCompletionGuard(
            requestID: requestID,
            peerID: peerID,
            generation: 4
        )

        XCTAssertFalse(
            guardToken.permits(
                currentGeneration: 5
            )
        )
        XCTAssertNotEqual(
            guardToken,
            PairingCompletionGuard(
                requestID: UUID(),
                peerID: peerID,
                generation: 4
            )
        )
    }
}
