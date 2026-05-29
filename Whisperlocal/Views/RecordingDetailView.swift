import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording

    @EnvironmentObject private var library: RecordingStore
    @Environment(\.dismiss) private var dismiss

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ZStack {
            BraunPalette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let summary = recording.summary, !summary.isEmpty {
                        BraunCard(title: "Summary") {
                            Text(summary).braunBody().textSelection(.enabled)
                        }
                    }
                    if !recording.segments.isEmpty {
                        BraunCard(title: "Transcript") {
                            transcriptBody
                        }
                    }
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Recording").braunLabel(size: 11)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: RecordingExport.body(for: recording),
                    subject: Text(RecordingExport.subject(for: recording))
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(BraunPalette.foreground)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    library.delete(recording)
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(BraunPalette.foreground)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.fullDate.string(from: recording.createdAt))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(BraunPalette.foreground)
            HStack(spacing: 14) {
                Text(durationText(recording.duration)).braunLabel()
                let speakers = Set(recording.segments.map(\.speakerLabel)).count
                if speakers > 0 {
                    Text("\(speakers) speaker\(speakers == 1 ? "" : "s")").braunLabel()
                }
            }
        }
    }

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(recording.segments) { seg in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(seg.speakerLabel).braunLabel(size: 10)
                        Text(timeRange(seg)).braunDigit(size: 10).foregroundStyle(BraunPalette.secondary)
                    }
                    Text(seg.text).braunBody().textSelection(.enabled)
                }
            }
        }
    }

    private func timeRange(_ seg: TranscriptSegment) -> String {
        String(format: "%@ – %@", mmss(seg.start), mmss(seg.end))
    }

    private func mmss(_ s: TimeInterval) -> String {
        let secs = Int(s.rounded())
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private func durationText(_ s: TimeInterval) -> String {
        let secs = Int(s.rounded())
        let m = secs / 60
        let r = secs % 60
        return m > 0 ? String(format: "%d:%02d", m, r) : String(format: "%ds", r)
    }
}
