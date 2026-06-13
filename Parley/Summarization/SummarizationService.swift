import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The structured information the summarizer pulls out of a transcript.
/// Empty arrays / empty summary are valid for any field — voice memos shouldn't have topics.
struct MeetingExtraction: Hashable {
    let summary: String
    let topics: [Topic]

    static let empty = MeetingExtraction(
        summary: "",
        topics: []
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
        @Guide(description: "Action items that someone explicitly committed to with a concrete deadline. At most 3 in any single chunk. Quality over quantity — only the most important commitments.")
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

    /// How to handle a failed Apple FM call.
    private enum RetryDisposition {
        /// Deterministic failure — retrying the identical input can't change the outcome.
        case dontRetry
        /// Transient failure — retry once after this delay.
        case retryAfter(UInt64)
    }

    /// Classify an Apple FM error into a retry strategy. The key distinction: a content-safety
    /// *refusal* is deterministic (same input → same refusal), so retrying only wastes a
    /// session and adds rate-limit pressure. A *rate-limit* needs a real back-off, not the
    /// 500 ms we use for generic transient hiccups.
    private static func disposition(for error: Error) -> RetryDisposition {
        guard let gen = error as? LanguageModelSession.GenerationError else {
            return .retryAfter(500_000_000)
        }
        switch gen {
        case .refusal:
            return .dontRetry
        case .rateLimited:
            return .retryAfter(3_000_000_000)
        default:
            return .retryAfter(500_000_000)
        }
    }

    /// Call an Apple FM block, retrying once on *transient* failure. Apple's on-device model
    /// occasionally throws transient errors under load; a second attempt usually succeeds.
    /// Refusals are not retried — they're deterministic — and rate-limits back off harder.
    /// Logs the original error and the retry outcome.
    private func withRetry<T>(_ label: String, _ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch {
            switch Self.disposition(for: error) {
            case .dontRetry:
                print("[Analyze] \(label) refused — not retrying (deterministic): \(error)")
                throw error
            case .retryAfter(let delay):
                print("[Analyze] \(label) failed once, retrying after \(delay / 1_000_000)ms: \(error)")
                try? await Task.sleep(nanoseconds: delay)
                do {
                    return try await block()
                } catch {
                    print("[Analyze] \(label) failed twice, giving up: \(error)")
                    throw error
                }
            }
        }
    }

    /// Sleep briefly between sub-pass calls so we don't slam the model with back-to-back
    /// requests, which seems to correlate with the transient unavailability we've seen.
    private func breathe() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    func analyze(
        _ text: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MeetingExtraction {
        try ensureAvailable()
        let analyzeStart = Date()
        let chunks = Self.chunk(text)

        // Single-chunk path: run the three passes sequentially with a beat between each.
        // Apple FM serializes internally anyway, so the old parallel `async let` bought no
        // real speedup — it just fired a 3-session burst that tripped the on-device rate
        // limiter (observed: long meetings failing with every pass empty). Paced-sequential
        // keeps us comfortably under the limiter.
        if chunks.count == 1 {
            let s = await safeFinal(chunks[0])
            await breathe()
            let t = await safeTopics(chunks[0])
            onProgress?(1.0)
            let topicsCapped = Array(Self.dedupeTopics(t).prefix(5))
            print("[Analyze] done (1 chunk sequential, \(String(format: "%.1f", Date().timeIntervalSince(analyzeStart)))s) — summary=\(s.count) chars, topics=\(topicsCapped.count)")
            return MeetingExtraction(summary: s, topics: topicsCapped)
        }

        // Multi-chunk path: walk chunks sequentially AND run each chunk's three passes
        // sequentially, with a beat between every call. On long meetings the old
        // parallel-within-chunk burst (chunk-count × 3 concurrent sessions) reliably tripped
        // the rate limiter until every pass came back empty — which discarded the whole
        // meeting. Pacing each call fixes that; FM serializes internally so we lose ~nothing.
        var briefSummaries: [String] = []
        var topicAcc: [Topic] = []

        for (i, chunk) in chunks.enumerated() {
            let b = await safeBrief(chunk)
            await breathe()
            let t = await safeTopics(chunk)
            if !b.isEmpty { briefSummaries.append(b) }
            topicAcc.append(contentsOf: t)
            // Per-chunk progress: leave a slice at the end for the final summary reduce.
            onProgress?(0.9 * Double(i + 1) / Double(chunks.count))
            await breathe()
        }

        // Reduce briefs into a single user-facing summary. Hierarchical: if joined
        // briefs still exceed the chunk budget, brief-summarize them again before the
        // final pass.
        var joined = briefSummaries.joined(separator: "\n\n")
        var lastSize = Int.max
        while joined.count > 3_500 && joined.count < lastSize {
            lastSize = joined.count
            let smallChunks = Self.chunk(joined, maxChars: 3_500)
            var compressed: [String] = []
            for sc in smallChunks {
                compressed.append(await safeBrief(sc))
            }
            joined = compressed.joined(separator: "\n\n")
        }
        // Fall back to the joined briefs if the final reduce fails. We already produced
        // good per-chunk summaries; never blank the whole summary just because the polish
        // pass got rate-limited or refused. A slightly-rougher summary beats none.
        let summary: String
        if joined.isEmpty {
            summary = ""
        } else {
            let polished = await safeFinal(joined)
            summary = polished.isEmpty ? joined : polished
        }
        onProgress?(1.0)

        let topics = Array(Self.dedupeTopics(topicAcc).prefix(5))
        print("[Analyze] done (\(chunks.count) chunks sequential, \(String(format: "%.1f", Date().timeIntervalSince(analyzeStart)))s) — summary=\(summary.count) chars, topics=\(topics.count)")

        return MeetingExtraction(
            summary: summary,
            topics: topics
        )
    }

    // MARK: - Safe wrappers (swallow a failed pass → empty, so analyze never throws)

    private func safeBrief(_ chunk: String) async -> String {
        do { return try await withRetry("brief summary") { try await summarizeBrief(chunk) } }
        catch { return "" }
    }

    private func safeFinal(_ chunk: String) async -> String {
        do { return try await withRetry("final summary") { try await summarizeFinal(chunk) } }
        catch { return "" }
    }

    private func safeTopics(_ chunk: String) async -> [Topic] {
        do { return try await withRetry("topics") { try await extractTopics(chunk) } }
        catch { return [] }
    }

    private func safeActions(_ chunk: String) async -> [ActionItem] {
        do { return try await withRetry("action items") { try await extractActionItems(chunk) } }
        catch { return [] }
    }

    // MARK: - Title

    func title(for text: String) async throws -> String {
        try ensureAvailable()
        let titleStart = Date()
        // The title call fires right after analyze()'s burst of sessions. Without a beat
        // here it lands on the rate limiter (observed: title rate-limited while analyze
        // succeeded). A short pause lets the model drain before we ask for one more thing.
        await breathe()
        let snippet = String(text.prefix(4_000))
        let result = try await withRetry("title") {
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
        print("[Timing] title: \(String(format: "%.1f", Date().timeIntervalSince(titleStart)))s")
        return result
    }

    // MARK: - Summary (hierarchical map-reduce)

    private func summarize(_ chunks: [String]) async throws -> String {
        // Single-chunk meetings go straight to the user-facing final summary.
        if chunks.count == 1 {
            return try await summarizeFinal(chunks[0])
        }
        // Map: each chunk produces a brief 1-2 sentence summary so the reduce input
        // stays under the context window even when there are many chunks.
        var partials: [String] = []
        for chunk in chunks {
            partials.append(try await summarizeBrief(chunk))
        }
        // Reduce: if the joined partials still exceed our safe budget, run another
        // brief-summarize pass. Repeat until the input fits. The bail-out check
        // ensures we don't infinite-loop on a degenerate case where the brief
        // pass doesn't actually compress.
        var joined = partials.joined(separator: "\n\n")
        var lastSize = Int.max
        while joined.count > 3_500 && joined.count < lastSize {
            lastSize = joined.count
            let smallChunks = Self.chunk(joined, maxChars: 3_500)
            var compressed: [String] = []
            for sc in smallChunks {
                compressed.append(try await summarizeBrief(sc))
            }
            joined = compressed.joined(separator: "\n\n")
        }
        return try await summarizeFinal(joined)
    }

    /// Brief, intermediate summary — 1-2 sentences. Used in the map step and any
    /// recursive reductions. NOT meant to be shown to the user.
    private func summarizeBrief(_ text: String) async throws -> String {
        let instructions = """
        Write a 1 to 2 sentence summary of this transcript chunk, under 40 words.

        Hard rules:
        - Do NOT include speaker labels.
        - Do NOT quote.
        - Plain prose, third person.
        - If the chunk has no substantive content, respond with "(no content)".
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Transcript:\n\(text)\n\nSummary:")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// User-facing summary — 4 to 6 sentences. Used for single-chunk meetings and as
    /// the final reduce step on multi-chunk meetings.
    private func summarizeFinal(_ text: String) async throws -> String {
        let instructions = """
        You are a summarization assistant. Output ONLY a single summary in 4 to 6 \
        sentences, under 120 words.

        Hard rules:
        - Do NOT include speaker labels.
        - Do NOT produce multiple paragraphs. One paragraph only.
        - Do NOT quote.
        - Do NOT begin with "The transcript", "This is", "In this", or similar meta phrases.
        - Plain prose, third person, describing the topic, decisions, and key facts.
        - If the content is too short or contains nothing substantive, respond with: \
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

        At most 3 action items per chunk. Be extremely selective — pick ONLY the most \
        important, time-sensitive commitments. If unsure whether to include something, \
        leave it out.

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
    /// alongside our instructions and the expected response. Apple's on-device model has a
    /// hard 4096-token limit. Measured against the earlier `exceededContextWindowSize`
    /// log (8000 chars produced 4091 tokens of total prompt), instructions + schema take
    /// ~1100 tokens and transcript runs at ~0.3 tokens/char. 6000 chars keeps the full
    /// prompt under ~3000 tokens — comfortable margin, ~33% fewer chunks than the
    /// previous 4000-char setting and therefore ~33% less LLM time end-to-end.
    private static func chunk(_ text: String, maxChars: Int = 6_000) -> [String] {
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


    /// Topics: fuzzy-match titles. Uses substring + Jaccard overlap, same approach as
    /// action item dedupe, so genuinely similar topics ("Marketing Plan" vs "Marketing
    /// Strategy") collapse together rather than appearing twice. When two collide, the
    /// merged topic keeps the longer (more specific) title and the union of points.
    private static func dedupeTopics(_ topics: [Topic]) -> [Topic] {
        var out: [Topic] = []
        for topic in topics {
            let normTitle = normalize(topic.title)
            if let idx = out.firstIndex(where: {
                let other = normalize($0.title)
                if roughlyEqual(other, normTitle) { return true }
                return wordOverlapRatio(other, normTitle) >= 0.45
            }) {
                let keptTitle = topic.title.count > out[idx].title.count ? topic.title : out[idx].title
                let mergedPoints = dedupe(out[idx].points + topic.points)
                out[idx] = Topic(id: out[idx].id, title: keptTitle, points: mergedPoints)
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
            topics: []
        )
    }

    func title(for text: String) async throws -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(5)
            .joined(separator: " ")
        return words.isEmpty ? "Untitled recording" : "Note: \(words)"
    }
}
