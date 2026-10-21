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

    func testDisplayRouteOwnershipRoundTripsAndDefaultsToLegacyWhenAbsent() throws {
        for ownership in [nil, true, false] as [Bool?] {
            let message = ControlMessage.requestControl(
                requestID: UUID(),
                managesDisplayRoute: ownership
            )
            let decoded = try ControlMessageCodec.decode(
                ControlMessageCodec.encode(message)
            )

            XCTAssertEqual(decoded.managesDisplayRoute, ownership)
        }

        let legacy = ControlMessage(kind: .requestControl, requestID: UUID())
        XCTAssertNil(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(legacy)
            ).managesDisplayRoute
        )
    }

    func testDisplayRouteOwnershipIsRequestOnly() {
        for kind in [ControlMessageKind.input, .controlGranted, .controlDenied, .endControl] {
            let message = ControlMessage(
                kind: kind,
                requestID: UUID(),
                input: kind == .input
                    ? RemoteInputEvent(kind: .keyUp, keyCode: 12) : nil,
                managesDisplayRoute: false
            )

            XCTAssertThrowsError(try message.validated()) { error in
                XCTAssertEqual(error as? ControlProtocolError, .invalidFields)
            }
        }
    }

    func testClipboardCapabilityNegotiationIsOptionalAndComplete() throws {
        let requestID = UUID()
        let request = ControlMessage.requestControl(
            requestID: requestID,
            clipboardEnabled: true
        )
        let decodedRequest = try ControlMessageCodec.decode(
            ControlMessageCodec.encode(request)
        )
        XCTAssertEqual(decodedRequest.supportsClipboard, true)
        XCTAssertEqual(decodedRequest.clipboardEnabled, true)

        let legacy = ControlMessage(kind: .requestControl, requestID: requestID)
        let decodedLegacy = try ControlMessageCodec.decode(
            ControlMessageCodec.encode(legacy)
        )
        XCTAssertNil(decodedLegacy.supportsClipboard)
        XCTAssertNil(decodedLegacy.clipboardEnabled)

        let grant = ControlMessage.controlGranted(
            requestID: requestID,
            clipboardEnabled: false
        )
        let decodedGrant = try ControlMessageCodec.decode(
            ControlMessageCodec.encode(grant)
        )
        XCTAssertEqual(decodedGrant.supportsClipboard, true)
        XCTAssertEqual(decodedGrant.clipboardEnabled, false)

        for malformed in [
            ControlMessage(
                kind: .requestControl,
                requestID: requestID,
                supportsClipboard: true
            ),
            ControlMessage(
                kind: .controlGranted,
                requestID: requestID,
                supportsClipboard: false,
                clipboardEnabled: true
            ),
            ControlMessage(
                kind: .endControl,
                requestID: requestID,
                supportsClipboard: true,
                clipboardEnabled: false
            )
        ] {
            XCTAssertThrowsError(try malformed.validated())
        }
    }

    func testClipboardTextRoundTripsInsideControlMessage() throws {
        let requestID = UUID()
        let message = ControlMessage.clipboard(
            "plain text\n你好",
            requestID: requestID
        )

        let payload = try ControlMessageCodec.encode(message)
        let decoded = try ControlMessageCodec.decode(payload)

        XCTAssertLessThanOrEqual(payload.count, ControlMessageCodec.maximumPayloadLength)
        XCTAssertEqual(decoded.kind, .clipboard)
        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.clipboardText, "plain text\n你好")
    }

    func testClipboardPayloadEnforcesTextAndWholeEnvelopeLimits() {
        let requestID = UUID()
        let maximumText = String(
            repeating: "x",
            count: ControlMessageCodec.maximumClipboardUTF8Length
        )
        XCTAssertNoThrow(
            try ControlMessage.clipboard(maximumText, requestID: requestID)
                .validated()
        )
        XCTAssertThrowsError(
            try ControlMessageCodec.encode(
                .clipboard(maximumText, requestID: requestID)
            )
        ) { error in
            XCTAssertEqual(error as? ControlProtocolError, .payloadTooLarge)
        }

        let oversizedText = maximumText + "x"
        XCTAssertThrowsError(
            try ControlMessage.clipboard(oversizedText, requestID: requestID)
                .validated()
        ) { error in
            XCTAssertEqual(error as? ControlProtocolError, .invalidFields)
        }
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
