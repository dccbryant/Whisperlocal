import Foundation

/// Produces a human-friendly text representation of a Recording for the share sheet.
/// Designed to read cleanly in Mail, Messages, Notes, Slack, and Gmail — uses uppercase
/// section headers and consistent spacing rather than Markdown (which renders inconsistently
/// across these apps).
enum RecordingExport {

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full        // "Thursday, May 28, 2026"
        f.timeStyle = .short       // "9:16 PM"
        return f
    }()

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let m = s / 60
        let r = s % 60
        return m > 0 ? String(format: "%d:%02d", m, r) : String(format: "0:%02d", r)
    }

    /// Subject line for Mail / message channels.
    static func subject(for recording: Recording) -> String {
        let date = DateFormatter.localizedString(from: recording.createdAt, dateStyle: .medium, timeStyle: .short)
        return "Whisperlocal recording — \(date)"
    }

    /// Full body, with header, summary, and transcript sections.
    static func body(for recording: Recording) -> String {
        var lines: [String] = []

        lines.append("WHISPERLOCAL")
        lines.append(dateFormatter.string(from: recording.createdAt))
        lines.append("Duration: \(formatDuration(recording.duration))")
        lines.append("")
        lines.append("———")
        lines.append("")

        if let summary = recording.summary, !summary.isEmpty {
            lines.append("SUMMARY")
            lines.append("")
            lines.append(summary)
            lines.append("")
            lines.append("———")
            lines.append("")
        }

        if !recording.segments.isEmpty {
            lines.append("TRANSCRIPT")
            lines.append("")
            for seg in recording.segments {
                lines.append("\(seg.speakerLabel):")
                lines.append(seg.text)
                lines.append("")
            }
        }

        // Strip the trailing blank line so the body doesn't end with whitespace.
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
