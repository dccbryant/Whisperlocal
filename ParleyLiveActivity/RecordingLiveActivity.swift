import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity for an in-progress recording. Renders on the lock screen and in the
/// Dynamic Island. Styled to match the Parley/Braun aesthetic.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(red: 0.945, green: 0.925, blue: 0.875))
                .activitySystemActionForegroundColor(Color(red: 0.145, green: 0.145, blue: 0.145))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Parley").font(.system(size: 12, weight: .semibold)).kerning(1.5)
                    } icon: {
                        Image(systemName: "mic.fill").foregroundStyle(.red)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LevelBar(peakDB: context.state.peakLevel)
                        .frame(height: 4)
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: RecordingActivityAttributes.State

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color(red: 0.700, green: 0.150, blue: 0.080))
                Image(systemName: "mic.fill").foregroundStyle(.white).font(.system(size: 18))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text("PARLEY · RECORDING")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(1.8)
                    .foregroundStyle(Color(red: 0.435, green: 0.415, blue: 0.380))
                Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.145, green: 0.145, blue: 0.145))
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct LevelBar: View {
    let peakDB: Float

    private var fraction: Double {
        let clamped = max(-60, min(0, peakDB))
        return Double((clamped + 60) / 60)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.25))
                Capsule()
                    .fill(Color(red: 0.700, green: 0.150, blue: 0.080))
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
}
