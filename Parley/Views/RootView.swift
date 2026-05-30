import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var library: RecordingStore
    @State private var showIconExporter = false
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BraunPalette.background.ignoresSafeArea()

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
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .onOpenURL { url in
                // Audio file opened from Files / share sheet / "Open in Parley".
                Task { await importExternalAudio(from: url) }
            }
            .alert("Couldn't import file", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
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
            Button { showImporter = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                    Text("Import").braunLabel(size: 11)
                }
                .foregroundStyle(BraunPalette.foreground)
            }
            .buttonStyle(.plain)
            .disabled(session.modelState != .ready)
            Spacer().frame(width: 16)
            Text(session.modelState == .ready ? "Ready" : "—").braunLabel(size: 11)
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
            if let rec = session.lastCompleted, session.stage == .done {
                NavigationLink(value: rec) {
                    lastRecordingChip(rec)
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

    @ViewBuilder
    private var statusLine: some View {
        switch session.stage {
        case .idle:
            Text("Tap to record").braunLabel()
        case .recording:
            VStack(spacing: 10) {
                if session.recorder.isPaused {
                    Text("Paused").braunLabel(size: 11).foregroundStyle(BraunPalette.recording)
                }
                Text(String(format: "%.1f s", session.recorder.elapsed))
                    .braunDigit(size: 22)
                BraunLevelMeter(peakDB: session.recorder.peakLevel)
                    .frame(width: 220, height: 6)
                    .opacity(session.recorder.isPaused ? 0.4 : 1)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().tint(BraunPalette.foreground)
                Text("Transcribing").braunLabel()
            }
        case .summarizing:
            HStack(spacing: 10) {
                ProgressView().tint(BraunPalette.foreground)
                Text("Summarizing").braunLabel()
            }
        case .done:
            Text("Saved").braunLabel()
        case .failed(let m):
            Text(m).font(.system(size: 12)).foregroundStyle(BraunPalette.recording).multilineTextAlignment(.center)
        }
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
            Text("On-device").braunLabel(size: 11)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importExternalAudio(from: url) }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func importExternalAudio(from sourceURL: URL) async {
        guard session.modelState == .ready else {
            importError = "Models are still loading. Try again in a moment."
            return
        }
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let dir = library.directory
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = dir.appendingPathComponent("\(name)-\(sourceURL.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            importError = "Could not copy file: \(error.localizedDescription)"
            return
        }
        await session.processImported(audioURL: destination, createdAt: Date())
    }
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
