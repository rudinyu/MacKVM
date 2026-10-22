import CryptoKit
import Foundation
import OSLog
import Security

struct CodeSigningIdentity: Equatable, Sendable {
    let cdhash: String
    let teamIdentifier: String?
    let signingIdentifier: String?
    let designatedRequirement: String?
    let leafCertificateSHA256: String?
    /// `nil` means the signature flags were unavailable.
    let isAdHoc: Bool?

    /// These flags distinguish a value that was read as absent from a value
    /// that could not be read. They are also persisted so an ad-hoc
    /// certificate remains a known absence across launches.
    let teamIdentifierWasRead: Bool
    let signingIdentifierWasRead: Bool
    let designatedRequirementWasRead: Bool
    let leafCertificateWasRead: Bool

    init(
        cdhash: String,
        teamIdentifier: String?,
        signingIdentifier: String? = nil,
        designatedRequirement: String? = nil,
        leafCertificateSHA256: String? = nil,
        isAdHoc: Bool? = nil,
        teamIdentifierWasRead: Bool? = nil,
        signingIdentifierWasRead: Bool? = nil,
        designatedRequirementWasRead: Bool? = nil,
        leafCertificateWasRead: Bool? = nil
    ) {
        self.cdhash = cdhash
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.designatedRequirement = designatedRequirement
        self.leafCertificateSHA256 = leafCertificateSHA256
        self.isAdHoc = isAdHoc
        self.teamIdentifierWasRead = teamIdentifierWasRead
            ?? (teamIdentifier != nil || isAdHoc == true)
        self.signingIdentifierWasRead = signingIdentifierWasRead
            ?? (signingIdentifier != nil)
        self.designatedRequirementWasRead = designatedRequirementWasRead
            ?? (designatedRequirement != nil)
        self.leafCertificateWasRead = leafCertificateWasRead
            ?? (leafCertificateSHA256 != nil || isAdHoc == true)
    }

    var supportDescription: String {
        let requirementDescription: String
        if isAdHoc == true {
            let requirement = designatedRequirement.map(Self.singleLine)
                ?? (designatedRequirementWasRead ? "Absent" : "Unavailable")
            requirementDescription = "Ad-hoc cdhash-based \(requirement)"
        } else {
            requirementDescription = fieldDescription(
                designatedRequirement,
                wasRead: designatedRequirementWasRead
            )
        }

        return [
            "CDHash=\(Self.singleLine(cdhash))",
            "TeamID=\(fieldDescription(teamIdentifier, wasRead: teamIdentifierWasRead))",
            "SigningIdentifier=\(fieldDescription(signingIdentifier, wasRead: signingIdentifierWasRead))",
            "Requirement=\(requirementDescription)",
            "CertificateSHA256=\(fieldDescription(leafCertificateSHA256, wasRead: leafCertificateWasRead))",
            "Signature=\(signatureDescription)"
        ].joined(separator: " ")
    }

    var signatureDescription: String {
        guard let isAdHoc else { return "Unknown" }
        return isAdHoc ? "Ad-hoc" : "Identified"
    }

    private func fieldDescription(_ value: String?, wasRead: Bool) -> String {
        guard let value else { return wasRead ? "Absent" : "Unavailable" }
        return Self.singleLine(value)
    }

    private static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct CodeSigningDiagnosticError: Error, Equatable, Sendable {
    let domain: String
    let code: Int?
    let detail: String

    var supportDescription: String {
        "domain=\(domain) code=\(code.map(String.init) ?? "Unknown") detail=\(detail)"
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

struct CodeSigningIdentityComparisons: Equatable, Sendable {
    let binaryChanged: Bool?
    let teamChanged: Bool?
    let signingIdentifierChanged: Bool?
    let requirementChanged: Bool?
    let certificateChanged: Bool?
    let adHocRequirementIgnored: Bool

    init(
        binaryChanged: Bool?,
        teamChanged: Bool?,
        signingIdentifierChanged: Bool?,
        requirementChanged: Bool?,
        certificateChanged: Bool?,
        adHocRequirementIgnored: Bool = false
    ) {
        self.binaryChanged = binaryChanged
        self.teamChanged = teamChanged
        self.signingIdentifierChanged = signingIdentifierChanged
        self.requirementChanged = requirementChanged
        self.certificateChanged = certificateChanged
        self.adHocRequirementIgnored = adHocRequirementIgnored
    }

    static let unknown = CodeSigningIdentityComparisons(
        binaryChanged: nil,
        teamChanged: nil,
        signingIdentifierChanged: nil,
        requirementChanged: nil,
        certificateChanged: nil
    )

    var identityChanged: Bool? {
        let identityFields = [teamChanged, signingIdentifierChanged]
            + (adHocRequirementIgnored ? [] : [requirementChanged])
            + [certificateChanged]
        if identityFields.contains(where: { $0 == true }) {
            return true
        }
        guard identityFields.allSatisfy({ $0 == false }) else {
            return nil
        }
        return false
    }

    var supportDescription: String {
        let requirement = adHocRequirementIgnored
            ? "Ad-hoc cdhash-based (not compared)"
            : Self.fieldDescription(requirementChanged)
        return [
            "binary=\(Self.fieldDescription(binaryChanged))",
            "team=\(Self.fieldDescription(teamChanged))",
            "signingIdentifier=\(Self.fieldDescription(signingIdentifierChanged))",
            "requirement=\(requirement)",
            "certificate=\(Self.fieldDescription(certificateChanged))"
        ].joined(separator: " ")
    }

    private static func fieldDescription(_ changed: Bool?) -> String {
        guard let changed else { return "Unknown" }
        return changed ? "Changed" : "Unchanged"
    }
}

struct CodeSigningIdentityDiagnostics: Equatable, Sendable {
    let current: CodeSigningIdentity?
    let previous: CodeSigningIdentity?
    let comparisons: CodeSigningIdentityComparisons
    let error: CodeSigningDiagnosticError?

    init(
        current: CodeSigningIdentity?,
        previous: CodeSigningIdentity?,
        comparisons: CodeSigningIdentityComparisons,
        error: CodeSigningDiagnosticError?
    ) {
        self.current = current
        self.previous = previous
        self.comparisons = comparisons
        self.error = error
    }

    var binaryChanged: Bool? { comparisons.binaryChanged }
    var teamChanged: Bool? { comparisons.teamChanged }
    var signingIdentifierChanged: Bool? { comparisons.signingIdentifierChanged }
    var requirementChanged: Bool? { comparisons.requirementChanged }
    var certificateChanged: Bool? { comparisons.certificateChanged }

    var identityChanged: Bool? {
        comparisons.identityChanged
    }

    var changeDescription: String {
        guard current != nil, previous != nil else {
            return "Unknown or first observation"
        }

        if identityChanged == true {
            let changedFields = [
                (comparisons.teamChanged == true, "Team ID"),
                (comparisons.signingIdentifierChanged == true, "signing identifier"),
                (
                    !comparisons.adHocRequirementIgnored
                        && comparisons.requirementChanged == true,
                    "designated requirement"
                ),
                (comparisons.certificateChanged == true, "signing certificate")
            ].compactMap { $0.0 ? $0.1 : nil }
            let details = changedFields.isEmpty
                ? ""
                : " (" + changedFields.joined(separator: ", ") + ")"
            return "Signing identity changed\(details)"
        }

        if identityChanged == false {
            if comparisons.binaryChanged == true {
                return "Binary rebuilt; signing identity unchanged"
            }
            if comparisons.binaryChanged == false {
                return "Binary unchanged"
            }
            return "Signing identity unchanged; binary comparison unknown"
        }

        if comparisons.binaryChanged == true {
            return "Binary rebuilt; signing identity unknown"
        }
        if comparisons.binaryChanged == false {
            return "Binary unchanged; signing identity unknown"
        }
        return "Unknown or first observation"
    }

    var supportDescription: String {
        [
            "current=\(current?.supportDescription ?? "Unavailable")",
            "previous=\(previous?.supportDescription ?? "None")",
            "comparison=\(comparisons.supportDescription)",
            "summary=\(changeDescription)",
            "error=\(error?.supportDescription ?? "None")"
        ].joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum CodeSigningIdentityReader {
    static func readCurrentProcess() -> Result<CodeSigningIdentity, CodeSigningDiagnosticError> {
        var code: SecCode?
        let copySelfStatus = SecCodeCopySelf(SecCSFlags(), &code)
        guard copySelfStatus == errSecSuccess, let code else {
            return .failure(
                CodeSigningDiagnosticError(
                    domain: "Security",
                    code: Int(copySelfStatus),
                    detail: "SecCodeCopySelf failed"
                )
            )
        }

        var staticCode: SecStaticCode?
        let staticCodeStatus = SecCodeCopyStaticCode(
            code,
            SecCSFlags(),
            &staticCode
        )
        guard staticCodeStatus == errSecSuccess, let staticCode else {
            return .failure(
                CodeSigningDiagnosticError(
                    domain: "Security",
                    code: Int(staticCodeStatus),
                    detail: "SecCodeCopyStaticCode failed"
                )
            )
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let signingInformation else {
            return .failure(
                CodeSigningDiagnosticError(
                    domain: "Security",
                    code: Int(informationStatus),
                    detail: "SecCodeCopySigningInformation failed"
                )
            )
        }
        let values = signingInformation as NSDictionary

        guard let cdhashData = values.object(
            forKey: kSecCodeInfoUnique
        ) as? Data,
              !cdhashData.isEmpty else {
            return .failure(
                CodeSigningDiagnosticError(
                    domain: "Security",
                    code: nil,
                    detail: "Signing information did not contain a code hash"
                )
            )
        }

        let cdhash = cdhashData.map { String(format: "%02x", $0) }.joined()
        let teamIdentifier = values.object(
            forKey: kSecCodeInfoTeamIdentifier
        ) as? String
        let signingIdentifier = values.object(
            forKey: kSecCodeInfoIdentifier
        ) as? String
        let isAdHoc = (values.object(forKey: kSecCodeInfoFlags) as? NSNumber)
            .map {
                SecCodeSignatureFlags(rawValue: $0.uint32Value)
                    .contains(.adhoc)
            }

        let designatedRequirement = readDesignatedRequirement(staticCode)
        let (leafCertificateSHA256, leafCertificateWasRead) =
            readLeafCertificateSHA256(values: values, isAdHoc: isAdHoc)

        return .success(
            CodeSigningIdentity(
                cdhash: cdhash,
                teamIdentifier: teamIdentifier,
                signingIdentifier: signingIdentifier,
                designatedRequirement: designatedRequirement.value,
                leafCertificateSHA256: leafCertificateSHA256,
                isAdHoc: isAdHoc,
                teamIdentifierWasRead: teamIdentifier != nil || isAdHoc == true,
                signingIdentifierWasRead: signingIdentifier != nil,
                designatedRequirementWasRead: designatedRequirement.wasRead,
                leafCertificateWasRead: leafCertificateWasRead
            )
        )
    }

    private static func readDesignatedRequirement(
        _ code: SecStaticCode
    ) -> (value: String?, wasRead: Bool) {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            code,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement else {
            return (nil, false)
        }

        var text: CFString?
        guard SecRequirementCopyString(
            requirement,
            SecCSFlags(),
            &text
        ) == errSecSuccess,
              let text else {
            return (nil, false)
        }
        return (text as String, true)
    }

    private static func readLeafCertificateSHA256(
        values: NSDictionary,
        isAdHoc: Bool?
    ) -> (value: String?, wasRead: Bool) {
        if isAdHoc == true {
            return (nil, true)
        }
        guard let certificates = values.object(
            forKey: kSecCodeInfoCertificates
        ) as? [SecCertificate],
              let leafCertificate = certificates.first else {
            return (nil, false)
        }

        let certificateData = SecCertificateCopyData(leafCertificate) as Data
        let digest = SHA256.hash(data: certificateData)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return (fingerprint, true)
    }
}

enum CodeSigningIdentityDiagnosticStore {
    // The original keys remain stable so builds that already recorded a
    // CDHash and Team ID continue to participate in the migration comparison.
    static let currentCDHashKey =
        "MacKVM.diagnostics.codeSigning.current.cdhash"
    static let currentTeamIDKey =
        "MacKVM.diagnostics.codeSigning.current.teamID"
    static let previousCDHashKey =
        "MacKVM.diagnostics.codeSigning.previous.cdhash"
    static let previousTeamIDKey =
        "MacKVM.diagnostics.codeSigning.previous.teamID"
    static let currentMetadataCDHashKey =
        "MacKVM.diagnostics.codeSigning.current.metadataCDHash"
    static let previousMetadataCDHashKey =
        "MacKVM.diagnostics.codeSigning.previous.metadataCDHash"
    static let identityChangedKey =
        "MacKVM.diagnostics.codeSigning.identityChanged"
    static let identityComparisonAvailableKey =
        "MacKVM.diagnostics.codeSigning.identityComparisonAvailable"

    static let binaryChangedKey =
        "MacKVM.diagnostics.codeSigning.binaryChanged"
    static let teamChangedKey =
        "MacKVM.diagnostics.codeSigning.teamChanged"
    static let signingIdentifierChangedKey =
        "MacKVM.diagnostics.codeSigning.signingIdentifierChanged"
    static let requirementChangedKey =
        "MacKVM.diagnostics.codeSigning.requirementChanged"
    static let certificateChangedKey =
        "MacKVM.diagnostics.codeSigning.certificateChanged"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.mackvm.MacKVM",
        category: "code-signing"
    )

    static func captureCurrentProcess(
        defaults: UserDefaults = .standard
    ) -> CodeSigningIdentityDiagnostics {
        let diagnostics = record(
            CodeSigningIdentityReader.readCurrentProcess(),
            defaults: defaults
        )
        log(diagnostics)
        return diagnostics
    }

    static func record(
        _ result: Result<CodeSigningIdentity, CodeSigningDiagnosticError>,
        defaults: UserDefaults
    ) -> CodeSigningIdentityDiagnostics {
        let lastCurrent = identity(prefix: "current", defaults: defaults)

        switch result {
        case let .success(current):
            let comparisons = compare(previous: lastCurrent, current: current)
            write(lastCurrent, prefix: "previous", defaults: defaults)
            write(current, prefix: "current", defaults: defaults)
            write(comparisons.binaryChanged, key: binaryChangedKey, defaults: defaults)
            write(comparisons.teamChanged, key: teamChangedKey, defaults: defaults)
            write(
                comparisons.signingIdentifierChanged,
                key: signingIdentifierChangedKey,
                defaults: defaults
            )
            write(
                comparisons.requirementChanged,
                key: requirementChangedKey,
                defaults: defaults
            )
            write(
                comparisons.certificateChanged,
                key: certificateChangedKey,
                defaults: defaults
            )

            if let lastCurrent {
                // Retain the former combined key for readers from the current
                // build. Its historical meaning included the CDHash.
                defaults.set(
                    lastCurrent.cdhash != current.cdhash
                        || lastCurrent.teamIdentifier != current.teamIdentifier,
                    forKey: identityChangedKey
                )
                defaults.set(true, forKey: identityComparisonAvailableKey)
            } else {
                defaults.removeObject(forKey: identityChangedKey)
                defaults.set(false, forKey: identityComparisonAvailableKey)
            }
            return CodeSigningIdentityDiagnostics(
                current: current,
                previous: lastCurrent,
                comparisons: comparisons,
                error: nil
            )
        case let .failure(error):
            // Preserve the last successful identity so a temporary Security
            // framework failure never erases the next startup comparison.
            defaults.removeObject(forKey: identityChangedKey)
            defaults.set(false, forKey: identityComparisonAvailableKey)
            for key in [
                binaryChangedKey,
                teamChangedKey,
                signingIdentifierChangedKey,
                requirementChangedKey,
                certificateChangedKey
            ] {
                defaults.removeObject(forKey: key)
            }
            return CodeSigningIdentityDiagnostics(
                current: nil,
                previous: lastCurrent,
                comparisons: .unknown,
                error: error
            )
        }
    }

    private static func compare(
        previous: CodeSigningIdentity?,
        current: CodeSigningIdentity
    ) -> CodeSigningIdentityComparisons {
        guard let previous else { return .unknown }

        let adHocRequirementIgnored = previous.isAdHoc == true
            || current.isAdHoc == true
        return CodeSigningIdentityComparisons(
            binaryChanged: previous.cdhash != current.cdhash,
            teamChanged: compare(
                previous.teamIdentifier,
                previousWasRead: previous.teamIdentifierWasRead,
                current.teamIdentifier,
                currentWasRead: current.teamIdentifierWasRead
            ),
            signingIdentifierChanged: compare(
                previous.signingIdentifier,
                previousWasRead: previous.signingIdentifierWasRead,
                current.signingIdentifier,
                currentWasRead: current.signingIdentifierWasRead
            ),
            requirementChanged: adHocRequirementIgnored
                ? nil
                : compare(
                    previous.designatedRequirement,
                    previousWasRead: previous.designatedRequirementWasRead,
                    current.designatedRequirement,
                    currentWasRead: current.designatedRequirementWasRead
                ),
            certificateChanged: compare(
                previous.leafCertificateSHA256,
                previousWasRead: previous.leafCertificateWasRead,
                current.leafCertificateSHA256,
                currentWasRead: current.leafCertificateWasRead
            ),
            adHocRequirementIgnored: adHocRequirementIgnored
        )
    }

    private static func compare(
        _ previous: String?,
        previousWasRead: Bool,
        _ current: String?,
        currentWasRead: Bool
    ) -> Bool? {
        guard previousWasRead, currentWasRead else { return nil }
        return previous != current
    }

    private static func log(_ diagnostics: CodeSigningIdentityDiagnostics) {
        let summary = diagnostics.supportDescription
        if diagnostics.error == nil {
            logger.info("phase=signing-identity \(summary, privacy: .public)")
        } else {
            logger.error("phase=signing-identity \(summary, privacy: .public)")
        }
    }

    private static func identity(
        prefix: String,
        defaults: UserDefaults
    ) -> CodeSigningIdentity? {
        guard let cdhash = defaults.string(forKey: key(prefix, "cdhash")) else {
            return nil
        }

        let teamIDKey = key(prefix, "teamID")
        let metadataMatchesCDHash = defaults.string(
            forKey: key(prefix, "metadataCDHash")
        ) == cdhash
        let identifierKey = key(prefix, "signingIdentifier")
        let requirementKey = key(prefix, "designatedRequirement")
        let certificateKey = key(prefix, "leafCertificateSHA256")
        let teamIdentifier = defaults.string(forKey: teamIDKey)
        let signingIdentifier = metadataMatchesCDHash
            ? defaults.string(forKey: identifierKey)
            : nil
        let designatedRequirement = metadataMatchesCDHash
            ? defaults.string(forKey: requirementKey)
            : nil
        let leafCertificateSHA256 = metadataMatchesCDHash
            ? defaults.string(forKey: certificateKey)
            : nil

        return CodeSigningIdentity(
            cdhash: cdhash,
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier,
            designatedRequirement: designatedRequirement,
            leafCertificateSHA256: leafCertificateSHA256,
            isAdHoc: metadataMatchesCDHash
                ? optionalBoolean(defaults, key(prefix, "isAdHoc"))
                : nil,
            teamIdentifierWasRead: metadataMatchesCDHash
                ? recorded(
                    defaults,
                    marker: key(prefix, "teamIDWasRead"),
                    fallback: defaults.object(forKey: teamIDKey) != nil
                )
                : defaults.object(forKey: teamIDKey) != nil,
            signingIdentifierWasRead: metadataMatchesCDHash
                && recorded(
                    defaults,
                    marker: key(prefix, "signingIdentifierWasRead"),
                    fallback: defaults.object(forKey: identifierKey) != nil
                ),
            designatedRequirementWasRead: metadataMatchesCDHash
                && recorded(
                    defaults,
                    marker: key(prefix, "designatedRequirementWasRead"),
                    fallback: defaults.object(forKey: requirementKey) != nil
                ),
            leafCertificateWasRead: metadataMatchesCDHash
                && recorded(
                    defaults,
                    marker: key(prefix, "leafCertificateWasRead"),
                    fallback: defaults.object(forKey: certificateKey) != nil
                )
        )
    }

    private static func write(
        _ identity: CodeSigningIdentity?,
        prefix: String,
        defaults: UserDefaults
    ) {
        guard let identity else {
            for field in [
                "cdhash", "teamID", "signingIdentifier", "designatedRequirement",
                "leafCertificateSHA256", "metadataCDHash", "isAdHoc", "teamIDWasRead",
                "signingIdentifierWasRead", "designatedRequirementWasRead",
                "leafCertificateWasRead"
            ] {
                defaults.removeObject(forKey: key(prefix, field))
            }
            return
        }

        // Invalidate the witness while the record is being replaced. Write it
        // last so a partial update is never mistaken for a complete record.
        defaults.removeObject(forKey: key(prefix, "metadataCDHash"))
        defaults.set(identity.cdhash, forKey: key(prefix, "cdhash"))
        write(identity.teamIdentifier, key: key(prefix, "teamID"), defaults: defaults)
        write(
            identity.signingIdentifier,
            key: key(prefix, "signingIdentifier"),
            defaults: defaults
        )
        write(
            identity.designatedRequirement,
            key: key(prefix, "designatedRequirement"),
            defaults: defaults
        )
        write(
            identity.leafCertificateSHA256,
            key: key(prefix, "leafCertificateSHA256"),
            defaults: defaults
        )
        write(
            identity.isAdHoc,
            key: key(prefix, "isAdHoc"),
            defaults: defaults
        )
        defaults.set(identity.teamIdentifierWasRead, forKey: key(prefix, "teamIDWasRead"))
        defaults.set(
            identity.signingIdentifierWasRead,
            forKey: key(prefix, "signingIdentifierWasRead")
        )
        defaults.set(
            identity.designatedRequirementWasRead,
            forKey: key(prefix, "designatedRequirementWasRead")
        )
        defaults.set(
            identity.leafCertificateWasRead,
            forKey: key(prefix, "leafCertificateWasRead")
        )
        defaults.set(identity.cdhash, forKey: key(prefix, "metadataCDHash"))
    }

    private static func write(
        _ value: String?,
        key: String,
        defaults: UserDefaults
    ) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func write(
        _ value: Bool?,
        key: String,
        defaults: UserDefaults
    ) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func recorded(
        _ defaults: UserDefaults,
        marker: String,
        fallback: Bool
    ) -> Bool {
        guard defaults.object(forKey: marker) != nil else { return fallback }
        return defaults.bool(forKey: marker)
    }

    private static func optionalBoolean(
        _ defaults: UserDefaults,
        _ key: String
    ) -> Bool? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    private static func key(_ prefix: String, _ field: String) -> String {
        "MacKVM.diagnostics.codeSigning.\(prefix).\(field)"
    }
}
