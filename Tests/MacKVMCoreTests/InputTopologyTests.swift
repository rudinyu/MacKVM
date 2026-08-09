import XCTest
@testable import MacKVMCore

final class InputTopologyTests: XCTestCase {
    func testRecommendedTopologyOnlyAllowsAppleSiliconToInitiate() {
        XCTAssertTrue(
            InputTopologyPolicy.allowsLocalControl(
                mode: .singleHostOnM5Pro,
                isAppleSilicon: true
            )
        )
        XCTAssertFalse(
            InputTopologyPolicy.allowsLocalControl(
                mode: .singleHostOnM5Pro,
                isAppleSilicon: false
            )
        )
    }

    func testExternalUsbSwitchAllowsBothArchitectures() {
        XCTAssertTrue(
            InputTopologyPolicy.allowsLocalControl(
                mode: .externalUsbSwitch,
                isAppleSilicon: true
            )
        )
        XCTAssertTrue(
            InputTopologyPolicy.allowsLocalControl(
                mode: .externalUsbSwitch,
                isAppleSilicon: false
            )
        )
    }
}
