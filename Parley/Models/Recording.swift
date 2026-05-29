import Foundation

struct TranscriptSegment: Identifiable, Hashable, Codable {
    var id = UUID()
    let speakerLabel: String   // e.g. "Speaker 1"
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

    func audioURL(in recordingsDir: URL) -> URL {
        recordingsDir.appendingPathComponent(audioFilename)
    }

    /// Flat transcript text (speaker labels prefixed) for use as the summarizer input.
    var flatTranscript: String {
        segments.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
    }
}
