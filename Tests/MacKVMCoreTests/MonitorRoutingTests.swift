import XCTest
@testable import MacKVMCore

final class MonitorRoutingTests: XCTestCase {
    func testInputSourceUsesStandardVCPValues() {
        XCTAssertEqual(MonitorInputSource.displayPort1.rawValue, 15)
        XCTAssertEqual(MonitorInputSource.hdmi1.rawValue, 17)
        XCTAssertEqual(MonitorInputSource.hdmi2.rawValue, 18)
        XCTAssertEqual(MonitorInputSource.usbC.rawValue, 27)
    }

    func testNativeDDCCommandTargetsInputVCP60() {
        XCTAssertEqual(
            NativeDDCCommand.setInputPacket(for: .usbC),
            [0x51, 0x84, 0x03, 0x60, 0x00, 0x1B, 0xC3]
        )
    }

    func testNativeDDCCommandChecksumChangesWithInput() {
        let hdmi = NativeDDCCommand.setInputPacket(for: .hdmi1)
        let displayPort = NativeDDCCommand.setInputPacket(for: .displayPort1)

        XCTAssertEqual(hdmi, [0x51, 0x84, 0x03, 0x60, 0x00, 0x11, 0xC9])
        XCTAssertNotEqual(hdmi.last, displayPort.last)
        XCTAssertEqual(displayPort[5], UInt8(MonitorInputSource.displayPort1.rawValue))
    }
}
