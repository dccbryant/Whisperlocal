import Foundation
import SwiftUI

/// Persistent on-disk library of recordings.
///
/// Layout (all under Documents/Recordings/):
///   <timestamp>.wav        — audio, AES-GCM encrypted with NSFileProtectionComplete
///   <timestamp>.wav.json   — Recording metadata sidecar, AES-GCM encrypted
///
/// File names keep their familiar extensions; the bytes inside are encrypted with the
/// ParleyCrypto magic header. On first launch under this version any plaintext files left
/// over from earlier installs are encrypted in place.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    let directory: URL

    init() {
        self.directory = Self.recordingsDirectory()
        migratePlaintextIfNeeded()
        reload()
    }

    static func recordingsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let jsons = files.filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [Recording] = []
        for url in jsons {
            do {
                let data = try EncryptedStore.readDecrypted(from: url)
                let rec = try decoder.decode(Recording.self, from: data)
                loaded.append(rec)
            } catch {
                print("[RecordingStore] could not decode \(url.lastPathComponent): \(error)")
            }
        }
        recordings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ recording: Recording) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sidecar = directory.appendingPathComponent("\(recording.audioFilename).json")
        do {
            let data = try encoder.encode(recording)
            try EncryptedStore.writeEncrypted(data, to: sidecar)
        } catch {
            print("[RecordingStore] could not save sidecar: \(error)")
        }
        if let idx = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[idx] = recording
        } else {
            recordings.insert(recording, at: 0)
        }
    }

    /// Encrypt and store an audio file produced by AudioRecorder (which writes plaintext to
    /// a temp directory) or imported from Files. Returns the filename stored in the library.
    func ingestAudio(from sourceURL: URL, deleteSource: Bool = true) throws -> String {
        let data = try Data(contentsOf: sourceURL)
        let filename = sourceURL.lastPathComponent
        let destination = directory.appendingPathComponent(filename)
        try EncryptedStore.writeEncrypted(data, to: destination)
        if deleteSource { try? FileManager.default.removeItem(at: sourceURL) }
        return filename
    }

    func delete(_ recording: Recording) {
        let audio = recording.audioURL(in: directory)
        let sidecar = directory.appendingPathComponent("\(recording.audioFilename).json")
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.removeItem(at: sidecar)
        recordings.removeAll { $0.id == recording.id }
    }

    // MARK: - Migration

    /// One-shot encrypt any legacy plaintext audio + sidecar files left from before
    /// at-rest encryption was added. Safe to call on every launch — encrypted files are
    /// recognised by the magic header and skipped.
    private func migratePlaintextIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in files where ["wav", "json"].contains(url.pathExtension) {
            do {
                if try EncryptedStore.migratePlaintextInPlace(at: url) {
                    print("[RecordingStore] encrypted legacy file: \(url.lastPathComponent)")
                }
            } catch {
                print("[RecordingStore] migration failed for \(url.lastPathComponent): \(error)")
            }
        }
    }
}
