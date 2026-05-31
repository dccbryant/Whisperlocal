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
    /// 0…1 progress within the current stage (.transcribing or .summarizing). nil between stages.
    @Published var stageProgress: Double?
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
        stageProgress = 0
        do {
            let segments = try await transcriber.transcribe(audioAt: url) { [weak self] p in
                Task { @MainActor [weak self] in self?.stageProgress = p }
            }
            let transcriptText = segments
                .map { "\($0.speakerLabel): \($0.text)" }
                .joined(separator: "\n")

            stage = .summarizing
            stageProgress = 0
            // Budget within .summarizing: summarize 0…0.5, title 0.5…0.55, extract 0.55…1.0.
            let summary = try await summarizer.summarize(transcriptText) { [weak self] p in
                Task { @MainActor [weak self] in self?.stageProgress = p * 0.5 }
            }
            stageProgress = 0.5
            let title = try? await summarizer.title(for: transcriptText)
            stageProgress = 0.55
            let extraction = (try? await summarizer.extract(from: transcriptText) { [weak self] p in
                Task { @MainActor [weak self] in self?.stageProgress = 0.55 + p * 0.45 }
            }) ?? .empty
            stageProgress = 1.0

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
            rec.decisions = extraction.decisions
            rec.actionItems = extraction.actionItems

            library.save(rec)
            lastCompleted = rec
            stageProgress = nil
            stage = .done
        } catch {
            try? FileManager.default.removeItem(at: url)
            stageProgress = nil
            stage = .failed("Processing failed: \(error.localizedDescription)")
        }
    }

    func reset() {
        lastCompleted = nil
        stage = .idle
    }
}
