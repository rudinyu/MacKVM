import XCTest
@testable import MacKVMCore

final class MonitorRoutingTests: XCTestCase {
    func testInputSourceUsesStandardVCPValues() {
        XCTAssertEqual(MonitorInputSource.displayPort1.rawValue, 15)
        XCTAssertEqual(MonitorInputSource.hdmi1.rawValue, 17)
        XCTAssertEqual(MonitorInputSource.hdmi2.rawValue, 18)
        XCTAssertEqual(MonitorInputSource.usbC.rawValue, 27)
    }

    func testCommandTargetsSelectedDisplay() {
        XCTAssertEqual(
            M1DDCCommand.arguments(
                displaySelector: "1",
                input: .usbC
            ),
            ["display", "1", "set", "input", "27"]
        )
    }

    func testBlankSelectorUsesDefaultDisplay() {
        XCTAssertEqual(
            M1DDCCommand.arguments(
                displaySelector: "  ",
                input: .hdmi1
            ),
            ["set", "input", "17"]
        )
    }
}
