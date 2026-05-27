import Foundation
import WhisperKit

/// On-device transcription via WhisperKit (CoreML-backed Whisper on the Neural Engine).
///
/// WhisperKit handles audio decoding (m4a/wav/mp3/flac) and model download on its own.
/// We just hold the pipeline instance and forward calls.
actor WhisperKitTranscriptionService: TranscriptionService {
    enum ServiceError: Error, LocalizedError {
        case notReady
        case empty

        var errorDescription: String? {
            switch self {
            case .notReady: return "WhisperKit isn't loaded yet."
            case .empty: return "Whisper produced no text."
            }
        }
    }

    /// Recommended for English-only on iPhone: a small CoreML Whisper variant. WhisperKit
    /// downloads this from Hugging Face on first init, then runs fully offline.
    static let defaultModel = "openai_whisper-base.en"

    private var pipeline: WhisperKit?

    func load(modelName: String = defaultModel) async throws {
        if pipeline != nil { return }
        pipeline = try await WhisperKit(model: modelName)
    }

    var isLoaded: Bool { pipeline != nil }

    func transcribe(audioAt url: URL) async throws -> String {
        guard let pipeline else { throw ServiceError.notReady }
        let results = try await pipeline.transcribe(audioPath: url.path)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServiceError.empty }
        return text
    }
}
