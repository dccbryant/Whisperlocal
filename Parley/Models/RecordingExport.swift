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
        if let title = recording.title, !title.isEmpty {
            return "Parley · \(title)"
        }
        let date = DateFormatter.localizedString(from: recording.createdAt, dateStyle: .medium, timeStyle: .short)
        return "Parley recording — \(date)"
    }

    /// Plain text body. Designed to read well across every share destination:
    ///   - Apple Mail / Outlook respect single blank lines.
    ///   - Notes / Messages / Slack respect newlines.
    ///   - Gmail's iOS compose collapses all whitespace, so we include visible separator
    ///     characters (──────) that survive collapse and keep section structure visible.
    static func body(for recording: Recording) -> String {
        var lines: [String] = []

        if let title = recording.title, !title.isEmpty {
            lines.append("PARLEY · \(title.uppercased())")
            lines.append("\(dateFormatter.string(from: recording.createdAt)) · \(formatDuration(recording.duration))")
        } else {
            lines.append("PARLEY · \(dateFormatter.string(from: recording.createdAt)) · \(formatDuration(recording.duration))")
        }
        lines.append("")

        if let summary = recording.summary, !summary.isEmpty {
            lines.append("────── SUMMARY ──────")
            lines.append(summary)
            lines.append("")
        }

        if !recording.segments.isEmpty {
            lines.append("────── TRANSCRIPT ──────")
            for seg in recording.segments {
                lines.append("\(recording.displayName(for: seg.speakerLabel)): \(seg.text)")
            }
        }

        // Strip any trailing blank line.
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
