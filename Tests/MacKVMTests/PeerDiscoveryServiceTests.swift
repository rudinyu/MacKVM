import XCTest
@testable import MacKVM

final class PeerDiscoveryServiceTests: XCTestCase {
    func testEOFWithoutAnActivePairingCancelsImmediately() {
        XCTAssertTrue(
            PairingConnectionEOFPolicy.shouldCancelAfterEOF(
                activePairingCount: 0
            )
        )
    }

    func testEOFWithAnActivePairingRemainsAvailableForCompletion() {
        XCTAssertFalse(
            PairingConnectionEOFPolicy.shouldCancelAfterEOF(
                activePairingCount: 1
            )
        )
    }
}
