import ActivityKit
import Foundation

/// Wraps the ActivityKit lifecycle of the recording Live Activity. No-ops gracefully when
/// the user has disabled Live Activities or the OS doesn't support them.
@MainActor
final class RecordingActivityManager {
    private var activity: Activity<RecordingActivityAttributes>?

    func start(at startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity != nil { return }
        let attributes = RecordingActivityAttributes()
        let state = RecordingActivityAttributes.State(startedAt: startedAt, peakLevel: -160)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            print("[Activity] failed to start: \(error)")
        }
    }

    func update(startedAt: Date, peakLevel: Float) {
        guard let activity else { return }
        let state = RecordingActivityAttributes.State(startedAt: startedAt, peakLevel: peakLevel)
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        Task {
            await activity.end(activity.content, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}
