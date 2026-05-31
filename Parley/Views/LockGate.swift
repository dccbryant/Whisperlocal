import LocalAuthentication
import SwiftUI

@MainActor
final class LockState: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published private(set) var lastError: String?

    /// Disable the lock entirely by setting this UserDefaults key to false. Defaults to true
    /// when biometrics are available on the device, false otherwise.
    private static let preferenceKey = "ParleyBiometricLockEnabled"

    /// How long the app may sit in the background before we challenge again. Anything shorter
    /// (a share sheet round-trip, a quick app switch) returns to an unlocked state without a
    /// Face ID prompt — matching what 1Password / banking apps do.
    private let gracePeriod: TimeInterval = 30

    private var leftForegroundAt: Date?

    init() {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.preferenceKey) == nil {
            defaults.set(canEvaluate, forKey: Self.preferenceKey)
        }
        let enabled = defaults.bool(forKey: Self.preferenceKey)
        self.isLocked = canEvaluate && enabled
    }

    func authenticate() async {
        let context = LAContext()
        context.localizedReason = "Unlock Parley"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // No biometrics available — unlock.
            isLocked = false
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock Parley to view your recordings."
            )
            if success {
                isLocked = false
                lastError = nil
            }
        } catch let err as LAError where err.code == .userCancel || err.code == .systemCancel || err.code == .appCancel {
            // User dismissed the prompt themselves or iOS cancelled it (e.g. competing
            // auth context, share sheet still settling). Stay locked but don't show an
            // error — the Unlock button stays available for manual retry.
            lastError = nil
        } catch let err as LAError {
            lastError = err.localizedDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// React to scene phase changes. Re-locks only if the app was away from the foreground
    /// longer than `gracePeriod`, so quick share-and-returns don't challenge.
    func handleScenePhase(_ phase: ScenePhase) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.preferenceKey) else { return }
        switch phase {
        case .background, .inactive:
            if leftForegroundAt == nil {
                leftForegroundAt = Date()
            }
        case .active:
            defer { leftForegroundAt = nil }
            guard let left = leftForegroundAt else { return }
            if Date().timeIntervalSince(left) > gracePeriod {
                let context = LAContext()
                if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                    isLocked = true
                }
            }
        @unknown default:
            break
        }
    }
}

struct LockGate<Content: View>: View {
    @StateObject private var state = LockState()
    @Environment(\.scenePhase) private var phase

    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            content()
            if state.isLocked {
                lockScreen
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.isLocked)
        .task(id: state.isLocked) {
            if state.isLocked { await state.authenticate() }
        }
        .onChange(of: phase) { _, newPhase in
            state.handleScenePhase(newPhase)
        }
    }

    private var lockScreen: some View {
        ZStack {
            BraunPalette.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(BraunPalette.foreground)
                Text("Parley").braunLabel(size: 11)
                if let err = state.lastError {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(BraunPalette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Button {
                    Task { await state.authenticate() }
                } label: {
                    Text("Unlock").braunLabel(size: 11)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Rectangle().stroke(BraunPalette.foreground, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
