import Foundation
import XCTest
@testable import MacKVM

final class SupportInformationTests: XCTestCase {
    func testFormatsLocalAndPairedMetadataWithoutPrivateMaterial() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let firstFingerprint = String(repeating: "AA:", count: 31) + "AA"
        let secondFingerprint = String(repeating: "BB:", count: 31) + "BB"
        let output = SupportInformationFormatter.make(
            appVersion: "0.7.0",
            appBuild: "12",
            operatingSystem: "macOS 15.6",
            localFriendlyName: "Office Mac",
            localModel: "MacBookPro18,3",
            localKeyFingerprint: firstFingerprint,
            peers: [
                SupportPeerInfo(
                    peerID: secondID,
                    friendlyName: "Beta Mac",
                    model: "MacBookPro17,1",
                    lastConnectedAt: nil,
                    keyFingerprint: secondFingerprint
                ),
                SupportPeerInfo(
                    peerID: firstID,
                    friendlyName: "Alpha Mac",
                    model: "MacBookPro18,3",
                    lastConnectedAt: Date(timeIntervalSince1970: 0),
                    keyFingerprint: firstFingerprint
                )
            ],
            connectionStatus: "Secure session connected",
            connectedPeerID: firstID
        )

        XCTAssertTrue(output.contains("MacKVM Support Information"))
        XCTAssertTrue(output.contains("Office Mac"))
        XCTAssertTrue(output.contains("MacBookPro18,3"))
        XCTAssertTrue(output.contains(firstFingerprint))
        XCTAssertTrue(output.contains("Last connected: 1970-01-01T00:00:00Z"))
        XCTAssertTrue(output.contains("Last connected: Never"))
        XCTAssertTrue(output.contains(firstID.uuidString))
        XCTAssertTrue(output.contains("Secure session connected"))
        XCTAssertLessThan(
            output.range(of: "Alpha Mac")!.lowerBound,
            output.range(of: "Beta Mac")!.lowerBound
        )
        XCTAssertFalse(output.contains("private-key"))
    }

    func testSanitizesLineBreaksInSupportFields() {
        let output = SupportInformationFormatter.make(
            appVersion: "0.7.0",
            appBuild: "12",
            operatingSystem: "macOS\n15.6",
            localFriendlyName: "Office\rMac",
            localModel: "MacBookPro18,3",
            localKeyFingerprint: "AA",
            peers: [],
            connectionStatus: "Idle\nready",
            connectedPeerID: nil
        )

        XCTAssertTrue(output.contains("Operating system: macOS 15.6"))
        XCTAssertTrue(output.contains("Friendly name: Office Mac"))
        XCTAssertTrue(output.contains("Status: Idle ready"))
        XCTAssertFalse(output.contains("macOS\n15.6"))
    }
}
