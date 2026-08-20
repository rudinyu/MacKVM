import XCTest
@testable import MacKVMCore

final class BoundedAdmissionGateTests: XCTestCase {
    func testCapacitySignalsOnceAndInvalidatesTheAdmissionWindow() {
        let gate = BoundedAdmissionGate(capacity: 1, initiallyEnabled: true)

        let first = gate.reserve()
        XCTAssertTrue(first.accepted)
        let overflow = gate.reserve()
        XCTAssertFalse(overflow.accepted)
        XCTAssertTrue(overflow.shouldSignalFailure)
        let repeated = gate.reserve()
        XCTAssertFalse(repeated.accepted)
        XCTAssertFalse(repeated.shouldSignalFailure)
    }

    func testOverflowDoesNotInvalidateAlreadyAdmittedWork() {
        let gate = BoundedAdmissionGate(capacity: 1, initiallyEnabled: true)

        let admitted = gate.reserve()
        XCTAssertTrue(admitted.accepted)
        XCTAssertFalse(gate.reserve().accepted)

        XCTAssertTrue(gate.isCurrent(admitted))
        gate.release(admitted)
    }

    func testActivationDoesNotReopenAnOverflowedGeneration() {
        let gate = BoundedAdmissionGate(capacity: 1, initiallyEnabled: true)

        XCTAssertTrue(gate.reserve().accepted)
        XCTAssertFalse(gate.reserve().accepted)

        gate.activate()

        XCTAssertFalse(gate.reserve().accepted)
    }

    func testOldReservationsCannotAffectANewGeneration() {
        let gate = BoundedAdmissionGate(capacity: 1, initiallyEnabled: true)
        let old = gate.reserve()

        gate.begin()
        let blockedByOldGeneration = gate.reserve()
        XCTAssertFalse(blockedByOldGeneration.accepted)
        XCTAssertTrue(blockedByOldGeneration.shouldSignalFailure)
        gate.release(old)
        let current = gate.reserve()

        XCTAssertTrue(gate.isCurrent(current))
        XCTAssertFalse(gate.reserve().accepted)
    }

    func testReservationReleaseIsSingleUse() {
        let gate = BoundedAdmissionGate(capacity: 2, initiallyEnabled: true)
        let first = gate.reserve()
        XCTAssertTrue(first.accepted)
        XCTAssertTrue(gate.reserve().accepted)

        gate.release(first)
        gate.release(first)

        XCTAssertTrue(gate.reserve().accepted)
        XCTAssertFalse(gate.reserve().accepted)
        XCTAssertFalse(gate.isCurrent(first))
    }
}
