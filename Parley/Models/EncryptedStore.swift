import Foundation

/// Convenience wrappers around ParleyCrypto for file-based I/O.
///
/// All writes use NSFileProtectionComplete so files are unreadable while the device is
/// locked, layered on top of the app-level AES-GCM encryption.
enum EncryptedStore {

    /// Read a file's bytes and decrypt. Throws if the file is plaintext (no magic header).
    static func readDecrypted(from url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        return try ParleyCrypto.shared.decrypt(raw)
    }

    /// Encrypt and write data to a file with full file protection.
    static func writeEncrypted(_ data: Data, to url: URL) throws {
        let sealed = try ParleyCrypto.shared.encrypt(data)
        try sealed.write(to: url, options: [.completeFileProtection])
    }

    /// One-shot encrypt-in-place for legacy plaintext files. After a successful re-write,
    /// returns true; if the file was already encrypted (magic header present) returns false.
    @discardableResult
    static func migratePlaintextInPlace(at url: URL) throws -> Bool {
        let raw = try Data(contentsOf: url)
        if ParleyCrypto.isEncrypted(raw) { return false }
        try writeEncrypted(raw, to: url)
        return true
    }

    // MARK: - Audio staging

    /// Decrypts an encrypted audio file to a unique temp path so AVAudioFile / AVAudioPlayer
    /// can stream from disk. Caller is responsible for calling `cleanupStagedAudio` when done.
    static func stageAudio(from encryptedURL: URL) throws -> URL {
        let encrypted = try Data(contentsOf: encryptedURL)
        let decrypted: Data
        if ParleyCrypto.isEncrypted(encrypted) {
            decrypted = try ParleyCrypto.shared.decrypt(encrypted)
        } else {
            // Plaintext leftover (migration not yet run for this file). Use as-is.
            decrypted = encrypted
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-stage-\(UUID().uuidString)")
            .appendingPathExtension(encryptedURL.pathExtension.isEmpty ? "wav" : encryptedURL.pathExtension)
        try decrypted.write(to: temp, options: [.completeFileProtectionUnlessOpen])
        return temp
    }

    static func cleanupStagedAudio(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
