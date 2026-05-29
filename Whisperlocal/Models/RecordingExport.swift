import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Produces human-friendly representations of a Recording for the share sheet.
///
/// Two outputs:
///   - `body(for:)`     — structured plain text with double newlines so paragraph breaks
///                        survive iOS Mail's whitespace normalization and read cleanly in
///                        Messages, Notes, Slack, etc.
///   - `html(for:)`     — semantic HTML used by Mail (and any other receiver that prefers
///                        rich text), preserving headings and speaker structure.
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

    // MARK: - Plain text

    /// Plain text body. Uses double newlines between every logical section because iOS Mail
    /// (and several other plain-text composers) collapse single newlines into spaces.
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

        // Double newlines between major sections — survives Mail's normalization.
        return parts.joined(separator: "\n\n\n")
    }

    // MARK: - HTML

    /// Self-contained HTML document. Mail.app and Gmail render this with full structure.
    static func html(for recording: Recording) -> String {
        var body = """
        <h2 style="margin:0 0 4px 0;font-family:-apple-system,system-ui,sans-serif;">Whisperlocal</h2>
        <p style="margin:0 0 20px 0;font-family:-apple-system,system-ui,sans-serif;color:#555;">
          <strong>\(escape(dateFormatter.string(from: recording.createdAt)))</strong><br>
          Duration: \(escape(formatDuration(recording.duration)))
        </p>
        """

        if let summary = recording.summary, !summary.isEmpty {
            body += """
            <h3 style="margin:0 0 8px 0;font-family:-apple-system,system-ui,sans-serif;text-transform:uppercase;letter-spacing:1.5px;font-size:12px;color:#666;">Summary</h3>
            <p style="margin:0 0 24px 0;font-family:-apple-system,system-ui,sans-serif;line-height:1.5;">\(escape(summary))</p>
            """
        }

        if !recording.segments.isEmpty {
            body += """
            <h3 style="margin:0 0 12px 0;font-family:-apple-system,system-ui,sans-serif;text-transform:uppercase;letter-spacing:1.5px;font-size:12px;color:#666;">Transcript</h3>
            """
            for seg in recording.segments {
                body += """
                <p style="margin:0 0 16px 0;font-family:-apple-system,system-ui,sans-serif;line-height:1.5;">
                  <strong style="color:#e74a1c;">\(escape(seg.speakerLabel))</strong><br>
                  \(escape(seg.text))
                </p>
                """
            }
        }

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="background:#f1ece0;color:#252525;padding:20px;">
        \(body)
        </body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Transferable wrapper so ShareLink can offer both HTML (rich destinations) and plain text
/// (everything else) from one item. iOS Mail picks HTML; Messages/Notes/Slack get plain text.
struct RecordingShareItem: Transferable {
    let recording: Recording

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .html) { item in
            Data(RecordingExport.html(for: item.recording).utf8)
        }
        DataRepresentation(exportedContentType: .plainText) { item in
            Data(RecordingExport.body(for: item.recording).utf8)
        }
    }
}
