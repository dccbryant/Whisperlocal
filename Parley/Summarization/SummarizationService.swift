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
    let actionItems: [ActionItem]

    static let empty = MeetingExtraction(
        summary: "",
        attendees: [],
        topics: [],
        actionItems: []
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
    struct GenerableActionItems {
        @Guide(description: "Action items that someone explicitly committed to. At most 5 in any single chunk. Quality over quantity — only include clear commitments.")
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
        @Guide(description: "3 to 5 main topics discussed. Only the most substantial topics — not minor side comments.")
        let topics: [GenerableTopic]
    }

    @Generable
    struct GenerableTopic {
        @Guide(description: "Short label for the topic, 3 to 6 words. No leading numbering.")
        let title: String
        @Guide(description: "2 to 3 short sentences expanding on what was said about this topic. Each is a complete sentence.")
        let points: [String]
    }

    // MARK: - Orchestration

    func analyze(
        _ text: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MeetingExtraction {
        try ensureAvailable()
        let chunks = Self.chunk(text)

        // Four sub-passes (down from six — dropped decisions, open questions, key dates).
        // Each pass is independently fallible; a failure in Topics doesn't tank Summary.
        let passes: Double = 4

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

        // 4. Action items
        var actAcc: [ActionItem] = []
        for chunk in chunks {
            do {
                actAcc.append(contentsOf: try await extractActionItems(chunk))
            } catch {
                print("[Analyze] action items failed on a chunk: \(error)")
            }
        }
        onProgress?(1.0)

        let dedupedActions = Self.dedupe(actAcc)
        print("[Analyze] done — summary=\(summary.count) chars, attendees=\(attendees.count), topics=\(topics.count), actions=\(dedupedActions.count) (raw \(actAcc.count))")

        return MeetingExtraction(
            summary: summary,
            attendees: attendees,
            topics: topics,
            actionItems: dedupedActions
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

    private func extractActionItems(_ text: String) async throws -> [ActionItem] {
        let instructions = """
        Extract action items. STRICT RULE: include ONLY action items where the speaker \
        gave a CONCRETE, SPECIFIC deadline.

        A concrete deadline names a specific day, date, week, month, quarter, year, or event:
        - "by Friday" ✓
        - "next Tuesday" ✓
        - "before July 1st" ✓
        - "end of Q3" ✓
        - "by the launch" ✓
        - "next week" ✓

        FORBIDDEN — these are NOT deadlines, skip the item entirely:
        - "soon" / "shortly" / "eventually" / "later"
        - "immediately" / "ASAP" / "as soon as possible"
        - "no time mentioned" / "no deadline" / "TBD" / "to be determined"
        - "when ready" / "when possible" / "when they come through"
        - "ongoing" / "continuously"

        At most 5 action items per chunk. Quality over quantity.

        For each item kept:
        - assignee: speaker label ("Speaker 1", "Speaker 2", ...) of whoever accepted it. \
        Use "Unassigned" only when no specific speaker took it on.
        - task: one short imperative sentence.
        - dueDate: the concrete time reference exactly as stated. MUST name a specific time. \
        If you cannot give a specific deadline, SKIP THE ITEM. Do NOT fill in "soon" or \
        "no time mentioned" or any other placeholder.

        Empty array is the correct answer when no items have concrete deadlines. Do NOT \
        invent items or deadlines.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)",
                                                 generating: GenerableActionItems.self)
        return response.content.actionItems.compactMap { gi -> ActionItem? in
            let due = gi.dueDate.trimmingCharacters(in: .whitespacesAndNewlines)
            // Belt-and-braces: even with the prompt, the small on-device model sometimes
            // slips placeholder strings like "soon" or "no time mentioned" in to bypass
            // the rule. Filter those out here.
            guard !due.isEmpty, Self.isConcreteDeadline(due) else { return nil }
            return ActionItem(
                assignee: gi.assignee.trimmingCharacters(in: .whitespacesAndNewlines),
                task: gi.task.trimmingCharacters(in: .whitespacesAndNewlines),
                dueDate: due
            )
        }
    }

    /// Phrases the model uses to pretend it has a deadline. Reject any due-date string that
    /// is, or starts with, or ends with, any of these (case-insensitive). Tweakable list.
    private static let placeholderDueDates: Set<String> = [
        "soon", "shortly", "eventually", "later", "immediately", "asap",
        "as soon as possible", "right away",
        "no time mentioned", "no time specified", "no time", "no deadline",
        "no date", "not specified", "not mentioned", "unspecified", "undefined",
        "tbd", "to be determined", "to be decided",
        "when ready", "when possible", "when they come through",
        "ongoing", "continuously", "n/a", "none", "any time", "anytime",
    ]

    /// True if a due-date string looks like a real deadline rather than a placeholder.
    private static func isConcreteDeadline(_ raw: String) -> Bool {
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered.isEmpty { return false }
        // Exact placeholder match → reject.
        if placeholderDueDates.contains(lowered) { return false }
        // "as soon as possible we can…" / "soon, before the launch" — strip leading/trailing
        // filler and check what's left has real content. Simple heuristic: at least one of
        // these substrings (day names, month names, period words, numbers).
        let concreteMarkers = [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "may", "june", "july", "august",
            "september", "october", "november", "december",
            "week", "month", "quarter", "year", "day", "tomorrow", "tonight",
            "morning", "afternoon", "evening",
            "launch", "release", "deadline", "meeting", "deliver",
            "end of", "beginning of", "mid-", "early", "late",
            "q1", "q2", "q3", "q4",
        ]
        for marker in concreteMarkers where lowered.contains(marker) { return true }
        // A digit in the string (e.g. "July 1st", "by the 15th") is also a strong signal.
        if lowered.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
            return true
        }
        return false
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
        - Provide 2 to 3 short sentences expanding on what was said. Each point is a full \
        sentence, not a fragment.

        Return 3 to 5 topics — only the most substantial ones. Skip minor side comments \
        and brief tangents. Empty array if the transcript has no substantive content \
        (e.g. very short voice memo).

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

    /// Jaccard similarity over word sets — fraction of words shared between two strings.
    /// 1.0 means identical words, 0.0 means disjoint. Catches reworded duplicates that
    /// substring matching misses ("send the contract" vs "send the contract draft to vendor").
    private static func wordOverlapRatio(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.split(separator: " ").map(String.init))
        let wordsB = Set(b.split(separator: " ").map(String.init))
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }

    private static func dedupe(_ items: [ActionItem]) -> [ActionItem] {
        var out: [ActionItem] = []
        for item in items {
            let normTask = normalize(item.task)
            if let idx = out.firstIndex(where: {
                let other = normalize($0.task)
                if other == normTask { return true }
                if roughlyEqual(other, normTask) { return true }
                // Lower threshold + ignore-assignee match: catches rewordings AND cases
                // where the model attributed the same commitment to different speakers
                // across chunks.
                return wordOverlapRatio(other, normTask) >= 0.45
            }) {
                // Prefer the longer task wording; if the kept one was Unassigned and the
                // duplicate names a specific speaker, take the named one.
                let existing = out[idx]
                let existingUnassigned = existing.assignee.lowercased() == "unassigned"
                let newNamed = item.assignee.lowercased() != "unassigned"
                if item.task.count > existing.task.count || (existingUnassigned && newNamed) {
                    out[idx] = item
                }
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
            actionItems: []
        )
    }

    func title(for text: String) async throws -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(5)
            .joined(separator: " ")
        return words.isEmpty ? "Untitled recording" : "Note: \(words)"
    }
}
