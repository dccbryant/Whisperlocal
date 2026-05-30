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
        await process(audioURL: url, duration: duration, createdAt: Date())
    }

    /// Process an audio file the user imported from Files / share sheet. The audio file is
    /// expected to already live inside the library's Recordings directory.
    func processImported(audioURL: URL, createdAt: Date) async {
        let duration = AudioFileReader.duration(of: audioURL) ?? 0
        await process(audioURL: audioURL, duration: duration, createdAt: createdAt)
    }

    private func process(audioURL url: URL, duration: TimeInterval, createdAt: Date) async {
        var rec = Recording(
            id: UUID(),
            audioFilename: url.lastPathComponent,
            createdAt: createdAt,
            duration: duration
        )

        stage = .transcribing
        do {
            let segments = try await transcriber.transcribe(audioAt: url)
            rec.segments = segments

            stage = .summarizing
            rec.summary = try await summarizer.summarize(rec.flatTranscript)
            rec.title = (try? await summarizer.title(for: rec.flatTranscript))

            library.save(rec)
            lastCompleted = rec
            stage = .done
        } catch {
            stage = .failed("Processing failed: \(error.localizedDescription)")
        }
    }

    func reset() {
        lastCompleted = nil
        stage = .idle
    }
}
