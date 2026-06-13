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
        // Up to 3 attempts with backoff. The on-device model files can fail to load on
        // first launch if the Hugging Face download is interrupted or the CoreML compile
        // step is starved; a retry almost always succeeds.
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await transcriber.load()
                modelState = .ready
                return
            } catch {
                lastError = error
                if attempt < 3 {
                    let backoff = UInt64(attempt) * 2_000_000_000
                    try? await Task.sleep(nanoseconds: backoff)
                }
            }
        }
        let message = lastError?.localizedDescription ?? "Unknown error."
        modelState = .failed("Could not load the on-device speech models. \(message)")
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
            // analyze() does the four sub-passes (summary, attendees, topics, action items)
            // and gets 0…0.9 of the bar; title() rounds it out from 0.9 to 1.0.
            let extraction = (try? await summarizer.analyze(transcriptText) { [weak self] p in
                Task { @MainActor [weak self] in self?.stageProgress = p * 0.9 }
            }) ?? .empty
            stageProgress = 0.9
            let title = try? await summarizer.title(for: transcriptText)
            stageProgress = 1.0

            // If every Apple FM call came back empty, the on-device model was almost
            // certainly transiently unavailable. Don't save a stub recording silently —
            // surface .failed so the user gets a Try Again button.
            let everythingFailed = extraction.summary.isEmpty
                && extraction.attendees.isEmpty
                && extraction.topics.isEmpty
                && extraction.actionItems.isEmpty
                && title == nil
            if everythingFailed {
                try? FileManager.default.removeItem(at: url)
                stageProgress = nil
                stage = .failed("Apple Intelligence was busy. Tap Try Again — your recording can be re-imported.")
                return
            }

            let filename = try library.ingestAudio(from: url)
            var rec = Recording(
                id: UUID(),
                audioFilename: filename,
                createdAt: createdAt,
                duration: duration
            )
            // Explicit clean slate. Swift's stored-property defaults already give us empty
            // collections and nil optionals, but spelling it out kills any chance that a
            // future refactor leaves stale fields visible across recordings.
            rec.segments = []
            rec.summary = nil
            rec.title = nil
            rec.attendees = []
            rec.topics = []
            rec.decisions = []
            rec.actionItems = []
            rec.openQuestions = []
            rec.keyDates = []
            rec.customSpeakerNames = [:]

            rec.segments = segments
            rec.summary = extraction.summary.isEmpty ? nil : extraction.summary
            rec.title = title
            rec.attendees = extraction.attendees
            rec.topics = extraction.topics
            rec.actionItems = extraction.actionItems
            // Decisions, open questions, and key dates have been removed from the
            // extraction pipeline. Fields stay on the Recording struct for Codable
            // compat with older saved recordings; never populated on new ones.
            rec.decisions = []
            rec.openQuestions = []
            rec.keyDates = []

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
