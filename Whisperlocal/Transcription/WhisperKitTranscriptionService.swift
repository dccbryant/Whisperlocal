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
        // WhisperKit auto-detects the simulator and forces .cpuOnly internally, so we don't
        // need a custom ModelComputeOptions here. On real devices it uses the Neural Engine.
        pipeline = try await WhisperKit(model: modelName)
    }

    var isLoaded: Bool { pipeline != nil }

    func transcribe(audioAt url: URL) async throws -> String {
        guard let pipeline else { throw ServiceError.notReady }

        // Feed WhisperKit raw [Float] samples instead of a file path. The file-path API has
        // shown decode flakiness on simulator -- producing $$$$ hallucinations despite a
        // well-formed PCM WAV input. Reading + converting ourselves removes that variable.
        let samples = try AudioFileReader.readMono16kFloats(at: url)
        let rms = samples.isEmpty
            ? 0
            : sqrt(samples.reduce(into: Float(0)) { $0 += $1 * $1 } / Float(samples.count))
        print("[WhisperKit] samples=\(samples.count) rms=\(String(format: "%.4f", rms)) (>0.01 = real speech)")

        let results = try await pipeline.transcribe(audioArray: samples)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServiceError.empty }
        return text
    }
}
