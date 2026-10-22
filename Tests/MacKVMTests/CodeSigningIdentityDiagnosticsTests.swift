import Foundation
import XCTest
@testable import MacKVM

final class CodeSigningIdentityDiagnosticsTests: XCTestCase {
    func testBinaryRebuildWithSameSigningIdentityIsReportedSeparately() throws {
        try withDefaults { defaults in
            let first = identity(cdhash: "001122")
            let firstSnapshot = CodeSigningIdentityDiagnosticStore.record(
                .success(first),
                defaults: defaults
            )
            XCTAssertEqual(firstSnapshot.current, first)
            XCTAssertNil(firstSnapshot.previous)
            XCTAssertNil(firstSnapshot.identityChanged)
            XCTAssertEqual(
                firstSnapshot.changeDescription,
                "Unknown or first observation"
            )

            let rebuilt = identity(cdhash: "aabbcc")
            let rebuiltSnapshot = CodeSigningIdentityDiagnosticStore.record(
                .success(rebuilt),
                defaults: defaults
            )

            XCTAssertEqual(rebuiltSnapshot.current, rebuilt)
            XCTAssertEqual(rebuiltSnapshot.previous, first)
            XCTAssertEqual(rebuiltSnapshot.binaryChanged, true)
            XCTAssertEqual(rebuiltSnapshot.teamChanged, false)
            XCTAssertEqual(rebuiltSnapshot.signingIdentifierChanged, false)
            XCTAssertEqual(rebuiltSnapshot.requirementChanged, false)
            XCTAssertEqual(rebuiltSnapshot.certificateChanged, false)
            XCTAssertEqual(rebuiltSnapshot.identityChanged, false)
            XCTAssertEqual(
                rebuiltSnapshot.changeDescription,
                "Binary rebuilt; signing identity unchanged"
            )

            XCTAssertTrue(defaults.bool(forKey: CodeSigningIdentityDiagnosticStore.binaryChangedKey))
            XCTAssertFalse(defaults.bool(forKey: CodeSigningIdentityDiagnosticStore.teamChangedKey))
            XCTAssertTrue(defaults.bool(forKey: CodeSigningIdentityDiagnosticStore.identityChangedKey))
            XCTAssertTrue(
                defaults.bool(
                    forKey: CodeSigningIdentityDiagnosticStore
                        .identityComparisonAvailableKey
                )
            )
        }
    }

    func testTeamRequirementAndCertificateChangesAreReported() throws {
        let original = identity(cdhash: "001122")
        try assertIdentityChanged(
            from: original,
            to: identity(cdhash: "001122", teamIdentifier: "OTHERTEAM"),
            expectedField: .team
        )
        try assertIdentityChanged(
            from: original,
            to: identity(
                cdhash: "001122",
                designatedRequirement: "identifier \"com.example.other\""
            ),
            expectedField: .requirement
        )
        try assertIdentityChanged(
            from: original,
            to: identity(cdhash: "001122", certificate: "certificate-b"),
            expectedField: .certificate
        )
    }

    func testLegacyRecordWithoutNewFieldsComparesThoseFieldsAsUnknown() throws {
        try withDefaults { defaults in
            // These are the keys written before the signing detail fields were
            // added. Their absence must not be treated as a changed identity.
            defaults.set("old-cdhash", forKey: CodeSigningIdentityDiagnosticStore.currentCDHashKey)
            defaults.set("TEAM123", forKey: CodeSigningIdentityDiagnosticStore.currentTeamIDKey)

            let snapshot = CodeSigningIdentityDiagnosticStore.record(
                .success(identity(cdhash: "new-cdhash")),
                defaults: defaults
            )

            XCTAssertEqual(snapshot.binaryChanged, true)
            XCTAssertEqual(snapshot.teamChanged, false)
            XCTAssertNil(snapshot.signingIdentifierChanged)
            XCTAssertNil(snapshot.requirementChanged)
            XCTAssertNil(snapshot.certificateChanged)
            XCTAssertNil(snapshot.identityChanged)
            XCTAssertEqual(
                snapshot.changeDescription,
                "Binary rebuilt; signing identity unknown"
            )
        }
    }

    func testLegacyBuildOverwriteCannotReuseMetadataFromDifferentCDHash() throws {
        try withDefaults { defaults in
            let build101Identity = identity(cdhash: "build-101-cdhash")
            _ = CodeSigningIdentityDiagnosticStore.record(
                .success(build101Identity),
                defaults: defaults
            )
            XCTAssertEqual(
                defaults.string(
                    forKey: CodeSigningIdentityDiagnosticStore
                        .currentMetadataCDHashKey
                ),
                "build-101-cdhash"
            )

            // Simulate build 100, which updates only the legacy values and
            // leaves build 101's detailed fields and markers behind.
            defaults.set(
                "build-100-cdhash",
                forKey: CodeSigningIdentityDiagnosticStore.currentCDHashKey
            )
            defaults.set(
                "TEAM123",
                forKey: CodeSigningIdentityDiagnosticStore.currentTeamIDKey
            )

            let snapshot = CodeSigningIdentityDiagnosticStore.record(
                .success(build101Identity),
                defaults: defaults
            )

            XCTAssertEqual(snapshot.previous?.cdhash, "build-100-cdhash")
            XCTAssertEqual(snapshot.previous?.teamIdentifier, "TEAM123")
            XCTAssertFalse(snapshot.previous?.signingIdentifierWasRead ?? true)
            XCTAssertFalse(snapshot.previous?.designatedRequirementWasRead ?? true)
            XCTAssertFalse(snapshot.previous?.leafCertificateWasRead ?? true)
            XCTAssertNil(snapshot.previous?.signingIdentifier)
            XCTAssertNil(snapshot.previous?.designatedRequirement)
            XCTAssertNil(snapshot.previous?.leafCertificateSHA256)
            XCTAssertNil(snapshot.previous?.isAdHoc)
            XCTAssertEqual(snapshot.binaryChanged, true)
            XCTAssertEqual(snapshot.teamChanged, false)
            XCTAssertNil(snapshot.signingIdentifierChanged)
            XCTAssertNil(snapshot.requirementChanged)
            XCTAssertNil(snapshot.certificateChanged)
            XCTAssertNil(snapshot.identityChanged)
            XCTAssertEqual(
                snapshot.changeDescription,
                "Binary rebuilt; signing identity unknown"
            )
        }
    }

    func testFailedFieldReadRemainsUnknownInsteadOfClaimingIdentityChange() throws {
        try withDefaults { defaults in
            let previous = identity(cdhash: "001122")
            _ = CodeSigningIdentityDiagnosticStore.record(
                .success(previous),
                defaults: defaults
            )

            let current = CodeSigningIdentity(
                cdhash: previous.cdhash,
                teamIdentifier: previous.teamIdentifier,
                signingIdentifier: previous.signingIdentifier,
                designatedRequirement: nil,
                leafCertificateSHA256: previous.leafCertificateSHA256,
                isAdHoc: false,
                designatedRequirementWasRead: false
            )
            let snapshot = CodeSigningIdentityDiagnosticStore.record(
                .success(current),
                defaults: defaults
            )

            XCTAssertNil(snapshot.requirementChanged)
            XCTAssertNil(snapshot.identityChanged)
            XCTAssertEqual(
                snapshot.changeDescription,
                "Binary unchanged; signing identity unknown"
            )
        }
    }

    func testAdHocCertificateAbsenceIsKnownAndCdHashRequirementIsNotCompared() throws {
        try withDefaults { defaults in
            let first = CodeSigningIdentity(
                cdhash: "001122",
                teamIdentifier: nil,
                signingIdentifier: "com.example.mackvm",
                designatedRequirement: "identifier \"com.example.mackvm\" and cdhash H\"001122\"",
                leafCertificateSHA256: nil,
                isAdHoc: true
            )
            _ = CodeSigningIdentityDiagnosticStore.record(
                .success(first),
                defaults: defaults
            )

            let rebuilt = CodeSigningIdentity(
                cdhash: "aabbcc",
                teamIdentifier: nil,
                signingIdentifier: "com.example.mackvm",
                designatedRequirement: "identifier \"com.example.mackvm\" and cdhash H\"aabbcc\"",
                leafCertificateSHA256: nil,
                isAdHoc: true
            )
            let snapshot = CodeSigningIdentityDiagnosticStore.record(
                .success(rebuilt),
                defaults: defaults
            )

            XCTAssertEqual(snapshot.binaryChanged, true)
            XCTAssertEqual(snapshot.teamChanged, false)
            XCTAssertEqual(snapshot.signingIdentifierChanged, false)
            XCTAssertNil(snapshot.requirementChanged)
            XCTAssertEqual(snapshot.certificateChanged, false)
            XCTAssertEqual(snapshot.identityChanged, false)
            XCTAssertEqual(
                snapshot.changeDescription,
                "Binary rebuilt; signing identity unchanged"
            )
            XCTAssertTrue(rebuilt.supportDescription.contains("Signature=Ad-hoc"))
            XCTAssertTrue(
                rebuilt.supportDescription.contains(
                    "Requirement=Ad-hoc cdhash-based"
                )
            )
            XCTAssertTrue(
                snapshot.comparisons.supportDescription.contains(
                    "requirement=Ad-hoc cdhash-based (not compared)"
                )
            )
        }
    }

    func testReadFailurePreservesLastSuccessfulIdentityForNextComparison() throws {
        try withDefaults { defaults in
            let previous = identity(cdhash: "001122")
            _ = CodeSigningIdentityDiagnosticStore.record(
                .success(previous),
                defaults: defaults
            )

            let error = CodeSigningDiagnosticError(
                domain: "Security",
                code: -1,
                detail: "test read failure"
            )
            let failedSnapshot = CodeSigningIdentityDiagnosticStore.record(
                .failure(error),
                defaults: defaults
            )
            XCTAssertNil(failedSnapshot.current)
            XCTAssertEqual(failedSnapshot.previous, previous)
            XCTAssertEqual(failedSnapshot.error, error)
            XCTAssertFalse(
                defaults.bool(
                    forKey: CodeSigningIdentityDiagnosticStore
                        .identityComparisonAvailableKey
                )
            )

            let nextSnapshot = CodeSigningIdentityDiagnosticStore.record(
                .success(previous),
                defaults: defaults
            )
            XCTAssertEqual(nextSnapshot.previous, previous)
            XCTAssertEqual(nextSnapshot.binaryChanged, false)
            XCTAssertEqual(nextSnapshot.identityChanged, false)
        }
    }

    func testCurrentProcessSigningReadReturnsIdentityOrExplicitDiagnostic() {
        switch CodeSigningIdentityReader.readCurrentProcess() {
        case let .success(identity):
            XCTAssertFalse(identity.cdhash.isEmpty)
            XCTAssertFalse(identity.cdhash.contains { $0.isWhitespace })
            XCTAssertFalse(identity.supportDescription.contains("\n"))
        case let .failure(error):
            XCTAssertFalse(error.domain.isEmpty)
            XCTAssertFalse(error.detail.isEmpty)
        }
    }

    private enum ComparedField {
        case team
        case requirement
        case certificate
    }

    private func assertIdentityChanged(
        from previous: CodeSigningIdentity,
        to current: CodeSigningIdentity,
        expectedField: ComparedField,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try withDefaults { defaults in
            _ = CodeSigningIdentityDiagnosticStore.record(
                .success(previous),
                defaults: defaults
            )
            let snapshot = CodeSigningIdentityDiagnosticStore.record(
                .success(current),
                defaults: defaults
            )

            XCTAssertEqual(snapshot.identityChanged, true, file: file, line: line)
            XCTAssertEqual(
                snapshot.changeDescription,
                "Signing identity changed (\(expectedFieldDescription(expectedField)))",
                file: file,
                line: line
            )
            switch expectedField {
            case .team:
                XCTAssertEqual(snapshot.teamChanged, true, file: file, line: line)
            case .requirement:
                XCTAssertEqual(snapshot.requirementChanged, true, file: file, line: line)
            case .certificate:
                XCTAssertEqual(snapshot.certificateChanged, true, file: file, line: line)
            }
        }
    }

    private func expectedFieldDescription(_ field: ComparedField) -> String {
        switch field {
        case .team: "Team ID"
        case .requirement: "designated requirement"
        case .certificate: "signing certificate"
        }
    }

    private func identity(
        cdhash: String,
        teamIdentifier: String = "TEAM123",
        signingIdentifier: String = "com.example.mackvm",
        designatedRequirement: String = "identifier \"com.example.mackvm\" and anchor apple generic",
        certificate: String = "certificate-a"
    ) -> CodeSigningIdentity {
        CodeSigningIdentity(
            cdhash: cdhash,
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier,
            designatedRequirement: designatedRequirement,
            leafCertificateSHA256: certificate,
            isAdHoc: false
        )
    }

    private func withDefaults(
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let suiteName = "CodeSigningIdentityDiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
