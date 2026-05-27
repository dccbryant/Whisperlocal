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

    @Published var stage: Stage = .idle
    @Published var recordings: [Recording] = []
    @Published var current: Recording?

    let recorder = AudioRecorder()
    let transcriber: TranscriptionService
    let summarizer: SummarizationService

    init(
        transcriber: TranscriptionService = MockTranscriptionService(),
        summarizer: SummarizationService = MockSummarizationService()
    ) {
        self.transcriber = transcriber
        self.summarizer = summarizer
    }

    func startRecording() async {
        do {
            _ = try await recorder.start()
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
        var rec = Recording(id: UUID(), url: url, createdAt: Date(), duration: recorder.elapsed)
        current = rec

        stage = .transcribing
        do {
            let text = try await transcriber.transcribe(audioAt: url)
            rec.transcript = text
            current = rec

            stage = .summarizing
            let summary = try await summarizer.summarize(text)
            rec.summary = summary
            current = rec
            recordings.insert(rec, at: 0)
            stage = .done
        } catch {
            stage = .failed("Processing failed: \(error.localizedDescription)")
        }
    }

    func reset() {
        current = nil
        stage = .idle
    }
}
