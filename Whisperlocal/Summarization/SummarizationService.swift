import Foundation

protocol SummarizationService {
    func summarize(_ text: String) async throws -> String
}

/// Placeholder until llama.cpp is integrated. Produces a trivial extractive summary so the UI
/// has something to render. Replace with `LlamaCppSummarizationService`.
struct MockSummarizationService: SummarizationService {
    func summarize(_ text: String) async throws -> String {
        try await Task.sleep(nanoseconds: 400_000_000)
        let sentences = text
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lead = sentences.prefix(2).joined(separator: ". ")
        return lead.isEmpty ? "[mock summary]" : "[mock summary] " + lead + "."
    }
}
