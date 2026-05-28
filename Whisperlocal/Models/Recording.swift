import Foundation

struct TranscriptSegment: Identifiable, Hashable {
    let id = UUID()
    let speakerLabel: String   // e.g. "Speaker 1"
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct Recording: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let createdAt: Date
    var duration: TimeInterval
    var segments: [TranscriptSegment] = []
    var summary: String?

    /// Flat transcript text (speaker labels prefixed) for sharing/summarizing.
    var flatTranscript: String {
        segments.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
    }
}
