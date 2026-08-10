import CryptoKit
import Foundation
import Security

public struct PeerIdentity: Codable, Hashable, Sendable {
    public static let maximumDisplayNameBytes = 64

    public let id: UUID
    public var name: String
    public let signingPublicKey: Data

    public init(
        id: UUID = UUID(),
        name: String,
        signingPublicKey: Data
    ) {
        self.id = id
        self.name = name
        self.signingPublicKey = signingPublicKey
    }

    public var serviceName: String {
        "MacKVM-\(id.uuidString)"
    }

    /// Truncates a display name on Character boundaries without exceeding the
    /// UTF-8 wire/UI budget. Callers can still apply stricter validation when
    /// the value is used as signed protocol identity data.
    public static func boundedDisplayName(_ name: String) -> String {
        var boundedName = ""
        var boundedByteCount = 0
        for character in name {
            let characterByteCount = character.utf8.count
            guard boundedByteCount + characterByteCount
                    <= maximumDisplayNameBytes else {
                break
            }
            boundedName.append(character)
            boundedByteCount += characterByteCount
        }
        return boundedName
    }

    /// Returns a safe, bounded name for use in Bonjour records and signed
    /// protocol messages. The wire protocols must never carry control
    /// characters or an unbounded display name.
    public static func isValidDisplayName(_ name: String) -> Bool {
        // Validate the exact wire text, including surrounding whitespace;
        // validatedDisplayName(_:) trims only locally stored/generated names.
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              boundedDisplayName(name) == name,
              name.unicodeScalars.allSatisfy({
                  !isUnsafeDisplayScalar($0)
              }) else {
            return false
        }
        // Combining marks and variation selectors are only meaningful when
        // attached to a visible base character; reject visually blank names
        // made solely from those scalars.
        return name.unicodeScalars.contains {
            isVisibleDisplayBaseScalar($0)
        }
    }

    private static func isVisibleDisplayBaseScalar(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format:
            return false
        default:
            return !isUnsafeDisplayScalar(scalar)
        }
    }

    private static func isUnsafeDisplayScalar(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        let value = scalar.value
        // C0/C1 controls, DEL, and line separators can hide or reorder
        // peer-controlled text in menus and alerts.
        guard value >= 0x20,
              value != 0x7F,
              !(0x80...0x9F).contains(value),
              value != 0x2028,
              value != 0x2029 else {
            return true
        }
        switch scalar.properties.generalCategory {
        // Allowlist printable categories so newly added control/format
        // categories remain rejected by default. Variation selectors are the
        // one format range retained for normal emoji presentation.
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter, .nonspacingMark, .spacingMark,
             .enclosingMark, .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation, .mathSymbol, .currencySymbol,
             .modifierSymbol, .otherSymbol, .spaceSeparator:
            return false
        case .format:
            return !(0xFE00...0xFE0F).contains(value)
        default:
            // Unknown and future Unicode categories are rejected by default.
            return true
        }
    }

    public static func validatedDisplayName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidDisplayName(trimmed) else { return nil }
        return trimmed
    }
}

public struct DeviceCredentials {
    public let identity: PeerIdentity
    public let privateKey: P256.Signing.PrivateKey
    /// Whether this call loaded an existing complete identity rather than
    /// creating a new one. The onboarding flow uses this to migrate upgrades
    /// without a second Keychain lookup during app launch.
    public let wasLoadedFromStorage: Bool
}

public protocol DevicePrivateKeyStore {
    func load() throws -> Data?
    func save(_ keyData: Data) throws
    func delete() throws
}

public struct KeychainPrivateKeyStore: DevicePrivateKeyStore {
    private let service: String
    private let account: String

    public init(
        service: String = "app.mackvm.device-identity",
        account: String = "p256-signing-key"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DeviceCredentialError.keychain(status)
        }
        return data
    }

    public func save(_ keyData: Data) throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: keyData,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw DeviceCredentialError.keychain(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw DeviceCredentialError.keychain(updateStatus)
        }
    }

    public func delete() throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceCredentialError.keychain(status)
        }
    }
}

public enum DeviceCredentialError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)
    case invalidStoredIdentity
    case identityKeyMismatch

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain access failed with status \(status)."
        case .invalidStoredIdentity:
            return "The saved MacKVM device identity is invalid."
        case .identityKeyMismatch:
            return "The saved MacKVM identity does not match its Keychain key. Forget this Mac on the other computer before resetting its identity."
        }
    }
}

public enum DeviceCredentialsStore {
    private static let identityKey = "MacKVM.localIdentity"
    private static let identityDefaultsSuite = "app.mackvm.device-identity"

    public static func load(
        from suppliedDefaults: UserDefaults? = nil,
        fallbackName: String = Host.current().localizedName ?? "Mac",
        keyStore: DevicePrivateKeyStore = KeychainPrivateKeyStore()
    ) throws -> DeviceCredentials {
        let defaults = suppliedDefaults
            ?? UserDefaults(suiteName: identityDefaultsSuite)
            ?? .standard
        let identityData = defaults.data(forKey: identityKey)
        let privateKeyData = try keyStore.load()

        if let identityData, let privateKeyData {
            guard let identity = try? JSONDecoder().decode(
                PeerIdentity.self,
                from: identityData
            ) else {
                throw DeviceCredentialError.invalidStoredIdentity
            }
            guard let privateKey = try? P256.Signing.PrivateKey(
                rawRepresentation: privateKeyData
            ),
            privateKey.publicKey.x963Representation
                == identity.signingPublicKey else {
                throw DeviceCredentialError.identityKeyMismatch
            }
            let normalizedName = PeerIdentity.validatedDisplayName(identity.name)
                ?? PeerIdentity.validatedDisplayName(fallbackName)
                ?? "Mac"
            if normalizedName != identity.name {
                let normalizedIdentity = PeerIdentity(
                    id: identity.id,
                    name: normalizedName,
                    signingPublicKey: identity.signingPublicKey
                )
                defaults.set(
                    try JSONEncoder().encode(normalizedIdentity),
                    forKey: identityKey
                )
                return DeviceCredentials(
                    identity: normalizedIdentity,
                    privateKey: privateKey,
                    wasLoadedFromStorage: true
                )
            }
            return DeviceCredentials(
                identity: identity,
                privateKey: privateKey,
                wasLoadedFromStorage: true
            )
        }

        guard identityData == nil, privateKeyData == nil else {
            throw DeviceCredentialError.identityKeyMismatch
        }
        let privateKey = P256.Signing.PrivateKey()
        let identity = PeerIdentity(
            name: PeerIdentity.validatedDisplayName(fallbackName) ?? "Mac",
            signingPublicKey: privateKey.publicKey.x963Representation
        )
        try keyStore.save(privateKey.rawRepresentation)
        defaults.set(try JSONEncoder().encode(identity), forKey: identityKey)
        return DeviceCredentials(
            identity: identity,
            privateKey: privateKey,
            wasLoadedFromStorage: false
        )
    }

    /// Removes the local identity atomically from the app defaults and
    /// Keychain boundary. A new identity is generated on the next launch;
    /// callers should clear paired peers at the same time and pair again.
    public static func reset(
        from suppliedDefaults: UserDefaults? = nil,
        keyStore: DevicePrivateKeyStore = KeychainPrivateKeyStore()
    ) throws {
        let defaults = suppliedDefaults
            ?? UserDefaults(suiteName: identityDefaultsSuite)
            ?? .standard
        // Delete the Keychain record first. If that fails, retain the stored
        // identity so the next launch cannot accidentally combine a new key
        // with an old identity record.
        try keyStore.delete()
        defaults.removeObject(forKey: identityKey)
    }
}
