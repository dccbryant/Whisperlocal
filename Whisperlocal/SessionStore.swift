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
    private var cancellables = Set<AnyCancellable>()

    init(library: RecordingStore, summarizer: SummarizationService = SummarizationFactory.make()) {
        self.library = library
        self.summarizer = summarizer

        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
            lastCompleted = nil
            stage = .recording
        } catch {
            stage = .failed("Could not start recording: \(error.localizedDescription)")
        }
    }

    func stopAndProcess() async {
        guard let url = recorder.stop() else {
            stage = .idle
            return
        }
        var rec = Recording(
            id: UUID(),
            audioFilename: url.lastPathComponent,
            createdAt: Date(),
            duration: recorder.elapsed
        )

        stage = .transcribing
        do {
            let segments = try await transcriber.transcribe(audioAt: url)
            rec.segments = segments

            stage = .summarizing
            let summary = try await summarizer.summarize(rec.flatTranscript)
            rec.summary = summary

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
