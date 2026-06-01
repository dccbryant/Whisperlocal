import AVFoundation
import Foundation
import SpeakerKit
import WhisperKit

protocol TranscriptionService {
    /// Transcribe the audio file, splitting into per-speaker segments where possible.
    /// `onProgress` (if provided) is called with a 0…1 fraction as segments complete.
    func transcribe(
        audioAt url: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [TranscriptSegment]
}

/// On-device transcription with speaker diarization.
///
/// Pipeline:
///   1. AudioFileReader → [Float] at 16 kHz mono.
///   2. SpeakerKit.diarize(...) → SpeakerSegment list (start/end + speaker ID).
///   3. For each segment, slice the [Float] and run WhisperKit.transcribe(audioArray:).
///   4. Produce TranscriptSegment list with friendly "Speaker N" labels.
///
/// If diarization fails or finds nothing, falls back to a single full-audio transcription.
actor DiarizingTranscriptionService: TranscriptionService {
    enum ServiceError: Error, LocalizedError {
        case notReady
        case empty

        var errorDescription: String? {
            switch self {
            case .notReady: return "Models aren't loaded yet."
            case .empty: return "Whisper produced no text."
            }
        }
    }

    /// `small.en` is meaningfully more accurate than `base.en` (especially on names,
    /// numbers, and crosstalk) at the cost of a ~250 MB first-launch download instead
    /// of ~75 MB and slightly slower transcription on older devices.
    static let defaultWhisperModel = "openai_whisper-small.en"

    private var whisper: WhisperKit?
    private var speakers: SpeakerKit?

    func load() async throws {
        if whisper == nil {
            whisper = try await WhisperKit(model: Self.defaultWhisperModel)
        }
        if speakers == nil {
            speakers = try await SpeakerKit()
        }
    }

    var isLoaded: Bool { whisper != nil && speakers != nil }

    func transcribe(
        audioAt url: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        guard let whisper, let speakers else { throw ServiceError.notReady }

        let samples = try AudioFileReader.readMono16kFloats(at: url)
        guard !samples.isEmpty else { throw ServiceError.empty }

        // Diarization gets ~30% of the progress budget; per-segment transcription gets ~70%.
        // SpeakerKit's diarize() is one opaque call that takes 20-40s with no internal
        // signal, so the bar would otherwise sit at 0% the whole time. Spin up a background
        // task that creeps the reported progress upward along an ease-out curve toward
        // (but never reaching) 0.25, so the user can see the app is alive. The real 0.3
        // lands the moment diarization actually finishes.
        onProgress?(0)
        let creepTask: Task<Void, Never>? = onProgress.map { cb in
            Task {
                var elapsed: Double = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    elapsed += 1
                    let p = 0.25 * (1 - exp(-elapsed / 15))
                    cb(p)
                }
            }
        }

        let diarization: DiarizationResult
        do {
            diarization = try await speakers.diarize(audioArray: samples)
        } catch {
            creepTask?.cancel()
            throw error
        }
        creepTask?.cancel()
        onProgress?(0.3)

        // No speakers detected → single-shot transcribe.
        if diarization.segments.isEmpty {
            let results = try await whisper.transcribe(audioArray: samples)
            onProgress?(1.0)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ServiceError.empty }
            return [TranscriptSegment(speakerLabel: "Speaker 1", text: text, start: 0, end: Double(samples.count) / 16_000)]
        }

        var labelMap: [Int: Int] = [:]
        var nextLabel = 1

        var out: [TranscriptSegment] = []
        let total = diarization.segments.count
        for (i, seg) in diarization.segments.enumerated() {
            // Need a single speaker ID for the segment; skip ambiguous segments.
            guard let speakerId = seg.speaker.speakerId else {
                onProgress?(0.3 + 0.7 * Double(i + 1) / Double(total))
                continue
            }

            let label: Int
            if let existing = labelMap[speakerId] {
                label = existing
            } else {
                label = nextLabel
                labelMap[speakerId] = nextLabel
                nextLabel += 1
            }

            let startSample = max(0, Int(seg.startTime * 16_000))
            let endSample = min(samples.count, Int(seg.endTime * 16_000))
            guard endSample > startSample else {
                onProgress?(0.3 + 0.7 * Double(i + 1) / Double(total))
                continue
            }
            if endSample - startSample < 3_200 {
                onProgress?(0.3 + 0.7 * Double(i + 1) / Double(total))
                continue
            }

            let slice = Array(samples[startSample..<endSample])
            let results = try await whisper.transcribe(audioArray: slice)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            onProgress?(0.3 + 0.7 * Double(i + 1) / Double(total))
            guard !text.isEmpty else { continue }

            out.append(TranscriptSegment(
                speakerLabel: "Speaker \(label)",
                text: text,
                start: TimeInterval(seg.startTime),
                end: TimeInterval(seg.endTime)
            ))
        }

        guard !out.isEmpty else { throw ServiceError.empty }
        return out
    }
}

/// Mock used until services load. Returns a placeholder transcript so the UI can be exercised.
struct MockTranscriptionService: TranscriptionService {
    func transcribe(
        audioAt url: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        try await Task.sleep(nanoseconds: 200_000_000)
        onProgress?(1.0)
        return [TranscriptSegment(speakerLabel: "Speaker 1", text: "[mock transcript] \(url.lastPathComponent)", start: 0, end: 1)]
    }
}
