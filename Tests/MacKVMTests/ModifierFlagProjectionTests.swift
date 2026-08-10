import CoreGraphics
import XCTest
@testable import MacKVM

final class ModifierFlagProjectionTests: XCTestCase {
    func testReleasingOneSideKeepsAggregateModifierFlagWhileOtherIsHeld() {
        let projected = ModifierFlagProjection.projectedFlags(
            reportedFlags: [.maskShift],
            keyCode: 56,
            isPressed: false,
            pressedKeyCodes: [56, 60]
        )

        XCTAssertTrue(projected.contains(.maskShift))
    }

    func testReleasingTheLastSideRemovesAggregateModifierFlag() {
        let projected = ModifierFlagProjection.projectedFlags(
            reportedFlags: [.maskShift],
            keyCode: 56,
            isPressed: false,
            pressedKeyCodes: [56]
        )

        XCTAssertFalse(projected.contains(.maskShift))
        XCTAssertTrue(
            ModifierFlagProjection.aggregateFlags(for: [60])
                .contains(.maskShift)
        )
    }

    func testReleaseFlagsPreserveLocallyHeldModifiers() {
        let flags = ModifierFlagProjection.releaseFlags(
            preservingLocalKeyCodes: [54],
            remainingRemoteKeyCodes: []
        )

        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertFalse(flags.contains(.maskNumericPad))

        let overlappingGroupFlags = ModifierFlagProjection.releaseFlags(
            preservingLocalKeyCodes: [56],
            remainingRemoteKeyCodes: []
        )
        XCTAssertTrue(overlappingGroupFlags.contains(.maskShift))
    }

    func testCapsLockUsesToggleFlagAsItsEdgeState() {
        let enabled = ModifierFlagProjection.projectedFlags(
            reportedFlags: [.maskAlphaShift],
            keyCode: 57,
            isPressed: true,
            pressedKeyCodes: []
        )
        let disabled = ModifierFlagProjection.projectedFlags(
            reportedFlags: [],
            keyCode: 57,
            isPressed: false,
            pressedKeyCodes: [57]
        )

        XCTAssertTrue(enabled.contains(.maskAlphaShift))
        XCTAssertFalse(disabled.contains(.maskAlphaShift))
    }

    func testCapsLockCaptureForwardsOnlyStateEdges() {
        var policy = CapsLockCapturePolicy()

        XCTAssertEqual(
            policy.nextState(from: [.maskAlphaShift]),
            true
        )
        XCTAssertNil(policy.nextState(from: [.maskAlphaShift]))
        XCTAssertEqual(policy.nextState(from: []), false)
        XCTAssertNil(policy.nextState(from: []))

        policy.reset()
        XCTAssertEqual(policy.nextState(from: [.maskAlphaShift]), true)
    }

    func testLegacyCapsLockRemoteInputUsesReportedStateEdges() {
        var policy = CapsLockRemoteInputPolicy()

        XCTAssertEqual(
            policy.keyDown(
                explicitState: nil,
                modifierFlags: CGEventFlags.maskAlphaShift.rawValue
            ),
            true
        )
        XCTAssertNil(
            policy.keyDown(
                explicitState: nil,
                modifierFlags: CGEventFlags.maskAlphaShift.rawValue
            )
        )
        XCTAssertEqual(
            policy.keyDown(explicitState: nil, modifierFlags: 0),
            false
        )
        XCTAssertEqual(
            policy.keyDown(explicitState: true, modifierFlags: 0),
            true
        )
    }
}
