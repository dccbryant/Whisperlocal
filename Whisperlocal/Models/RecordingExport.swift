import Foundation

/// Produces a human-friendly plain-text representation of a Recording for the share sheet.
///
/// Plain text only — iOS Mail's share extension turned out to mishandle Transferable items
/// that exposed an HTML alternative (delivered an empty compose). With pure plain text +
/// double-newline paragraph breaks, every share destination we tested (Notes, Messages,
/// Mail, Gmail, Slack) preserves the formatting.
enum RecordingExport {

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let m = s / 60
        let r = s % 60
        return m > 0 ? String(format: "%d:%02d", m, r) : String(format: "0:%02d", r)
    }

    static func subject(for recording: Recording) -> String {
        let date = DateFormatter.localizedString(from: recording.createdAt, dateStyle: .medium, timeStyle: .short)
        return "Whisperlocal recording — \(date)"
    }

    /// Plain text body. Uses double newlines between every logical section because plain-text
    /// composers (notably iOS Mail) collapse single newlines into spaces.
    static func body(for recording: Recording) -> String {
        var parts: [String] = []

        parts.append("""
        WHISPERLOCAL
        \(dateFormatter.string(from: recording.createdAt))
        Duration: \(formatDuration(recording.duration))
        """)

        if let summary = recording.summary, !summary.isEmpty {
            parts.append("SUMMARY\n\n\(summary)")
        }

        if !recording.segments.isEmpty {
            var transcriptLines: [String] = ["TRANSCRIPT"]
            for seg in recording.segments {
                transcriptLines.append("\(seg.speakerLabel):\n\(seg.text)")
            }
            parts.append(transcriptLines.joined(separator: "\n\n"))
        }

        return parts.joined(separator: "\n\n\n")
    }
}
