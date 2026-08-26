import MacKVMCore
import XCTest
@testable import MacKVM

final class TrackpadScrollTests: XCTestCase {
    func testCapturePrefersFractionalFixedPointDelta() {
        let captured = ScrollEventEncoding.capturedScroll(
            isContinuous: true,
            fixedPoint: 0.375,
            point: 0,
            legacy: 1
        )
        XCTAssertEqual(captured.delta, 0.375)
        XCTAssertEqual(captured.unit, .pixel)
    }

    func testCaptureFallsBackForLegacyScrollEvents() {
        let lineEvent = ScrollEventEncoding.capturedScroll(
            isContinuous: false,
            fixedPoint: 0,
            point: 4,
            legacy: 2
        )
        XCTAssertEqual(lineEvent.delta, 2)
        XCTAssertEqual(lineEvent.unit, .line)

        let continuousEvent = ScrollEventEncoding.capturedScroll(
            isContinuous: true,
            fixedPoint: 0,
            point: 0,
            legacy: -3
        )
        XCTAssertEqual(continuousEvent.delta, -3)
        XCTAssertEqual(continuousEvent.unit, .pixel)
    }

    func testCaptureLabelsPointFallbackAsPixelsWhenLineDeltaIsMissing() {
        let captured = ScrollEventEncoding.capturedScroll(
            isContinuous: false,
            fixedPoint: 0,
            point: 4,
            legacy: 0
        )
        XCTAssertEqual(captured.delta, 4)
        XCTAssertEqual(captured.unit, .pixel)
    }

    func testCapturePreservesContinuousVersusLineUnit() {
        XCTAssertEqual(
            ScrollEventEncoding.capturedScroll(
                isContinuous: true,
                fixedPoint: 0,
                point: 0,
                legacy: 0
            ).unit,
            .pixel
        )
        XCTAssertEqual(
            ScrollEventEncoding.capturedScroll(
                isContinuous: false,
                fixedPoint: 0,
                point: 0,
                legacy: 0
            ).unit,
            .line
        )
    }

    func testFixedPointConversionPreservesTrackpadPrecision() {
        XCTAssertEqual(
            ScrollEventEncoding.fixedPointValue(1.5),
            98_304
        )
        XCTAssertEqual(
            ScrollEventEncoding.fixedPointValue(-0.375),
            -24_576
        )
    }

    func testTrackpadPressureIsForwardedOnlyWhenPresent() {
        XCTAssertEqual(
            RemoteInputEvent(
                kind: .leftMouseDown,
                location: NormalizedPoint(x: 0.2, y: 0.3),
                buttonNumber: 0,
                clickCount: 1,
                pressure: 0.8
            ).pressure,
            0.8
        )
        XCTAssertNil(
            RemoteInputEvent(
                kind: .leftMouseDown,
                location: NormalizedPoint(x: 0.2, y: 0.3),
                buttonNumber: 0,
                clickCount: 1
            ).pressure
        )
    }
}
