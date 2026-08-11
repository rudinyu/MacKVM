import XCTest
@testable import MacKVMCore

final class ControlProtocolTests: XCTestCase {
    func testInputMessageRoundTrips() throws {
        let event = RemoteInputEvent(kind: .keyDown, keyCode: 36)
        let message = ControlMessage.input(event, requestID: UUID())

        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(message)
            ),
            message
        )
    }

    func testControlMessageRejectsUnexpectedInput() {
        let message = ControlMessage(
            kind: .endControl,
            requestID: UUID(),
            input: RemoteInputEvent(kind: .keyUp, keyCode: 12)
        )

        XCTAssertThrowsError(try message.validated()) { error in
            XCTAssertEqual(
                error as? ControlProtocolError,
                .invalidFields
            )
        }
    }

    func testControlResponseRetainsRequestIdentifier() throws {
        let requestID = UUID()
        let message = ControlMessage(
            kind: .controlGranted,
            requestID: requestID
        )

        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(message)
            ).requestID,
            requestID
        )
    }

    func testControlRequestCarriesProtocolAndKeyboardLayoutNegotiation() throws {
        let requestID = UUID()
        let message = ControlMessage.requestControl(
            requestID: requestID,
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        let decoded = try ControlMessageCodec.decode(
            ControlMessageCodec.encode(message)
        )

        XCTAssertEqual(
            decoded.protocolVersion,
            ControlMessage.currentProtocolVersion
        )
        XCTAssertEqual(decoded.minimumProtocolVersion, 1)
        XCTAssertEqual(
            decoded.keyboardLayoutIdentifier,
            "com.apple.keylayout.US"
        )
    }

    func testProtocolRangesRequireAnOverlappingVersion() {
        XCTAssertTrue(
            ControlProtocolCompatibility.isCompatible(
                remoteVersion: 1,
                remoteMinimumVersion: 1
            )
        )
        XCTAssertTrue(
            ControlProtocolCompatibility.isCompatible(
                remoteVersion: 2,
                remoteMinimumVersion: 2
            )
        )
        XCTAssertFalse(
            ControlProtocolCompatibility.isCompatible(
                remoteVersion: 3,
                remoteMinimumVersion: 3
            )
        )
        XCTAssertFalse(
            ControlProtocolCompatibility.isCompatible(
                remoteVersion: 1,
                remoteMinimumVersion: 2
            )
        )
    }

    func testRequestRejectsAnUnboundedKeyboardLayoutIdentifier() {
        let message = ControlMessage(
            kind: .requestControl,
            requestID: UUID(),
            protocolVersion: 1,
            minimumProtocolVersion: 1,
            keyboardLayoutIdentifier: String(repeating: "x", count: 257)
        )

        XCTAssertThrowsError(try message.validated()) { error in
            XCTAssertEqual(
                error as? ControlProtocolError,
                .invalidFields
            )
        }
    }

    func testControlMessageRequiresRequestIdentifier() {
        XCTAssertThrowsError(
            try ControlMessage(kind: .controlGranted).validated()
        ) { error in
            XCTAssertEqual(error as? ControlProtocolError, .invalidFields)
        }
    }

    func testStateMachineRequiresGrantBeforeControlling() throws {
        var machine = ControlSessionStateMachine()

        XCTAssertEqual(
            try machine.handle(.transportConnected),
            .connected
        )
        XCTAssertThrowsError(try machine.handle(.controlGranted))
        XCTAssertEqual(try machine.handle(.requestControl), .suspended)
        XCTAssertEqual(try machine.handle(.controlGranted), .controlling)
        XCTAssertEqual(try machine.handle(.stopControl), .connected)
    }

    func testDisconnectAlwaysReturnsToSafeState() throws {
        var machine = ControlSessionStateMachine(state: .controlling)

        XCTAssertEqual(
            try machine.handle(.transportDisconnected),
            .disconnected
        )
        XCTAssertThrowsError(try machine.handle(.resume))
        XCTAssertEqual(try machine.handle(.transportConnected), .connected)
    }
}
