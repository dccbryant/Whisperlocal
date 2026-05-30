import CryptoKit
import Foundation
import Security

enum ParleyCryptoError: Error, LocalizedError {
    case keychainFailed(OSStatus)
    case sealFailed(Error)
    case openFailed(Error)
    case notEncrypted

    var errorDescription: String? {
        switch self {
        case .keychainFailed(let status): return "Keychain operation failed (\(status))"
        case .sealFailed(let e): return "Encryption failed: \(e.localizedDescription)"
        case .openFailed(let e): return "Decryption failed: \(e.localizedDescription)"
        case .notEncrypted: return "File is not encrypted (no Parley magic header)"
        }
    }
}

/// Holds the master encryption key for all on-disk recording data.
///
/// Key lifecycle:
///   - First launch generates a fresh 256-bit AES key and stores it in the iOS Keychain
///     with kSecAttrAccessibleWhenUnlockedThisDeviceOnly. That accessibility tier means:
///       • The key only resolves when the device is unlocked.
///       • The key is never synced to iCloud Keychain.
///       • The key is excluded from unencrypted iTunes/Finder backups.
///   - Subsequent launches load the existing key from Keychain.
///   - The key is cached in memory for the app's lifetime; cleared on background after the
///     LockGate grace period (handled separately by the lock layer).
///
/// Encryption uses AES-GCM with a random nonce per blob. We prepend a 4-byte magic header
/// "PRLY" so we can tell encrypted files from any plaintext that might still exist (migration).
final class ParleyCrypto: @unchecked Sendable {
    static let shared = ParleyCrypto()

    /// "PRLY"
    static let magicHeader = Data([0x50, 0x52, 0x4C, 0x59])

    private let keychainAccount = "com.davidbryant.parley.dataKey"
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    private init() {}

    // MARK: - Public API

    func encrypt(_ data: Data) throws -> Data {
        let k = try key()
        do {
            let sealed = try AES.GCM.seal(data, using: k)
            guard let combined = sealed.combined else {
                throw ParleyCryptoError.sealFailed(NSError(domain: "ParleyCrypto", code: -1))
            }
            return Self.magicHeader + combined
        } catch let e as ParleyCryptoError {
            throw e
        } catch {
            throw ParleyCryptoError.sealFailed(error)
        }
    }

    func decrypt(_ data: Data) throws -> Data {
        guard Self.isEncrypted(data) else { throw ParleyCryptoError.notEncrypted }
        let k = try key()
        let payload = data.suffix(from: Self.magicHeader.count)
        do {
            let box = try AES.GCM.SealedBox(combined: payload)
            return try AES.GCM.open(box, using: k)
        } catch {
            throw ParleyCryptoError.openFailed(error)
        }
    }

    /// True if `data` starts with the Parley magic header.
    static func isEncrypted(_ data: Data) -> Bool {
        guard data.count > magicHeader.count else { return false }
        return data.prefix(magicHeader.count) == magicHeader
    }

    /// Drop the in-memory key cache so the next access re-fetches from Keychain. Used by the
    /// lock layer when the app re-locks after the grace period.
    func clearCache() {
        lock.lock(); defer { lock.unlock() }
        cachedKey = nil
    }

    // MARK: - Keychain

    private func key() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let k = cachedKey { return k }
        if let existing = loadKey() {
            cachedKey = existing
            return existing
        }
        let fresh = SymmetricKey(size: .bits256)
        try saveKey(fresh)
        cachedKey = fresh
        return fresh
    }

    private func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private func saveKey(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        // SecItemAdd fails with errSecDuplicateItem if the item already exists; delete first.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ParleyCryptoError.keychainFailed(status)
        }
    }
}
