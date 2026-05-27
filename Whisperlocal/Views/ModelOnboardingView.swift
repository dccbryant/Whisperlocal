import SwiftUI

struct ModelOnboardingView: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject var downloader: ModelDownloader

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("One-time model download")
                .font(.title2).bold()

            Text("Whisperlocal needs a ~190 MB speech model. After this download, transcription runs entirely on your phone — no audio ever leaves the device.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            content
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch downloader.state {
        case .idle:
            Button {
                downloader.start()
            } label: {
                Label("Download model (190 MB)", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .downloading(let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .destructive) { downloader.cancel() }
            }
            .padding(.horizontal)

        case .finished:
            Label("Model ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .onAppear { session.refreshTranscriberIfReady() }

        case .failed(let message):
            VStack(spacing: 8) {
                Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try again") { downloader.start() }
                    .buttonStyle(.bordered)
            }
        }
    }
}
