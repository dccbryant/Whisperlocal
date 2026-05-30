import Combine
import Foundation
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    enum Stage: Equatable {
        case idle
        case recording
        case transcribing
        case summarizing
        case done
        case failed(String)
    }

    enum ModelState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published var stage: Stage = .idle
    @Published var modelState: ModelState = .loading
    /// The recording produced by the most recent record→process cycle. Cleared on next record.
    @Published var lastCompleted: Recording?

    let recorder = AudioRecorder()
    let library: RecordingStore
    let summarizer: SummarizationService

    private let transcriber = DiarizingTranscriptionService()
    private let activity = RecordingActivityManager()
    private var recordingStartedAt: Date?
    private var cancellables = Set<AnyCancellable>()

    init(library: RecordingStore, summarizer: SummarizationService = SummarizationFactory.make()) {
        self.library = library
        self.summarizer = summarizer

        recorder.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                if let started = self.recordingStartedAt, self.recorder.isRecording {
                    self.activity.update(startedAt: started, peakLevel: self.recorder.peakLevel)
                }
            }
            .store(in: &cancellables)

        Task { await loadModel() }
    }

    func loadModel() async {
        modelState = .loading
        do {
            try await transcriber.load()
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    func startRecording() async {
        do {
            _ = try await recorder.start()
            let started = Date()
            recordingStartedAt = started
            activity.start(at: started)
            lastCompleted = nil
            stage = .recording
        } catch {
            stage = .failed("Could not start recording: \(error.localizedDescription)")
        }
    }

    func stopAndProcess() async {
        let duration = recorder.elapsed
        guard let url = recorder.stop() else {
            activity.end()
            recordingStartedAt = nil
            stage = .idle
            return
        }
        activity.end()
        recordingStartedAt = nil
        await process(plaintextAudioURL: url, duration: duration, createdAt: Date())
    }

    /// Process an audio file imported from Files / share sheet. Same pipeline as a fresh
    /// recording but starts from a plaintext file we copy in.
    func processImported(audioURL: URL, createdAt: Date) async {
        let duration = AudioFileReader.duration(of: audioURL) ?? 0
        await process(plaintextAudioURL: audioURL, duration: duration, createdAt: createdAt)
    }

    /// Pipeline: read plaintext audio from a temp location, transcribe + summarize from it,
    /// then encrypt into the library and delete the plaintext. The transcription pass works
    /// on the plaintext so we don't pay decrypt cost for the analysis path.
    private func process(plaintextAudioURL url: URL, duration: TimeInterval, createdAt: Date) async {
        stage = .transcribing
        do {
            let segments = try await transcriber.transcribe(audioAt: url)

            stage = .summarizing
            let summary = try await summarizer.summarize(
                segments.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
            )
            let title = try? await summarizer.title(
                for: segments.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
            )

            let filename = try library.ingestAudio(from: url)
            var rec = Recording(
                id: UUID(),
                audioFilename: filename,
                createdAt: createdAt,
                duration: duration
            )
            rec.segments = segments
            rec.summary = summary
            rec.title = title

            library.save(rec)
            lastCompleted = rec
            stage = .done
        } catch {
            // Leave the plaintext temp file alone on failure so the user could retry — but
            // the simpler default is to clean it up.
            try? FileManager.default.removeItem(at: url)
            stage = .failed("Processing failed: \(error.localizedDescription)")
        }
    }

    func reset() {
        lastCompleted = nil
        stage = .idle
    }
}
