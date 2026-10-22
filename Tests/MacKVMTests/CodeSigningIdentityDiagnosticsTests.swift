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

    func testSigningLogMessagesAreBoundedForDeveloperIDRequirement() throws {
        let requirement = "identifier \"app.mackvm.MacKVM\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = LYK4LV2859"
        let current = identity(
            cdhash: "0123456789abcdef0123456789abcdef01234567",
            designatedRequirement: requirement,
            certificate: String(repeating: "a", count: 64)
        )
        let previous = identity(
            cdhash: "76543210fedcba9876543210fedcba9876543210",
            designatedRequirement: requirement,
            certificate: String(repeating: "b", count: 64)
        )
        let diagnostics = CodeSigningIdentityDiagnostics(
            current: current,
            previous: previous,
            comparisons: CodeSigningIdentityComparisons(
                binaryChanged: true,
                teamChanged: false,
                signingIdentifierChanged: false,
                requirementChanged: false,
                certificateChanged: true
            ),
            error: nil
        )

        let messages = CodeSigningIdentityDiagnosticLogMessageComposer.messages(
            for: diagnostics
        )
        XCTAssertFalse(messages.isEmpty)
        XCTAssertTrue(messages.allSatisfy { $0.utf8.count < 900 })

        let summary = try XCTUnwrap(messages.first)
        XCTAssertTrue(summary.hasPrefix("phase=signing-identity.summary "))
        for field in [
            "binary=Changed",
            "team=Unchanged",
            "signingIdentifier=Unchanged",
            "requirement=Unchanged",
            "certificate=Changed"
        ] {
            XCTAssertTrue(summary.contains(field), "Missing comparison field: \(field)")
        }

        let currentMetadata = try XCTUnwrap(
            messages.first { $0.hasPrefix("phase=signing-identity.current ") }
        )
        XCTAssertTrue(currentMetadata.contains("CDHash="))
        XCTAssertTrue(currentMetadata.contains("TeamID="))
        XCTAssertTrue(currentMetadata.contains("SigningIdentifier="))
        XCTAssertTrue(currentMetadata.contains("CertificateSHA256="))
        XCTAssertTrue(currentMetadata.contains("Signature=Identified"))
        XCTAssertFalse(currentMetadata.contains("Requirement="))

        XCTAssertTrue(
            messages.contains(
                "phase=signing-identity.requirement current=\(requirement)"
            )
        )
    }

    func testPreviousLogContainsOnlyChangedFields() throws {
        let previous = identity(
            cdhash: "old-cdhash",
            teamIdentifier: "TEAM123",
            signingIdentifier: "com.example.mackvm",
            designatedRequirement: "identifier \"com.example.mackvm\" and anchor apple generic",
            certificate: "same-certificate"
        )
        let current = identity(
            cdhash: "new-cdhash",
            teamIdentifier: "TEAM123",
            signingIdentifier: "com.example.mackvm",
            designatedRequirement: "identifier \"com.example.mackvm\" and anchor apple generic",
            certificate: "same-certificate"
        )
        let diagnostics = CodeSigningIdentityDiagnostics(
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

        let messages = CodeSigningIdentityDiagnosticLogMessageComposer.messages(
            for: diagnostics
        )
        let previousMessages = messages.filter {
            $0.hasPrefix("phase=signing-identity.previous ")
        }
        XCTAssertEqual(
            previousMessages,
            ["phase=signing-identity.previous CDHash=old-cdhash"]
        )
        XCTAssertFalse(messages.contains { $0.contains("previous=") })
    }

    func testLongUTF8RequirementIsChunkedAtScalarBoundaries() throws {
        let requirement = String(repeating: "🍎", count: 800)
        let diagnostics = CodeSigningIdentityDiagnostics(
            current: identity(cdhash: "current", designatedRequirement: requirement),
            previous: nil,
            comparisons: .unknown,
            error: nil
        )

        let messages = CodeSigningIdentityDiagnosticLogMessageComposer.messages(
            for: diagnostics
        )
        XCTAssertTrue(messages.allSatisfy { $0.utf8.count < 900 })

        let requirementMessages = messages.filter {
            $0.hasPrefix("phase=signing-identity.requirement current=")
        }
        XCTAssertGreaterThan(requirementMessages.count, 1)
        let reconstructed = requirementMessages.compactMap { message -> String? in
            guard let prefixRange = message.range(of: " current=") else {
                return nil
            }
            var payload = String(message[prefixRange.upperBound...])
            if let markerRange = payload.range(of: " [part=") {
                payload = String(payload[..<markerRange.lowerBound])
            }
            return payload
        }.joined()
        XCTAssertEqual(reconstructed, requirement)
        XCTAssertFalse(requirementMessages.contains { $0.contains("�") })
    }

    func testReadFailureKeepsAnErrorSummaryWithoutDumpingPreviousRecord() {
        let previous = identity(cdhash: "old-cdhash")
        let diagnostics = CodeSigningIdentityDiagnostics(
            current: nil,
            previous: previous,
            comparisons: .unknown,
            error: CodeSigningDiagnosticError(
                domain: "Security",
                code: -1,
                detail: String(repeating: "失敗", count: 500)
            )
        )

        let messages = CodeSigningIdentityDiagnosticLogMessageComposer.messages(
            for: diagnostics
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertLessThan(messages[0].utf8.count, 900)
        XCTAssertTrue(messages[0].hasPrefix("phase=signing-identity.summary "))
        XCTAssertTrue(messages[0].contains("error=domain=Security code=-1 detail="))
        XCTAssertTrue(messages[0].contains("... [truncated]"))
        XCTAssertFalse(messages[0].contains("phase=signing-identity.previous"))
        for field in [
            "binary=Unknown",
            "team=Unknown",
            "signingIdentifier=Unknown",
            "requirement=Unknown",
            "certificate=Unknown"
        ] {
            XCTAssertTrue(messages[0].contains(field))
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
