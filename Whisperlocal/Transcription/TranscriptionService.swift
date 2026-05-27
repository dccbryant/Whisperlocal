import Foundation

protocol TranscriptionService {
    func transcribe(audioAt url: URL) async throws -> String
}

/// Placeholder used until whisper.cpp is integrated. Returns a fake transcript so the UI flow
/// is exercisable end-to-end. Replace with `WhisperCppTranscriptionService` once the SwiftPM
/// dependency and model download are in place.
struct MockTranscriptionService: TranscriptionService {
    func transcribe(audioAt url: URL) async throws -> String {
        try await Task.sleep(nanoseconds: 800_000_000)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return "[mock transcript] Recorded file \(url.lastPathComponent) (\(size) bytes). Wire in whisper.cpp to get a real transcript."
    }
}
