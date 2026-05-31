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
    func summarize(
        _ text: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> String

    func title(for text: String) async throws -> String

    func extract(
        from text: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> MeetingExtraction
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

    func summarize(
        _ text: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        try ensureAvailable()
        let chunks = Self.chunk(text)
        if chunks.count == 1 {
            let result = try await summarizeChunk(chunks[0])
            onProgress?(1.0)
            return result
        }
        // Map-reduce: summarize each chunk, then summarize the summaries.
        // Budget: chunks share 80% of the bar, final reduce step gets the last 20%.
        var partials: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let s = try await summarizeChunk(chunk)
            partials.append(s)
            onProgress?(0.8 * Double(i + 1) / Double(chunks.count))
        }
        let final = try await summarizeChunk(partials.joined(separator: "\n\n"))
        onProgress?(1.0)
        return final
    }

    private func summarizeChunk(_ text: String) async throws -> String {
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
        // Title only needs the topic, not the full transcript. Cap at the first 4K chars
        // so we never hit the context window on a long meeting.
        let snippet = String(text.prefix(4_000))
        let instructions = """
        You are a title generator. Output ONLY a short newspaper-headline title for the transcript.

        Hard rules:
        - 3 to 5 words.
        - No quotation marks, no markdown, no leading "Title:" prefix.
        - Capture the topic only (e.g. "Q3 sales planning", "Voice memo about groceries").
        - Output the title and nothing else.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(snippet)\n\nTitle:")
        return Self.cleanTitle(response.content)
    }

    func extract(
        from text: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MeetingExtraction {
        try ensureAvailable()
        let chunks = Self.chunk(text)
        if chunks.count == 1 {
            let result = try await extractFromChunk(chunks[0])
            onProgress?(1.0)
            return result
        }
        var decisions: [String] = []
        var actions: [ActionItem] = []
        for (i, chunk) in chunks.enumerated() {
            let e = try await extractFromChunk(chunk)
            decisions.append(contentsOf: e.decisions)
            actions.append(contentsOf: e.actionItems)
            onProgress?(Double(i + 1) / Double(chunks.count))
        }
        return MeetingExtraction(
            decisions: Self.dedupe(decisions),
            actionItems: Self.dedupe(actions)
        )
    }

    /// De-dupe by lowercased string equality. Crude but effective for the common case where
    /// the same decision is extracted from two overlapping chunks.
    private static func dedupe(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in strings where seen.insert(s.lowercased()).inserted {
            out.append(s)
        }
        return out
    }

    /// De-dupe action items by lowercased assignee+task. Due dates ignored — if the model
    /// got the task right twice, it almost certainly meant the same item.
    private static func dedupe(_ items: [ActionItem]) -> [ActionItem] {
        var seen = Set<String>()
        var out: [ActionItem] = []
        for item in items {
            let key = "\(item.assignee.lowercased())|\(item.task.lowercased())"
            if seen.insert(key).inserted { out.append(item) }
        }
        return out
    }

    private func extractFromChunk(_ text: String) async throws -> MeetingExtraction {
        let instructions = """
        You extract structured meeting notes from a transcript. Be conservative.

        Rules:
        - "Decisions" are conclusions reached, not tasks. Examples: "Go with vendor A.", \
        "Move standup to Tuesdays.". Each is one sentence.
        - "Action items" are concrete next steps someone agreed to do.
        - The assignee MUST be one of the speaker labels exactly as they appear in the \
        transcript ("Speaker 1", "Speaker 2", etc.) — whichever speaker accepted the task. \
        Use "Unassigned" if no speaker took it on. Do NOT use a person's name; use the \
        speaker label even when names are mentioned.
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
        return MeetingExtraction(
            decisions: g.decisions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            actionItems: items
        )
    }

    /// Split a transcript into chunks small enough to fit the on-device LLM context window
    /// alongside our instructions and the expected response. Apple's on-device model carries
    /// roughly a 4K-token context (≈ 12K English characters); 8K leaves comfortable headroom
    /// for the system instructions and the generated output.
    private static func chunk(_ text: String, maxChars: Int = 8_000) -> [String] {
        if text.count <= maxChars { return [text] }
        // Prefer breaking on newlines so we don't split a speaker turn mid-sentence.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            let lineSize = line.count + 1
            if size + lineSize > maxChars, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(line)
            size += lineSize
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
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
    func summarize(
        _ text: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        try await Task.sleep(nanoseconds: 200_000_000)
        onProgress?(1.0)
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

    func extract(
        from text: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MeetingExtraction {
        onProgress?(1.0)
        return .empty
    }
}
