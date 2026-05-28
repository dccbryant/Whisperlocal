import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header
                switch session.modelState {
                case .ready:
                    recordButton
                    statusView
                    if let current = session.current {
                        ResultView(recording: current)
                    } else {
                        Spacer()
                    }
                case .loading:
                    modelLoadingView
                    Spacer()
                case .failed(let message):
                    modelFailedView(message: message)
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("Whisperlocal")
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("On-device transcription & summary")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Nothing leaves your phone.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var modelLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Preparing on-device models…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("First launch downloads the Whisper + speaker models. After that, everything runs offline.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)
        }
    }

    private func modelFailedView(message: String) -> some View {
        VStack(spacing: 12) {
            Label("Model load failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Try again") {
                Task { await session.loadModel() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                if session.recorder.isRecording {
                    await session.stopAndProcess()
                } else {
                    session.reset()
                    await session.startRecording()
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(session.recorder.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 120, height: 120)
                Image(systemName: session.recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(processingDisabled)
    }

    private var processingDisabled: Bool {
        switch session.stage {
        case .transcribing, .summarizing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch session.stage {
        case .idle:
            Text("Tap to record")
                .foregroundStyle(.secondary)
        case .recording:
            VStack(spacing: 6) {
                Text(String(format: "Recording  %.1fs", session.recorder.elapsed))
                    .monospacedDigit()
                    .foregroundStyle(.red)
                LevelMeter(peakDB: session.recorder.peakLevel)
                    .frame(width: 200, height: 8)
                Text(String(format: "peak: %.0f dB", session.recorder.peakLevel))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .transcribing:
            HStack { ProgressView(); Text("Identifying speakers & transcribing…") }
        case .summarizing:
            HStack { ProgressView(); Text("Summarizing on device…") }
        case .done:
            Text("Done")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }
}

struct ResultView: View {
    let recording: Recording

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                if let summary = recording.summary {
                    section(title: "Summary", body: { Text(summary).font(.body).textSelection(.enabled) })
                }
                if !recording.segments.isEmpty {
                    section(title: "Transcript", body: { transcriptBody })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.dateFormatter.string(from: recording.createdAt))
                    .font(.subheadline.weight(.medium))
                Text(String(format: "%.0fs recording", recording.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: shareText, subject: Text("Whisperlocal recording")) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
        }
    }

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(recording.segments) { seg in
                VStack(alignment: .leading, spacing: 2) {
                    Text(seg.speakerLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(seg.text)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            body()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var shareText: String {
        var lines: [String] = []
        lines.append("Whisperlocal — \(Self.dateFormatter.string(from: recording.createdAt))")
        lines.append("")
        if let summary = recording.summary {
            lines.append("Summary")
            lines.append(summary)
            lines.append("")
        }
        if !recording.segments.isEmpty {
            lines.append("Transcript")
            for seg in recording.segments {
                lines.append("\(seg.speakerLabel): \(seg.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct LevelMeter: View {
    let peakDB: Float

    private var fraction: Double {
        let clamped = max(-60, min(0, peakDB))
        return Double((clamped + 60) / 60)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * fraction)
                    .animation(.easeOut(duration: 0.1), value: fraction)
            }
        }
    }
}

#Preview {
    RootView().environmentObject(SessionStore())
}
