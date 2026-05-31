import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct MeetingExtraction: Hashable {
    let decisions: [String]
    let actionItems: [ActionItem]
    static let empty = MeetingExtraction(decisions: [], actionItems: [])
}

protocol SummarizationService {
    func summarize(_ text: String) async throws -> String
    func title(for text: String) async throws -> String
    func extract(from text: String) async throws -> MeetingExtraction
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

    /// Mirror types used only for structured-output generation. The @Generable macro's
    /// expansion needs to reference these from outside the struct, so they can't be
    /// `private`; left at internal/file scope so the rest of the app stays decoupled
    /// from the FoundationModels framework via the public MeetingExtraction value type.
    @Generable
    struct GenerableExtraction {
        @Guide(description: "Concrete decisions reached in the meeting. Each is one short sentence. Empty if nothing was decided.")
        let decisions: [String]
        @Guide(description: "Concrete next-step tasks that someone needs to do.")
        let actionItems: [GenerableActionItem]
    }

    @Generable
    struct GenerableActionItem {
        @Guide(description: "Name of the person who will do this. Use 'Unassigned' if the transcript does not make it clear.")
        let assignee: String
        @Guide(description: "What needs to be done, one short sentence in the imperative.")
        let task: String
        @Guide(description: "When it is due — for example 'Friday', 'next Tuesday', 'end of quarter'. Use an empty string if no time was mentioned.")
        let dueDate: String
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

    func extract(from text: String) async throws -> MeetingExtraction {
        try ensureAvailable()
        let instructions = """
        You extract structured meeting notes from a transcript. Be conservative.

        Rules:
        - "Decisions" are conclusions reached, not tasks. Examples: "Go with vendor A.", \
        "Move standup to Tuesdays.". Each is one sentence.
        - "Action items" are concrete next steps someone agreed to do. Attribute the assignee \
        only when the transcript makes it clear ("Sarah, can you...?"). Otherwise use "Unassigned".
        - Only include a due date when the speaker actually stated one. Leave it empty otherwise.
        - If nothing was decided, return an empty decisions array.
        - If no action items were assigned, return an empty actionItems array.
        - Do NOT invent decisions or actions that were not in the transcript.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)",
                                                 generating: GenerableExtraction.self)
        let g = response.content
        let items = g.actionItems.map { gi -> ActionItem in
            let trimmedDue = gi.dueDate.trimmingCharacters(in: .whitespacesAndNewlines)
            return ActionItem(
                assignee: gi.assignee.trimmingCharacters(in: .whitespacesAndNewlines),
                task: gi.task.trimmingCharacters(in: .whitespacesAndNewlines),
                dueDate: trimmedDue.isEmpty ? nil : trimmedDue
            )
        }
        return MeetingExtraction(decisions: g.decisions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, actionItems: items)
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
        if let first = t.first, ["\"", "'", "“", "‘"].contains(first) { t.removeFirst() }
        if let last = t.last, ["\"", "'", "”", "’"].contains(last) { t.removeLast() }
        if t.last == "." { t.removeLast() }
        return t
    }
}
#endif

/// Placeholder used on devices without Apple Intelligence. Echoes the first couple of sentences
/// so the UI has something to render. Returns empty meeting extraction.
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

    func extract(from text: String) async throws -> MeetingExtraction {
        .empty
    }
}
