import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// All of the structured information the summarizer pulls out of a transcript.
/// Empty arrays / nil are valid for any field — voice memos shouldn't have meeting topics.
struct MeetingExtraction: Hashable {
    let summary: String
    let attendees: [String]
    let topics: [Topic]
    let decisions: [String]
    let actionItems: [ActionItem]
    let openQuestions: [String]
    let keyDates: [KeyDate]

    static let empty = MeetingExtraction(
        summary: "",
        attendees: [],
        topics: [],
        decisions: [],
        actionItems: [],
        openQuestions: [],
        keyDates: []
    )
}

protocol SummarizationService {
    /// Produce title + summary + attendees + topics + decisions + action items +
    /// open questions + key dates in one orchestrated pass.
    /// `onProgress` is called with 0–1 as each section finishes.
    func analyze(
        _ text: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> MeetingExtraction

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

    // MARK: - Generable mirror types

    @Generable
    struct GenerableExtraction {
        @Guide(description: "Concrete decisions reached in the meeting. Each is one short sentence. Empty if nothing was decided.")
        let decisions: [String]
        @Guide(description: "Concrete next-step tasks that someone needs to do.")
        let actionItems: [GenerableActionItem]
    }

    @Generable
    struct GenerableActionItem {
        @Guide(description: "Speaker label (Speaker 1, Speaker 2, ...) of whoever accepted the task. Use 'Unassigned' if no speaker took it on. Do NOT use a person's name.")
        let assignee: String
        @Guide(description: "What needs to be done, one short sentence in the imperative.")
        let task: String
        @Guide(description: "When it is due — 'Friday', 'next Tuesday', 'end of quarter'. Empty string if no time was mentioned.")
        let dueDate: String
    }

    @Generable
    struct GenerableAttendees {
        @Guide(description: "First names of people who participated in the conversation, based on names spoken or addressed. Do NOT include speaker labels. Empty array if no names are mentioned.")
        let attendees: [String]
    }

    @Generable
    struct GenerableTopics {
        @Guide(description: "5 to 10 main topics discussed in the conversation, in the order they came up.")
        let topics: [GenerableTopic]
    }

    @Generable
    struct GenerableTopic {
        @Guide(description: "Short label for the topic, 3 to 6 words. No leading numbering.")
        let title: String
        @Guide(description: "2 to 4 short sentences expanding on what was said about this topic. Each is a complete sentence.")
        let points: [String]
    }

    @Generable
    struct GenerableOpenQuestions {
        @Guide(description: "Questions raised in the conversation that were left unresolved. Include only genuine open questions, not rhetorical ones. Empty array if none.")
        let questions: [String]
    }

    @Generable
    struct GenerableKeyDates {
        @Guide(description: "Specific dates, deadlines, or time references that were explicitly stated.")
        let dates: [GenerableKeyDate]
    }

    @Generable
    struct GenerableKeyDate {
        @Guide(description: "The date or timeframe as stated — 'Mid-July 2026', 'next Friday', 'end of Q3'.")
        let date: String
        @Guide(description: "Short description of what the date refers to — 'Granite 5.0 launch', 'Sarah's product review'.")
        let context: String
    }

    // MARK: - Orchestration

    func analyze(
        _ text: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MeetingExtraction {
        try ensureAvailable()
        let chunks = Self.chunk(text)

        // Six sub-passes. Each one is independently fallible: a failure in (say) Topics
        // shouldn't tank the Summary. We swallow errors per sub-pass and accumulate
        // whatever sections succeeded; the result is partial, not empty.
        let passes: Double = 6

        // 1. Summary
        let summary: String
        do {
            summary = try await summarize(chunks)
        } catch {
            print("[Analyze] summary failed: \(error)")
            summary = ""
        }
        onProgress?(1 / passes)

        // 2. Attendees
        var attendeeAcc: [String] = []
        for chunk in chunks {
            do {
                attendeeAcc.append(contentsOf: try await extractAttendees(chunk))
            } catch {
                print("[Analyze] attendees failed on a chunk: \(error)")
            }
        }
        let attendees = Self.dedupeNames(attendeeAcc)
        onProgress?(2 / passes)

        // 3. Topics
        var topicAcc: [Topic] = []
        for chunk in chunks {
            do {
                topicAcc.append(contentsOf: try await extractTopics(chunk))
            } catch {
                print("[Analyze] topics failed on a chunk: \(error)")
            }
        }
        let topics = Self.dedupeTopics(topicAcc)
        onProgress?(3 / passes)

        // 4. Decisions + action items
        var decAcc: [String] = []
        var actAcc: [ActionItem] = []
        for chunk in chunks {
            do {
                let e = try await extractDecisionsAndActions(chunk)
                decAcc.append(contentsOf: e.decisions)
                actAcc.append(contentsOf: e.actionItems)
            } catch {
                print("[Analyze] decisions/actions failed on a chunk: \(error)")
            }
        }
        onProgress?(4 / passes)

        // 5. Open questions
        var qAcc: [String] = []
        for chunk in chunks {
            do {
                qAcc.append(contentsOf: try await extractOpenQuestions(chunk))
            } catch {
                print("[Analyze] open questions failed on a chunk: \(error)")
            }
        }
        onProgress?(5 / passes)

        // 6. Key dates
        var dAcc: [KeyDate] = []
        for chunk in chunks {
            do {
                dAcc.append(contentsOf: try await extractKeyDates(chunk))
            } catch {
                print("[Analyze] key dates failed on a chunk: \(error)")
            }
        }
        onProgress?(1.0)

        print("[Analyze] done — summary=\(summary.count) chars, attendees=\(attendees.count), topics=\(topics.count), decisions=\(decAcc.count), actions=\(actAcc.count), questions=\(qAcc.count), dates=\(dAcc.count)")

        return MeetingExtraction(
            summary: summary,
            attendees: attendees,
            topics: topics,
            decisions: Self.dedupe(decAcc),
            actionItems: Self.dedupe(actAcc),
            openQuestions: Self.dedupe(qAcc),
            keyDates: Self.dedupeKeyDates(dAcc)
        )
    }

    // MARK: - Title

    func title(for text: String) async throws -> String {
        try ensureAvailable()
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

    // MARK: - Summary (per-chunk + reduce)

    private func summarize(_ chunks: [String]) async throws -> String {
        if chunks.count == 1 {
            return try await summarizeChunk(chunks[0])
        }
        var partials: [String] = []
        for chunk in chunks {
            partials.append(try await summarizeChunk(chunk))
        }
        return try await summarizeChunk(partials.joined(separator: "\n\n"))
    }

    private func summarizeChunk(_ text: String) async throws -> String {
        let instructions = """
        You are a summarization assistant. You receive a transcript with lines like \
        "Speaker 1: ...". You output ONLY a summary in 4 to 6 sentences, under 120 words.

        Hard rules:
        - Do NOT include the words "Speaker 1", "Speaker 2", or any speaker label.
        - Do NOT quote, paraphrase line-by-line, or repeat sentences from the transcript.
        - Do NOT begin with "The transcript", "This is", "In this", or similar meta phrases.
        - Write in plain prose, third person, describing the topic, decisions, and key facts.
        - If the transcript is too short or contains no substantive content, respond with: \
        "No meaningful content to summarize."
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)\n\nSummary:")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Per-section extractors

    private func extractDecisionsAndActions(_ text: String) async throws -> (decisions: [String], actionItems: [ActionItem]) {
        let instructions = """
        Extract decisions and action items from this transcript. Be inclusive — not just \
        formal conclusions but any agreement to do something or take an approach.

        For each action item, assignee MUST be a speaker label ("Speaker 1", "Speaker 2", ...) \
        or "Unassigned". Do NOT use a person's name even if mentioned.

        Empty arrays are valid. Do NOT invent items.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)",
                                                 generating: GenerableExtraction.self)
        let g = response.content
        let items = g.actionItems.map { gi -> ActionItem in
            let due = gi.dueDate.trimmingCharacters(in: .whitespacesAndNewlines)
            return ActionItem(
                assignee: gi.assignee.trimmingCharacters(in: .whitespacesAndNewlines),
                task: gi.task.trimmingCharacters(in: .whitespacesAndNewlines),
                dueDate: due.isEmpty ? nil : due
            )
        }
        return (
            g.decisions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            items
        )
    }

    private func extractAttendees(_ text: String) async throws -> [String] {
        let instructions = """
        List the first names of people who participated in the conversation.

        Look for:
        - Self-introductions ("Hi, I'm Sarah")
        - Names addressed directly ("Sarah, what do you think?")
        - Names mentioned as the speaker of an action ("Tom will send the report")

        Output first names only, no titles or surnames. Do NOT include speaker labels \
        ("Speaker 1" etc.). Do NOT invent names not in the transcript. Empty array is valid.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)",
                                                 generating: GenerableAttendees.self)
        return response.content.attendees
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func extractTopics(_ text: String) async throws -> [Topic] {
        let instructions = """
        Identify the main topics discussed in this transcript.

        For each topic:
        - Give a short title (3 to 6 words, no leading numbering like "1.")
        - Provide 2 to 4 short sentences expanding on what was said. Each point is a full \
        sentence, not a fragment.

        Return 5 to 10 topics in the order they came up. Empty array if the transcript has \
        no substantive content (e.g. very short voice memo).

        Do NOT include speaker labels in the points. Do NOT invent content.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)",
                                                 generating: GenerableTopics.self)
        return response.content.topics.map { gt in
            Topic(
                title: gt.title.trimmingCharacters(in: .whitespacesAndNewlines),
                points: gt.points.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }.filter { !$0.title.isEmpty }
    }

    private func extractOpenQuestions(_ text: String) async throws -> [String] {
        let instructions = """
        List genuine open questions raised in this transcript that were NOT resolved.

        Include:
        - Questions explicitly asked and not answered
        - Decisions deferred ("we'll figure this out later")
        - Unknowns flagged ("we still don't know X")

        Do NOT include:
        - Rhetorical questions
        - Questions that were answered in the same conversation

        Empty array if no open questions remained. Do NOT invent.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)",
                                                 generating: GenerableOpenQuestions.self)
        return response.content.questions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func extractKeyDates(_ text: String) async throws -> [KeyDate] {
        let instructions = """
        List specific dates, deadlines, and timeframes that were explicitly mentioned.

        For each:
        - date: the date or timeframe as stated ("Mid-July 2026", "next Friday")
        - context: what it refers to ("Granite 5.0 launch", "product review meeting")

        Include only dates/times actually spoken. Do NOT invent context. Empty array if no \
        time references were made.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)",
                                                 generating: GenerableKeyDates.self)
        return response.content.dates.map { gd in
            KeyDate(
                date: gd.date.trimmingCharacters(in: .whitespacesAndNewlines),
                context: gd.context.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.filter { !$0.date.isEmpty }
    }

    // MARK: - Chunking

    /// Split a transcript into chunks small enough to fit the on-device LLM context window
    /// alongside our instructions and the expected response. Apple's on-device model carries
    /// roughly a 4K-token context (≈ 12K English characters); 8K leaves comfortable headroom.
    private static func chunk(_ text: String, maxChars: Int = 8_000) -> [String] {
        if text.count <= maxChars { return [text] }
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

    // MARK: - Dedupe / normalize helpers

    private static let stopwords: Set<String> = [
        "the", "a", "an", "to", "for", "and", "or", "but", "by", "of", "in", "on",
        "with", "from", "is", "it", "this", "that", "be", "will",
    ]

    private static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let stripped = lowered.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .reduce(into: "") { $0.append(Character($1)) }
        return stripped
            .split(separator: " ")
            .map(String.init)
            .filter { !stopwords.contains($0) }
            .joined(separator: " ")
    }

    private static func roughlyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }
        return a.contains(b) || b.contains(a)
    }

    private static func dedupe(_ strings: [String]) -> [String] {
        var out: [String] = []
        var seen: [String] = []
        for s in strings {
            let n = normalize(s)
            if !seen.contains(where: { roughlyEqual($0, n) }) {
                out.append(s)
                seen.append(n)
            }
        }
        return out
    }

    private static func dedupe(_ items: [ActionItem]) -> [ActionItem] {
        var out: [ActionItem] = []
        for item in items {
            let normTask = normalize(item.task)
            let assignee = item.assignee.lowercased()
            if let idx = out.firstIndex(where: {
                $0.assignee.lowercased() == assignee && roughlyEqual(normalize($0.task), normTask)
            }) {
                if item.task.count > out[idx].task.count { out[idx] = item }
            } else {
                out.append(item)
            }
        }
        return out
    }

    /// Names: case-insensitive exact match.
    private static func dedupeNames(_ names: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for name in names {
            let key = name.lowercased()
            if seen.insert(key).inserted { out.append(name) }
        }
        return out
    }

    /// Topics: fuzzy-match titles. When duplicates collide, union the points.
    private static func dedupeTopics(_ topics: [Topic]) -> [Topic] {
        var out: [Topic] = []
        for topic in topics {
            let normTitle = normalize(topic.title)
            if let idx = out.firstIndex(where: { roughlyEqual(normalize($0.title), normTitle) }) {
                let mergedPoints = dedupe(out[idx].points + topic.points)
                out[idx] = Topic(id: out[idx].id, title: out[idx].title, points: mergedPoints)
            } else {
                out.append(topic)
            }
        }
        return out
    }

    /// Key dates: fuzzy-match on date+context combined.
    private static func dedupeKeyDates(_ dates: [KeyDate]) -> [KeyDate] {
        var out: [KeyDate] = []
        for kd in dates {
            let key = normalize("\(kd.date) \(kd.context)")
            if !out.contains(where: { roughlyEqual(normalize("\($0.date) \($0.context)"), key) }) {
                out.append(kd)
            }
        }
        return out
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

/// Placeholder for devices without Apple Intelligence. Returns minimal output so the UI works.
struct MockSummarizationService: SummarizationService {
    func analyze(
        _ text: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MeetingExtraction {
        try await Task.sleep(nanoseconds: 200_000_000)
        onProgress?(1.0)
        let sentences = text
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lead = sentences.prefix(2).joined(separator: ". ")
        return MeetingExtraction(
            summary: lead.isEmpty
                ? "[mock summary — Apple Intelligence not available on this device]"
                : "[mock summary] " + lead + ".",
            attendees: [],
            topics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            keyDates: []
        )
    }

    func title(for text: String) async throws -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(5)
            .joined(separator: " ")
        return words.isEmpty ? "Untitled recording" : "Note: \(words)"
    }
}
