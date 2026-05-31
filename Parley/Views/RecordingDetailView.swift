import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording

    @EnvironmentObject private var library: RecordingStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlayer()
    @State private var renameTarget: String?     // raw speaker label being edited
    @State private var renameDraft: String = ""
    /// Path to a decrypted plaintext copy of the audio, written into NSTemporaryDirectory
    /// on view appear and removed on disappear. Audio playback and waveform rendering both
    /// stream from this URL — the encrypted file on disk is never read by AVFoundation.
    @State private var stagedAudioURL: URL?

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
                    if !current.decisions.isEmpty {
                        BraunCard(title: "Decisions") {
                            decisionsBody
                        }
                    }
                    if !current.actionItems.isEmpty {
                        BraunCard(title: "Action items") {
                            actionItemsBody
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
        .task(id: current.id) {
            await stageAudio()
        }
        .onDisappear {
            player.stop()
            EncryptedStore.cleanupStagedAudio(stagedAudioURL)
            stagedAudioURL = nil
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
            if let title = current.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(BraunPalette.foreground)
            }
            Text(Self.fullDate.string(from: current.createdAt))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BraunPalette.secondary)
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
        VStack(spacing: 12) {
            if let url = stagedAudioURL {
                WaveformView(
                    url: url,
                    progress: playbackFraction,
                    onSeek: { fraction in
                        let total = max(player.duration, current.duration)
                        player.seek(to: fraction * total)
                    }
                )
                .frame(height: 56)
            } else {
                Rectangle()
                    .fill(BraunPalette.divider.opacity(0.3))
                    .frame(height: 56)
            }

            HStack(spacing: 14) {
                Button {
                    if player.isPlaying { player.pause() } else { player.play() }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(stagedAudioURL == nil ? BraunPalette.secondary : BraunPalette.foreground)
                        .frame(width: 44, height: 44)
                        .background(Rectangle().stroke(stagedAudioURL == nil ? BraunPalette.divider : BraunPalette.foreground, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(stagedAudioURL == nil)

                Spacer()

                Text(mmss(player.currentTime)).braunDigit(size: 12)
                Text("/").braunDigit(size: 12).foregroundStyle(BraunPalette.secondary)
                Text(mmss(player.duration > 0 ? player.duration : current.duration))
                    .braunDigit(size: 12)
                    .foregroundStyle(BraunPalette.secondary)
            }
        }
        .padding(16)
        .background(BraunPalette.surface)
    }

    private var playbackFraction: Double {
        let total = max(player.duration, 0.01)
        return min(1, max(0, player.currentTime / total))
    }

    // MARK: - Decisions / Action items

    private var decisionsBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(current.decisions, id: \.self) { d in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("·").braunBody()
                    Text(d).braunBody().textSelection(.enabled)
                }
            }
        }
    }

    private var actionItemsBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(current.actionItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.assignee).braunLabel(size: 10).foregroundStyle(BraunPalette.accent)
                        if let due = item.dueDate, !due.isEmpty {
                            Text("· \(due)").braunLabel(size: 10).foregroundStyle(BraunPalette.secondary)
                        }
                    }
                    Text(item.task).braunBody().textSelection(.enabled)
                }
            }
        }
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

    // MARK: - Audio staging

    private func stageAudio() async {
        // Clean any prior staging (e.g. user navigated between recordings).
        EncryptedStore.cleanupStagedAudio(stagedAudioURL)
        let encryptedURL = current.audioURL(in: library.directory)
        let staged: URL? = await Task.detached(priority: .userInitiated) {
            do {
                return try EncryptedStore.stageAudio(from: encryptedURL)
            } catch {
                print("[Detail] failed to stage audio: \(error)")
                return nil
            }
        }.value
        stagedAudioURL = staged
        if let staged { player.load(staged) }
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
