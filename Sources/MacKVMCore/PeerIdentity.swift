import CryptoKit
import Foundation
import Security

public struct PeerIdentity: Codable, Hashable, Sendable {
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
}

public struct DeviceCredentials {
    public let identity: PeerIdentity
    public let privateKey: P256.Signing.PrivateKey
}

public protocol DevicePrivateKeyStore {
    func load() throws -> Data?
    func save(_ keyData: Data) throws
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
            return DeviceCredentials(
                identity: identity,
                privateKey: privateKey
            )
        }

        guard identityData == nil, privateKeyData == nil else {
            throw DeviceCredentialError.identityKeyMismatch
        }
        let privateKey = P256.Signing.PrivateKey()
        let identity = PeerIdentity(
            name: fallbackName,
            signingPublicKey: privateKey.publicKey.x963Representation
        )
        try keyStore.save(privateKey.rawRepresentation)
        defaults.set(try JSONEncoder().encode(identity), forKey: identityKey)
        return DeviceCredentials(identity: identity, privateKey: privateKey)
    }
}
