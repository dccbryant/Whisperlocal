import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording

    @EnvironmentObject private var library: RecordingStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlayer()
    @State private var renameTarget: String?     // raw speaker label being edited
    @State private var renameDraft: String = ""

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    /// The recording as it currently exists in the library so edits persist + reflect.
    private var current: Recording {
        library.recordings.first(where: { $0.id == recording.id }) ?? recording
    }

    var body: some View {
        ZStack {
            BraunPalette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    playerBar
                    if let summary = current.summary, !summary.isEmpty {
                        BraunCard(title: "Summary") {
                            Text(summary).braunBody().textSelection(.enabled)
                        }
                    }
                    if !current.segments.isEmpty {
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
                    item: RecordingExport.body(for: current),
                    subject: Text(RecordingExport.subject(for: current))
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(BraunPalette.foreground)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    library.delete(current)
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(BraunPalette.foreground)
                }
            }
        }
        .onAppear {
            player.load(current.audioURL(in: library.directory))
        }
        .onDisappear {
            player.stop()
        }
        .alert("Rename speaker", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameDraft)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") { commitRename() }
        } message: {
            if let raw = renameTarget {
                Text("Replace \"\(raw)\" with a custom name. Leave blank to reset.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.fullDate.string(from: current.createdAt))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(BraunPalette.foreground)
            HStack(spacing: 14) {
                Text(durationText(current.duration)).braunLabel()
                let speakers = current.distinctSpeakerLabels.count
                if speakers > 0 {
                    Text("\(speakers) speaker\(speakers == 1 ? "" : "s")").braunLabel()
                }
            }
        }
    }

    // MARK: - Player

    private var playerBar: some View {
        HStack(spacing: 14) {
            Button {
                if player.isPlaying { player.pause() } else { player.play() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(BraunPalette.foreground)
                    .frame(width: 44, height: 44)
                    .background(Rectangle().stroke(BraunPalette.foreground, lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                progressBar
                HStack {
                    Text(mmss(player.currentTime)).braunDigit(size: 11)
                    Spacer()
                    Text(mmss(player.duration > 0 ? player.duration : current.duration))
                        .braunDigit(size: 11)
                        .foregroundStyle(BraunPalette.secondary)
                }
            }
        }
        .padding(16)
        .background(BraunPalette.surface)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let total = max(player.duration, 0.01)
            let fraction = min(1, max(0, player.currentTime / total))
            ZStack(alignment: .leading) {
                Rectangle().fill(BraunPalette.divider).frame(height: 2)
                Rectangle()
                    .fill(BraunPalette.foreground)
                    .frame(width: geo.size.width * fraction, height: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onEnded { v in
                    let pct = max(0, min(1, v.location.x / geo.size.width))
                    player.seek(to: pct * total)
                }
            )
        }
        .frame(height: 16)
    }

    // MARK: - Transcript

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(current.segments) { seg in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Button {
                            beginRename(rawLabel: seg.speakerLabel)
                        } label: {
                            HStack(spacing: 4) {
                                Text(current.displayName(for: seg.speakerLabel)).braunLabel(size: 10)
                                Image(systemName: "pencil")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(BraunPalette.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Text(timeRange(seg)).braunDigit(size: 10).foregroundStyle(BraunPalette.secondary)
                    }
                    Text(seg.text).braunBody().textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Rename

    private func beginRename(rawLabel: String) {
        renameTarget = rawLabel
        renameDraft = current.customSpeakerNames[rawLabel] ?? ""
    }

    private func commitRename() {
        guard let raw = renameTarget else { return }
        var updated = current
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            updated.customSpeakerNames.removeValue(forKey: raw)
        } else {
            updated.customSpeakerNames[raw] = trimmed
        }
        library.save(updated)
        renameTarget = nil
        renameDraft = ""
    }

    // MARK: - Formatting

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
