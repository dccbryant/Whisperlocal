import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol SummarizationService {
    func summarize(_ text: String) async throws -> String
}

enum SummarizationFactory {
    /// Returns the best on-device summarizer available on this device.
    static func make() -> SummarizationService {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleSummarizationService.isAvailable {
            return AppleSummarizationService()
        }
        #endif
        return MockSummarizationService()
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
struct AppleSummarizationService: SummarizationService {
    enum ServiceError: Error, LocalizedError {
        case modelUnavailable(String)
        var errorDescription: String? {
            if case let .modelUnavailable(reason) = self { return reason }
            return nil
        }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func summarize(_ text: String) async throws -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw ServiceError.modelUnavailable("Apple on-device LLM unavailable: \(reason)")
        }

        let instructions = """
        You write concise, neutral summaries of meeting and voice-note transcripts.
        Capture only what was said. Do not invent facts. Use 2-4 sentences.
        If multiple speakers participated, mention each by their label (e.g. Speaker 1).
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Summarize this transcript:\n\n\(text)")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

/// Placeholder used on devices without Apple Intelligence. Echoes the first couple of sentences
/// so the UI has something to render.
struct MockSummarizationService: SummarizationService {
    func summarize(_ text: String) async throws -> String {
        try await Task.sleep(nanoseconds: 200_000_000)
        let sentences = text
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lead = sentences.prefix(2).joined(separator: ". ")
        return lead.isEmpty
            ? "[mock summary — Apple Intelligence not available on this device]"
            : "[mock summary] " + lead + "."
    }
}
