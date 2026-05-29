import Foundation
import SwiftUI

/// Persistent on-disk library of recordings.
///
/// Layout (all under Documents/Recordings/):
///   2026-05-28T01-23-45Z.wav        — raw audio
///   2026-05-28T01-23-45Z.json       — Recording metadata sidecar
///
/// We deliberately keep them as separate files rather than packing into a single store so
/// each recording can be inspected or exported by hand from the Files app.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    let directory: URL

    init() {
        self.directory = Self.recordingsDirectory()
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
            guard let data = try? Data(contentsOf: url),
                  let rec = try? decoder.decode(Recording.self, from: data) else { continue }
            loaded.append(rec)
        }
        recordings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ recording: Recording) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sidecar = directory.appendingPathComponent("\(recording.audioFilename).json")
        if let data = try? encoder.encode(recording) {
            try? data.write(to: sidecar)
        }
        if let idx = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[idx] = recording
        } else {
            recordings.insert(recording, at: 0)
        }
    }

    func delete(_ recording: Recording) {
        let audio = recording.audioURL(in: directory)
        let sidecar = directory.appendingPathComponent("\(recording.audioFilename).json")
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.removeItem(at: sidecar)
        recordings.removeAll { $0.id == recording.id }
    }
}
