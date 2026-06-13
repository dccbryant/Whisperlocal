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
///   3. ONE WhisperKit.transcribe(audioArray:) pass over the full audio → timestamped
///      segments. (Slicing per speaker-turn and transcribing each slice paid ~5s of fixed
///      per-call overhead every time — hundreds of calls on a long meeting; one pass pays
///      it once.)
///   4. Assign each Whisper segment a speaker by max timestamp-overlap with the diarization
///      ranges, then group consecutive same-speaker segments into "Speaker N" turns.
///
/// If diarization finds nothing, falls back to a single untagged full-audio transcription.
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

        let stageStart = Date()
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
        let diarizeStart = Date()
        do {
            diarization = try await speakers.diarize(audioArray: samples)
        } catch {
            creepTask?.cancel()
            throw error
        }
        let diarizeElapsed = Date().timeIntervalSince(diarizeStart)
        creepTask?.cancel()
        onProgress?(0.3)

        // No speakers detected → single-shot transcribe.
        if diarization.segments.isEmpty {
            let whisperStart = Date()
            let results = try await whisper.transcribe(audioArray: samples)
            let whisperElapsed = Date().timeIntervalSince(whisperStart)
            onProgress?(1.0)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ServiceError.empty }
            let audioSeconds = Double(samples.count) / 16_000
            print(String(format: "[Timing] transcribe (no diarization): audio=%.0fs, diarize=%.1fs, whisper=%.1fs (1 pass), stage=%.1fs",
                         audioSeconds, diarizeElapsed, whisperElapsed, Date().timeIntervalSince(stageStart)))
            return [TranscriptSegment(speakerLabel: "Speaker 1", text: text, start: 0, end: audioSeconds)]
        }

        // Transcribe the whole audio in ONE pass. Whisper has no incremental progress hook
        // here, so creep the bar from 0.3 toward 0.85 while it runs, then snap to 0.9.
        let transcribeCreep: Task<Void, Never>? = onProgress.map { cb in
            Task {
                var elapsed: Double = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    elapsed += 1
                    cb(0.3 + 0.55 * (1 - exp(-elapsed / 60)))
                }
            }
        }
        let whisperStart = Date()
        let results: [TranscriptionResult]
        do {
            results = try await whisper.transcribe(audioArray: samples)
        } catch {
            transcribeCreep?.cancel()
            throw error
        }
        transcribeCreep?.cancel()
        let whisperElapsed = Date().timeIntervalSince(whisperStart)
        onProgress?(0.9)

        // Whisper's timestamped segments (start/end in seconds), in chronological order.
        let whisperSegments = results.flatMap { $0.segments }

        // Dense 1-based speaker labels in first-appearance (time) order. SpeakerKit cluster
        // IDs can be sparse (0, 3, 7); remap them to Speaker 1, 2, 3 …
        var labelMap: [Int: Int] = [:]
        var nextLabel = 1
        for seg in diarization.segments {
            guard let sid = seg.speaker.speakerId else { continue }
            if labelMap[sid] == nil {
                labelMap[sid] = nextLabel
                nextLabel += 1
            }
        }

        // The speaker label for a Whisper segment's time span: the diarization speaker it
        // overlaps most. If it lands in a diarization gap (no overlap), fall back to the
        // nearest diarization range in time.
        func speakerLabel(forStart s: Double, end e: Double) -> Int? {
            var bestLabel: Int?
            var bestOverlap = 0.0
            var nearestLabel: Int?
            var nearestGap = Double.greatestFiniteMagnitude
            for seg in diarization.segments {
                guard let sid = seg.speaker.speakerId, let label = labelMap[sid] else { continue }
                let segStart = Double(seg.startTime)
                let segEnd = Double(seg.endTime)
                let overlap = min(e, segEnd) - max(s, segStart)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestLabel = label
                }
                let gap = e < segStart ? segStart - e : (s > segEnd ? s - segEnd : 0)
                if gap < nearestGap {
                    nearestGap = gap
                    nearestLabel = label
                }
            }
            return bestLabel ?? nearestLabel
        }

        // Walk segments in order, merging consecutive same-speaker ones into one turn.
        var out: [TranscriptSegment] = []
        var curLabel: Int?
        var curText = ""
        var curStart = 0.0
        var curEnd = 0.0
        func flush() {
            let text = Self.collapseWhitespace(curText)
            guard let label = curLabel, !text.isEmpty else { return }
            out.append(TranscriptSegment(
                speakerLabel: "Speaker \(label)",
                text: text,
                start: curStart,
                end: curEnd
            ))
        }
        for ws in whisperSegments {
            let segStart = Double(ws.start)
            let segEnd = Double(ws.end)
            // Per-segment text carries raw special/timestamp tokens (<|startoftranscript|>,
            // <|0.00|>, …); strip them. The result-level .text is pre-cleaned but has no
            // per-segment timing, which we need for speaker alignment.
            let cleaned = Self.stripSpecialTokens(ws.text)
            let label = speakerLabel(forStart: segStart, end: segEnd)
            if label != curLabel {
                flush()
                curLabel = label
                curText = cleaned
                curStart = segStart
                curEnd = segEnd
            } else {
                curText += cleaned
                curEnd = segEnd
            }
        }
        flush()

        onProgress?(1.0)

        let audioSeconds = Double(samples.count) / 16_000
        print(String(format: "[Timing] transcribe: audio=%.0fs, diarize=%.1fs, whisper=%.1fs (1 pass), %d whisper segs → %d turns, %d speakers, stage=%.1fs",
                     audioSeconds, diarizeElapsed, whisperElapsed,
                     whisperSegments.count, out.count, labelMap.count,
                     Date().timeIntervalSince(stageStart)))

        guard !out.isEmpty else { throw ServiceError.empty }
        return out
    }

    /// Remove WhisperKit special/timestamp tokens like `<|startoftranscript|>` and `<|0.00|>`.
    private static func stripSpecialTokens(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
    }

    /// Collapse runs of whitespace (left behind after token stripping) into single spaces.
    private static func collapseWhitespace(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
