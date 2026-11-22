import Foundation

#if canImport(Security)
import Security
#endif

public protocol SecretStoreProtocol: Sendable {
    func saveKey(_ key: String, forHost host: String) throws
    func readKey(forHost host: String) throws -> String?
    func deleteKey(forHost host: String) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case invalidHost
    case keychainFailure(Int32)
}

/// Testler ve simülatör izole çalıştırmaları için bellek içi anahtar deposu.
public final class InMemorySecretStore: SecretStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var keysByHost: [String: String] = [:]

    public init() {}

    public func saveKey(_ key: String, forHost host: String) throws {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw SecretStoreError.invalidHost }
        lock.withLock { keysByHost[normalized] = key }
    }

    public func readKey(forHost host: String) throws -> String? {
        lock.withLock { keysByHost[host.lowercased()] }
    }

    public func deleteKey(forHost host: String) throws {
        lock.withLock { _ = keysByHost.removeValue(forKey: host.lowercased()) }
    }
}

#if canImport(Security)
/// Kişisel sağlayıcı anahtarını cihazla sınırlı Keychain erişimiyle (AfterFirstUnlockThisDeviceOnly) saklar.
public final class KeychainSecretStore: SecretStoreProtocol, Sendable {
    private let servicePrefix: String

    public init(servicePrefix: String = "com.iagent.provider-key") {
        self.servicePrefix = servicePrefix
    }

    public func saveKey(_ key: String, forHost host: String) throws {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw SecretStoreError.invalidHost }

        let keyData = Data(key.utf8)
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: normalized
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Sil-sonra-ekle yarış penceresini kapatmak için önce atomik SecItemUpdate dene.
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SecretStoreError.keychainFailure(updateStatus)
        }

        var addQuery = matchQuery
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = keyData

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailure(status)
        }
    }

    public func readKey(forHost host: String) throws -> String? {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: normalized,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError.keychainFailure(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteKey(forHost host: String) throws {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
            kSecAttrAccount as String: normalized
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SecretStoreError.keychainFailure(status)
        }
    }
}
#endif
