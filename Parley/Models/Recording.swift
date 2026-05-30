import Foundation

struct TranscriptSegment: Identifiable, Hashable, Codable {
    var id = UUID()
    /// Raw speaker label as produced by SpeakerKit (e.g. "Speaker 1"). Stable across edits.
    let speakerLabel: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct Recording: Identifiable, Hashable, Codable {
    let id: UUID
    /// Filename only (relative to the Recordings directory). Absolute paths are not stable
    /// across app installs on iOS, so we reconstruct the URL on demand.
    let audioFilename: String
    let createdAt: Date
    var duration: TimeInterval
    var segments: [TranscriptSegment] = []
    var summary: String?
    /// User-supplied display names mapped from raw speaker labels: ["Speaker 1": "Sarah"].
    var customSpeakerNames: [String: String] = [:]

    func audioURL(in recordingsDir: URL) -> URL {
        recordingsDir.appendingPathComponent(audioFilename)
    }

    /// Display name for a speaker label, falling back to the raw label.
    func displayName(for speakerLabel: String) -> String {
        customSpeakerNames[speakerLabel] ?? speakerLabel
    }

    /// Distinct raw speaker labels in first-appearance order.
    var distinctSpeakerLabels: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for seg in segments where seen.insert(seg.speakerLabel).inserted {
            ordered.append(seg.speakerLabel)
        }
        return ordered
    }

    /// Flat transcript text with display names (used for summarization input + share).
    var flatTranscript: String {
        segments.map { "\(displayName(for: $0.speakerLabel)): \($0.text)" }.joined(separator: "\n")
    }

    /// Lowercased blob used for substring search across the library.
    var searchableText: String {
        var parts: [String] = []
        if let summary { parts.append(summary) }
        for seg in segments {
            parts.append(displayName(for: seg.speakerLabel))
            parts.append(seg.text)
        }
        return parts.joined(separator: " ").lowercased()
    }
}
