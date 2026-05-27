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

    private var modelLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing on-device model…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("First launch downloads the model (~150 MB). After that, everything runs offline.")
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
            Text(String(format: "Recording  %.1fs", session.recorder.elapsed))
                .monospacedDigit()
                .foregroundStyle(.red)
        case .transcribing:
            HStack { ProgressView(); Text("Transcribing on device…") }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = recording.summary {
                    section(title: "Summary", body: summary)
                }
                if let transcript = recording.transcript {
                    section(title: "Transcript", body: transcript)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    RootView().environmentObject(SessionStore())
}
