import ActivityKit
import Foundation

/// ActivityKit attributes for the "you are recording" Live Activity. Lives in a Shared/
/// folder so both the Parley app target and the ParleyLiveActivity widget extension
/// compile against the exact same struct.
struct RecordingActivityAttributes: ActivityAttributes {
    typealias ContentState = State

    struct State: Codable, Hashable {
        var startedAt: Date
        var peakLevel: Float
    }
}
