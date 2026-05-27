import Foundation

struct Recording: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let createdAt: Date
    var duration: TimeInterval
    var transcript: String?
    var summary: String?
}
