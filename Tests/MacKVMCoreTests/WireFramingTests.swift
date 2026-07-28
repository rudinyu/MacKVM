import Foundation
import XCTest
@testable import MacKVMCore

final class WireFramingTests: XCTestCase {
    func testDecodesCompleteFramesAndRetainsPartialFrame() throws {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let firstFrame = try LengthPrefixedFrameCodec.encode(first)
        let secondFrame = try LengthPrefixedFrameCodec.encode(second)
        let split = secondFrame.count / 2
        var buffer = firstFrame + secondFrame[..<split]

        XCTAssertEqual(
            try LengthPrefixedFrameCodec.decodeAvailablePayloads(from: &buffer),
            [first]
        )

        buffer.append(secondFrame[split...])
        XCTAssertEqual(
            try LengthPrefixedFrameCodec.decodeAvailablePayloads(from: &buffer),
            [second]
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testRejectsZeroLengthFrame() {
        var buffer = Data(repeating: 0, count: 4)

        XCTAssertThrowsError(
            try LengthPrefixedFrameCodec.decodeAvailablePayloads(from: &buffer)
        ) { error in
            XCTAssertEqual(
                error as? LengthPrefixedFrameError,
                .invalidLength
            )
        }
    }

    func testRejectsOversizedPayload() {
        let payload = Data(
            repeating: 0,
            count: LengthPrefixedFrameCodec.maximumPayloadLength + 1
        )

        XCTAssertThrowsError(try LengthPrefixedFrameCodec.encode(payload)) {
            error in
            XCTAssertEqual(
                error as? LengthPrefixedFrameError,
                .invalidLength
            )
        }
    }
}
