import Foundation
import Security

// =============================================================================
// BEFORE — Keychain.
//
// Tokens go here, never into UserDefaults or SwiftData (spec §47).
//
// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is deliberate:
//   - afterFirstUnlock, so a background refresh can read the token.
//   - ThisDeviceOnly, so a session token is never restored onto a new device
//     from an encrypted backup.
// =============================================================================

public struct KeychainStore: Sendable {
    public enum Key: String, Sendable {
        case accessToken = "before.auth.accessToken"
        case refreshToken = "before.auth.refreshToken"
        /// Stable UUID used as the App Store appAccountToken.
        case appAccountToken = "before.storekit.appAccountToken"
    }

    public enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        public var description: String {
            switch self {
            case .unexpectedStatus(let status):
                "Keychain operation failed with status \(status)"
            }
        }
    }

    private let service: String

    public init(service: String = "com.yourcompany.before") {
        self.service = service
    }

    // MARK: - API

    public func set(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else { return }

        // Delete-then-add rather than update: it is one code path instead of
        // two, and the race it avoids (concurrent refresh) is real.
        SecItemDelete(query(for: key) as CFDictionary)

        var attributes = query(for: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func string(for key: Key) -> String? {
        var lookup = query(for: key)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func remove(_ key: Key) {
        SecItemDelete(query(for: key) as CFDictionary)
    }

    /// Clear everything on sign-out or account deletion.
    public func removeAll() {
        for key in [Key.accessToken, .refreshToken, .appAccountToken] { remove(key) }
    }

    /// The stable per-user token sent to StoreKit so a transaction can be tied
    /// back to a BEFORE account (spec §37). Created once, then reused.
    public func appAccountToken() -> UUID {
        if let existing = string(for: .appAccountToken), let uuid = UUID(uuidString: existing) {
            return uuid
        }
        let fresh = UUID()
        try? set(fresh.uuidString, for: .appAccountToken)
        return fresh
    }

    // MARK: - Query

    private func query(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
