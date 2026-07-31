import Foundation
import Security

public enum KeychainStoreError: LocalizedError, Sendable {
    case unhandledStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .unhandledStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain operation failed (\(status)): \(message)"
        }
    }
}

/// Minimal wrapper around `SecItem*` for storing generic-password secrets
/// (e.g. OAuth tokens). Namespace `service` strings per caller to avoid
/// collisions with unrelated Keychain items on the same account.
public struct KeychainStore: Sendable {
    public init() {}

    public func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    public func save(service: String, account: String, data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        var attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
        ]

        let addQuery = baseQuery.merging(attributesToUpdate) { _, new in new }
            .merging([kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainStoreError.unhandledStatus(addStatus)
        }

        attributesToUpdate[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeychainStoreError.unhandledStatus(updateStatus)
        }
    }

    @discardableResult
    public func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
