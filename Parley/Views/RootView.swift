import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var library: RecordingStore
    @State private var showIconExporter = false
    @State private var showAbout = false
    @State private var showFeedbackPrompt = false

    var body: some View {
        NavigationStack {
            ZStack {
                BraunPalette.background.ignoresSafeArea()
                // Shake-to-feedback. The detector view controller lives behind everything,
                // becomes first responder on appear, and posts onShake on a device shake.
                ShakeDetector { showFeedbackPrompt = true }
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    titleBar
                    BraunDivider()
                    Spacer(minLength: 24)
                    mainArea
                    Spacer(minLength: 24)
                    BraunDivider()
                    bottomBar
                }
            }
            .navigationDestination(for: Recording.self) { rec in
                RecordingDetailView(recording: rec)
            }
            .navigationDestination(for: LibraryRoute.self) { _ in
                LibraryView()
            }
            .sheet(isPresented: $showIconExporter) {
                IconExportSheet()
            }
            .sheet(isPresented: $showAbout) {
                NavigationStack { AboutView() }
            }
            .onOpenURL { url in
                // Audio file opened from Files / share sheet / "Open in Parley".
                Task { await importExternalAudio(from: url, session: session, library: library) }
            }
            .alert("Send feedback?", isPresented: $showFeedbackPrompt) {
                Button("Cancel", role: .cancel) { }
                Button("Open Mail") { FeedbackComposer.open() }
            } message: {
                Text("Opens an email to the author with your device details pre-filled. Add what you'd like to share and send.")
            }
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack {
            Text("Parley")
                .braunLabel(size: 11)
                .onLongPressGesture(minimumDuration: 0.6) {
                    showIconExporter = true
                }
            Spacer()
            Button {
                showAbout = true
            } label: {
                Text("About")
                    .braunLabel(size: 11)
                    .foregroundStyle(BraunPalette.foreground)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Main

    @ViewBuilder
    private var mainArea: some View {
        switch session.modelState {
        case .ready: recordingArea
        case .loading: loadingArea
        case .failed(let message): failedArea(message: message)
        }
    }

    private var recordingArea: some View {
        VStack(spacing: 28) {
            recordDial
            statusLine
            // Resolve the cached lastCompleted against the live library on every render —
            // if the user deleted it, the chip disappears (and tapping it never opens a
            // detail view for a recording that no longer exists).
            if let cached = session.lastCompleted,
               session.stage == .done,
               let live = library.recordings.first(where: { $0.id == cached.id }) {
                NavigationLink(value: live) {
                    lastRecordingChip(live)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.top, 4)
            }
        }
    }

    private var recordDial: some View {
        let isRec = session.recorder.isRecording
        return Button {
            Task {
                if isRec {
                    await session.stopAndProcess()
                } else {
                    await session.startRecording()
                }
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(BraunPalette.foreground, lineWidth: 1.5)
                    .frame(width: 168, height: 168)
                Circle()
                    .fill(isRec ? BraunPalette.recording : BraunPalette.accent)
                    .frame(width: 132, height: 132)
                if isRec {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white)
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(processingDisabled)
        .opacity(processingDisabled ? 0.5 : 1)
    }

    private var processingDisabled: Bool {
        switch session.stage {
        case .transcribing, .summarizing: return true
        default: return false
        }
    }

    private func processingRow(label: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(label).braunLabel()
                if let p = session.stageProgress {
                    Text("\(Int(p * 100))%")
                        .braunDigit(size: 11)
                        .foregroundStyle(BraunPalette.secondary)
                }
            }
            if let p = session.stageProgress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(BraunPalette.divider)
                        Rectangle()
                            .fill(BraunPalette.foreground)
                            .frame(width: geo.size.width * CGFloat(p))
                            .animation(.easeOut(duration: 0.2), value: p)
                    }
                }
                .frame(width: 220, height: 2)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            switch session.stage {
            case .idle:
                Text("Tap to record").braunLabel()
            case .recording:
                VStack(spacing: 10) {
                    if session.recorder.isPaused {
                        Text("Paused").braunLabel(size: 11).foregroundStyle(BraunPalette.recording)
                    }
                    Text(Self.formatElapsed(session.recorder.elapsed))
                        .font(.system(size: 28, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(BraunPalette.foreground)
                    BraunLevelMeter(peakDB: session.recorder.peakLevel)
                        .frame(width: 220, height: 6)
                        .opacity(session.recorder.isPaused ? 0.4 : 1)
                }
            case .transcribing:
                processingRow(label: "Transcribing")
            case .summarizing:
                processingRow(label: "Summarizing")
            case .done:
                Text("Saved").braunLabel()
            case .failed(let m):
                Text(m).font(.system(size: 12)).foregroundStyle(BraunPalette.recording).multilineTextAlignment(.center)
            }
        }
        // Fixed-height container keeps the record dial above from shifting up/down as the
        // status content swaps between a single line ("Tap to record") and the multi-line
        // recording/processing UI. Height set to fit the tallest state (paused recording).
        .frame(height: 96)
    }

    /// Format an elapsed-time interval as HH:MM:SS (always three groups).
    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func lastRecordingChip(_ rec: Recording) -> some View {
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Latest recording").braunLabel(size: 9)
                Text(rec.title ?? rec.summary ?? "Untitled recording")
                    .braunBody()
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BraunPalette.secondary)
        }
        .padding(16)
        .background(BraunPalette.surface)
    }

    private var loadingArea: some View {
        VStack(spacing: 14) {
            ProgressView().tint(BraunPalette.foreground)
            Text("Preparing models").braunLabel()
            Text("First launch downloads the speech and speaker models.")
                .font(.system(size: 11))
                .foregroundStyle(BraunPalette.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func failedArea(message: String) -> some View {
        VStack(spacing: 12) {
            Text("Models unavailable").braunLabel()
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(BraunPalette.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button { Task { await session.loadModel() } } label: {
                Text("Retry").braunLabel().padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Rectangle().stroke(BraunPalette.foreground, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            NavigationLink(value: LibraryRoute.list) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .medium))
                    Text("Library").braunLabel(size: 11)
                    if !library.recordings.isEmpty {
                        Text("\(library.recordings.count)")
                            .braunDigit(size: 11)
                            .foregroundStyle(BraunPalette.secondary)
                    }
                }
                .foregroundStyle(BraunPalette.foreground)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("On-device only").braunLabel(size: 11)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

}

/// Shared helper used by RootView's onOpenURL and by LibraryView's Import button.
@MainActor
func importExternalAudio(
    from sourceURL: URL,
    session: SessionStore,
    library: RecordingStore
) async -> String? {
    guard session.modelState == .ready else {
        return "Models are still loading. Try again in a moment."
    }
    let needsScope = sourceURL.startAccessingSecurityScopedResource()
    defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

    // Copy into temp, not the library directory. The processing pipeline reads from a
    // plaintext temp file and then encrypts into the library; if we copied directly into
    // the library, ingestAudio would encrypt the file in place and then delete the same
    // path it just wrote to — losing the audio entirely.
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ParleyImport", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let destination = tempDir.appendingPathComponent("\(name)-\(sourceURL.lastPathComponent)")
    do {
        try FileManager.default.copyItem(at: sourceURL, to: destination)
    } catch {
        return "Could not copy file: \(error.localizedDescription)"
    }
    await session.processImported(audioURL: destination, createdAt: Date())
    return nil
}

enum LibraryRoute: Hashable { case list }

struct BraunLevelMeter: View {
    let peakDB: Float

    private var fraction: Double {
        let clamped = max(-60, min(0, peakDB))
        return Double((clamped + 60) / 60)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(BraunPalette.divider)
                Rectangle()
                    .fill(BraunPalette.foreground)
                    .frame(width: geo.size.width * fraction)
                    .animation(.easeOut(duration: 0.1), value: fraction)
            }
        }
    }
}

#Preview {
    let lib = RecordingStore()
    RootView()
        .environmentObject(SessionStore(library: lib))
        .environmentObject(lib)
        .preferredColorScheme(.light)
}
