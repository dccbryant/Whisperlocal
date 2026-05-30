import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol SummarizationService {
    func summarize(_ text: String) async throws -> String
    func title(for text: String) async throws -> String
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
        try ensureAvailable()
        let instructions = """
        You are a summarization assistant. You receive a transcript with lines like \
        "Speaker 1: ...". You output ONLY a short summary in 2 to 3 sentences, under 60 words.

        Hard rules:
        - Do NOT include the words "Speaker 1", "Speaker 2", or any speaker label.
        - Do NOT quote, paraphrase line-by-line, or repeat sentences from the transcript.
        - Do NOT begin with "The transcript", "This is", "In this", or similar meta phrases.
        - Write in plain prose, third person, describing the topic and any decisions or facts.
        - If the transcript is too short or contains no substantive content, respond with: \
        "No meaningful content to summarize."
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)\n\nSummary:")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func title(for text: String) async throws -> String {
        try ensureAvailable()
        let instructions = """
        You are a title generator. Output ONLY a short newspaper-headline title for the transcript.

        Hard rules:
        - 3 to 5 words.
        - No quotation marks, no markdown, no leading "Title:" prefix.
        - Capture the topic only (e.g. "Q3 sales planning", "Voice memo about groceries").
        - Output the title and nothing else.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)\n\nTitle:")
        return Self.cleanTitle(response.content)
    }

    private func ensureAvailable() throws {
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(let reason):
            throw ServiceError.modelUnavailable("Apple on-device LLM unavailable: \(reason)")
        }
    }

    private static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip surrounding quotes the model sometimes still adds.
        if let first = t.first, ["\"", "'", "“", "‘"].contains(first) { t.removeFirst() }
        if let last = t.last, ["\"", "'", "”", "’"].contains(last) { t.removeLast() }
        // Drop trailing period — titles don't take one.
        if t.last == "." { t.removeLast() }
        return t
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

    func title(for text: String) async throws -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(5)
            .joined(separator: " ")
        return words.isEmpty ? "Untitled recording" : "Note: \(words)"
    }
}
