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

    func testCapturedFixedPointFieldIsDecodedFromSignedSixteenSixteen() {
        XCTAssertEqual(
            ScrollEventEncoding.decodedFixedPointDelta(24_576),
            0.375,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            ScrollEventEncoding.decodedFixedPointDelta(-81_920),
            -1.25,
            accuracy: 0.000001
        )
    }

    func testScrollStreamStateTerminatesTouchAndMomentumIndependently() {
        var state = ScrollStreamState()
        state.observe(
            RemoteInputEvent(
                kind: .scroll,
                modifierFlags: UInt64(CGEventFlags.maskShift.rawValue),
                scrollDeltaX: 0.25,
                scrollDeltaY: 0.5,
                scrollPhase: .began,
                scrollEventUnit: .pixel
            )
        )
        XCTAssertTrue(state.needsTermination)
        XCTAssertTrue(state.hasActiveScrollPhase)
        XCTAssertFalse(state.hasActiveMomentumPhase)

        state.observe(
            RemoteInputEvent(
                kind: .scroll,
                scrollDeltaX: 0,
                scrollDeltaY: 0,
                scrollPhase: .ended,
                scrollMomentumPhase: .begin,
                scrollEventUnit: .pixel
            )
        )
        XCTAssertTrue(state.needsTermination)
        XCTAssertFalse(state.hasActiveScrollPhase)
        XCTAssertTrue(state.hasActiveMomentumPhase)

        state.observe(
            RemoteInputEvent(
                kind: .scroll,
                scrollDeltaX: 0,
                scrollDeltaY: 0,
                scrollMomentumPhase: .end,
                scrollEventUnit: .pixel
            )
        )
        XCTAssertFalse(state.needsTermination)
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

    func testBothAxesShareOneResolvedScrollUnit() {
        // A tilt-wheel event whose vertical axis is empty resolves the
        // vertical axis to the line default while the horizontal axis falls
        // back to its pixel point delta. The wire format carries one unit, so
        // sending the horizontal delta under the vertical axis' unit would
        // scroll sideways by lines instead of pixels.
        let tiltOnly = ScrollEventEncoding.capturedScrollEvent(
            isContinuous: false,
            horizontal: (fixedPoint: 0, point: 4, legacy: 0),
            vertical: (fixedPoint: 0, point: 0, legacy: 0)
        )
        XCTAssertEqual(tiltOnly.unit, .pixel)
        XCTAssertEqual(tiltOnly.horizontal, 4)
        XCTAssertEqual(tiltOnly.vertical, 0)

        // The mirror case: the dominant vertical axis keeps its line unit and
        // the disagreeing horizontal axis is re-read from its line field.
        let wheelWithTilt = ScrollEventEncoding.capturedScrollEvent(
            isContinuous: false,
            horizontal: (fixedPoint: 0, point: 4, legacy: 0),
            vertical: (fixedPoint: 0, point: 0, legacy: -6)
        )
        XCTAssertEqual(wheelWithTilt.unit, .line)
        XCTAssertEqual(wheelWithTilt.vertical, -6)
        XCTAssertEqual(wheelWithTilt.horizontal, 0)
    }

    func testAgreeingAxesKeepBothDeltas() {
        let captured = ScrollEventEncoding.capturedScrollEvent(
            isContinuous: true,
            horizontal: (fixedPoint: 0.5, point: 1, legacy: 0),
            vertical: (fixedPoint: -1.25, point: -1, legacy: 0)
        )
        XCTAssertEqual(captured.unit, .pixel)
        XCTAssertEqual(captured.horizontal, 0.5)
        XCTAssertEqual(captured.vertical, -1.25)
    }
}
