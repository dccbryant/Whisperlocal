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

        // Transcribe in bounded fixed-size windows rather than one giant call. A single
        // full-length transcribe hammers the ANE continuously until CoreML's ML Program
        // prediction watchdog times out. Bounded windows with a brief rest between them stay
        // safe — and it's still far fewer calls than the old per-speaker-turn slicing, so we
        // keep the speed. Whisper timestamps are window-local, so we offset them to absolute.
        let windowSamples = 120 * 16_000   // 2-minute windows
        let windowCount = max(1, Int(ceil(Double(samples.count) / Double(windowSamples))))
        let whisperStart = Date()
        var whisperSegments: [(start: Double, end: Double, text: String)] = []
        for w in 0..<windowCount {
            let startSample = w * windowSamples
            let endSample = min(samples.count, startSample + windowSamples)
            guard endSample > startSample else { break }
            let offset = Double(startSample) / 16_000
            let slice = Array(samples[startSample..<endSample])

            let results: [TranscriptionResult]
            do {
                results = try await whisper.transcribe(audioArray: slice)
            } catch {
                // ANE predictions occasionally time out transiently; rest and retry once
                // before failing the whole recording.
                print("[Timing] window \(w + 1)/\(windowCount) failed, retrying after 1s: \(error)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                results = try await whisper.transcribe(audioArray: slice)
            }

            for seg in results.flatMap({ $0.segments }) {
                whisperSegments.append((
                    start: offset + Double(seg.start),
                    end: offset + Double(seg.end),
                    text: Self.stripSpecialTokens(seg.text)
                ))
            }
            onProgress?(0.3 + 0.6 * Double(w + 1) / Double(windowCount))
            try? await Task.sleep(nanoseconds: 100_000_000)   // let the ANE breathe
        }
        let whisperElapsed = Date().timeIntervalSince(whisperStart)
        onProgress?(0.9)

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
        // whisperSegments already carry absolute timestamps and token-stripped text.
        for ws in whisperSegments {
            let label = speakerLabel(forStart: ws.start, end: ws.end)
            if label != curLabel {
                flush()
                curLabel = label
                curText = ws.text
                curStart = ws.start
                curEnd = ws.end
            } else {
                curText += ws.text
                curEnd = ws.end
            }
        }
        flush()

        onProgress?(1.0)

        let audioSeconds = Double(samples.count) / 16_000
        print(String(format: "[Timing] transcribe: audio=%.0fs, diarize=%.1fs, whisper=%.1fs (%d windows), %d whisper segs → %d turns, %d speakers, stage=%.1fs",
                     audioSeconds, diarizeElapsed, whisperElapsed, windowCount,
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
