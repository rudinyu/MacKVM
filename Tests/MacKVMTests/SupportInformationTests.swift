import Foundation
import Network
import XCTest
@testable import MacKVM

final class SupportInformationTests: XCTestCase {
    func testFormatsLocalAndPairedMetadataWithoutPrivateMaterial() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let firstFingerprint = String(repeating: "AA:", count: 31) + "AA"
        let secondFingerprint = String(repeating: "BB:", count: 31) + "BB"
        let output = SupportInformationFormatter.make(
            appVersion: "0.7.1",
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
            appVersion: "0.7.1",
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

    func testIncludesAuthoritativeNetworkAndSigningDiagnostics() {
        let current = CodeSigningIdentity(
            cdhash: "a1b2c3",
            teamIdentifier: "TEAM123",
            signingIdentifier: "com.example\nmackvm",
            designatedRequirement: "identifier \"com.example.mackvm\" and anchor apple generic",
            leafCertificateSHA256: "certificate-a",
            isAdHoc: false
        )
        let previous = CodeSigningIdentity(
            cdhash: "010203",
            teamIdentifier: "TEAM123",
            signingIdentifier: "com.example.mackvm",
            designatedRequirement: "identifier \"com.example.mackvm\" and anchor apple generic",
            leafCertificateSHA256: "certificate-a",
            isAdHoc: false
        )
        let signing = CodeSigningIdentityDiagnostics(
            current: current,
            previous: previous,
            comparisons: CodeSigningIdentityComparisons(
                binaryChanged: true,
                teamChanged: false,
                signingIdentifierChanged: false,
                requirementChanged: false,
                certificateChanged: false
            ),
            error: nil
        )
        let browserError = NetworkServiceErrorDiagnostic(
            component: .browser,
            state: "waiting",
            domain: "Network.NWError",
            code: Int(kDNSServiceErr_PolicyDenied)
        )
        let listenerError = NetworkServiceErrorDiagnostic(
            component: .listener,
            state: "failed",
            domain: "Network.NWError",
            code: 57
        )

        let output = SupportInformationFormatter.make(
            appVersion: "1.102.03",
            appBuild: "100",
            operatingSystem: "macOS 27",
            localFriendlyName: "Office Mac",
            localModel: "MacBookPro18,3",
            localKeyFingerprint: "AA",
            peers: [],
            connectionStatus: "Idle",
            connectedPeerID: nil,
            localNetworkStatus: .blocked,
            lastBrowserError: browserError,
            lastListenerError: listenerError,
            signingIdentity: signing
        )

        XCTAssertTrue(output.contains("App: 1.102.03 (build 100)"))
        XCTAssertTrue(
            output.contains("Status: Local Network access blocked by macOS")
        )
        XCTAssertTrue(
            output.contains(
                "Last browser error: state=waiting domain=Network.NWError code=\(kDNSServiceErr_PolicyDenied)"
            )
        )
        XCTAssertTrue(output.contains("state=failed domain=Network.NWError code=57"))
        XCTAssertTrue(
            output.contains(
                "Current identity: CDHash=a1b2c3 TeamID=TEAM123 SigningIdentifier=com.example mackvm"
            )
        )
        XCTAssertTrue(
            output.contains(
                "Previous identity: CDHash=010203 TeamID=TEAM123 SigningIdentifier=com.example.mackvm"
            )
        )
        XCTAssertTrue(
            output.contains(
                "Summary: Binary rebuilt; signing identity unchanged"
            )
        )
        XCTAssertTrue(
            output.contains(
                "Comparison: binary=Changed team=Unchanged signingIdentifier=Unchanged requirement=Unchanged certificate=Unchanged"
            )
        )
        XCTAssertFalse(output.contains("com.example\nmackvm"))
        XCTAssertFalse(output.contains("private-key"))
    }
}
