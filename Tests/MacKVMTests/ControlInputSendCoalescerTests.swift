import MacKVMCore
import XCTest
@testable import MacKVM

final class ControlInputSendCoalescerTests: XCTestCase {
    func testConsecutiveMouseMovesKeepOnlyTheNewestPosition() {
        let requestID = UUID()
        var sent: [ControlMessage] = []
        let coalescer = ControlInputSendCoalescer(
            flushInterval: .seconds(10),
            sendMessage: { sent.append($0) }
        )

        coalescer.send(mouseMove(x: 0.1, y: 0.2, requestID: requestID))
        coalescer.send(mouseMove(x: 0.7, y: 0.8, requestID: requestID))
        XCTAssertTrue(sent.isEmpty)

        coalescer.flush()

        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.input?.location, NormalizedPoint(x: 0.7, y: 0.8))
        XCTAssertEqual(sent.first?.requestID, requestID)
    }

    func testNonPointerMessageFlushesMoveBeforeIt() {
        let requestID = UUID()
        var sent: [ControlMessage] = []
        let coalescer = ControlInputSendCoalescer(
            flushInterval: .seconds(10),
            sendMessage: { sent.append($0) }
        )

        coalescer.send(mouseMove(x: 0.3, y: 0.4, requestID: requestID))
        coalescer.send(ControlMessage(kind: .endControl, requestID: requestID))

        XCTAssertEqual(sent.map(\.kind), [.input, .endControl])
        XCTAssertEqual(sent.first?.input?.location, NormalizedPoint(x: 0.3, y: 0.4))
    }

    func testConsecutiveDraggedMovesKeepOnlyTheNewestPosition() {
        let requestID = UUID()
        var sent: [ControlMessage] = []
        let coalescer = ControlInputSendCoalescer(
            flushInterval: .seconds(10),
            sendMessage: { sent.append($0) }
        )

        coalescer.send(draggedMove(x: 0.1, y: 0.2, requestID: requestID))
        coalescer.send(draggedMove(x: 0.8, y: 0.9, requestID: requestID))
        XCTAssertTrue(sent.isEmpty)

        coalescer.send(
            ControlMessage.input(
                RemoteInputEvent(
                    kind: .leftMouseUp,
                    location: NormalizedPoint(x: 0.8, y: 0.9),
                    buttonNumber: 0,
                    clickCount: 1
                ),
                requestID: requestID
            )
        )

        XCTAssertEqual(sent.map(\.kind), [.input, .input])
        XCTAssertEqual(sent.first?.input?.kind, .leftMouseDragged)
        XCTAssertEqual(
            sent.first?.input?.location,
            NormalizedPoint(x: 0.8, y: 0.9)
        )
        XCTAssertEqual(sent.last?.input?.kind, .leftMouseUp)
    }

    func testARequestChangeCannotCoalesceAcrossSessions() {
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        var sent: [ControlMessage] = []
        let coalescer = ControlInputSendCoalescer(
            flushInterval: .seconds(10),
            sendMessage: { sent.append($0) }
        )

        coalescer.send(mouseMove(x: 0.1, y: 0.1, requestID: firstRequestID))
        coalescer.send(mouseMove(x: 0.9, y: 0.9, requestID: secondRequestID))
        coalescer.flush()

        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.map(\.requestID), [firstRequestID, secondRequestID])
    }

    func testAuxiliaryDragsWithDifferentButtonsRemainIndependent() {
        let requestID = UUID()
        var sent: [ControlMessage] = []
        let coalescer = ControlInputSendCoalescer(
            flushInterval: .seconds(10),
            sendMessage: { sent.append($0) }
        )

        coalescer.send(auxiliaryDraggedMove(
            x: 0.1,
            y: 0.2,
            buttonNumber: 2,
            requestID: requestID
        ))
        coalescer.send(auxiliaryDraggedMove(
            x: 0.7,
            y: 0.8,
            buttonNumber: 3,
            requestID: requestID
        ))
        coalescer.flush()

        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.map { $0.input?.buttonNumber }, [2, 3])
    }

    func testResetDropsStalePointerSnapshot() {
        var sent: [ControlMessage] = []
        let coalescer = ControlInputSendCoalescer(
            flushInterval: .seconds(10),
            sendMessage: { sent.append($0) }
        )

        coalescer.send(mouseMove(x: 0.5, y: 0.5, requestID: UUID()))
        coalescer.reset()
        coalescer.flush()

        XCTAssertTrue(sent.isEmpty)
    }

    private func mouseMove(
        x: Double,
        y: Double,
        requestID: UUID
    ) -> ControlMessage {
        ControlMessage.input(
            RemoteInputEvent(
                kind: .mouseMoved,
                location: NormalizedPoint(x: x, y: y)
            ),
            requestID: requestID
        )
    }

    private func draggedMove(
        x: Double,
        y: Double,
        requestID: UUID
    ) -> ControlMessage {
        ControlMessage.input(
            RemoteInputEvent(
                kind: .leftMouseDragged,
                location: NormalizedPoint(x: x, y: y),
                buttonNumber: 0,
                clickCount: 1
            ),
            requestID: requestID
        )
    }

    private func auxiliaryDraggedMove(
        x: Double,
        y: Double,
        buttonNumber: Int,
        requestID: UUID
    ) -> ControlMessage {
        ControlMessage.input(
            RemoteInputEvent(
                kind: .otherMouseDragged,
                location: NormalizedPoint(x: x, y: y),
                buttonNumber: buttonNumber,
                clickCount: 1
            ),
            requestID: requestID
        )
    }
}
