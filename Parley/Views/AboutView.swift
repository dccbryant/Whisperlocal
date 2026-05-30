import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let dict = Bundle.main.infoDictionary
        let v = (dict?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
        let b = (dict?["CFBundleVersion"] as? String) ?? "1"
        return "v\(v) (\(b))"
    }

    var body: some View {
        ZStack {
            BraunPalette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    masthead
                    premiseCard
                    privacyCard
                    encryptionCard
                    attacksCard
                    authorCard
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("About").braunLabel(size: 11)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") { dismiss() }
                    .foregroundStyle(BraunPalette.foreground)
            }
        }
    }

    // MARK: - Sections

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parley")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(BraunPalette.foreground)
            Text(version)
                .braunDigit(size: 11)
                .foregroundStyle(BraunPalette.secondary)
        }
    }

    private var premiseCard: some View {
        BraunCard(title: "What it does") {
            Text("Parley records private conversations, identifies who is speaking, transcribes them, and summarizes them — entirely on your device.")
                .braunBody()
        }
    }

    private var privacyCard: some View {
        BraunCard(title: "Privacy") {
            bulletList([
                "No cloud, no analytics, no telemetry.",
                "No iCloud or CloudKit containers.",
                "App Transport Security blocks arbitrary network loads.",
                "One network call, ever: first launch downloads the on-device speech and speaker models from Hugging Face. After that, audio, transcripts, and summaries never leave the device.",
                "Microphone usage prompted explicitly with a local-only purpose string.",
                "Face ID required to open the app, with a 30-second grace period for share-sheet round-trips.",
            ])
        }
    }

    private var encryptionCard: some View {
        BraunCard(title: "Encryption at rest") {
            VStack(alignment: .leading, spacing: 14) {
                layer(title: "Layer 1 — iOS file protection",
                      body: "Every audio file and transcript on disk is sealed with NSFileProtectionComplete. The bytes are unreadable while the device is locked, derived from your device passcode.")
                layer(title: "Layer 2 — AES-256-GCM on transcripts",
                      body: "Each transcript, summary, and title is sealed with AES-256-GCM before it touches the file system.")
                layer(title: "Layer 3 — AES-256-GCM on audio",
                      body: "Audio files are sealed with the same scheme. The only plaintext audio that ever exists is the moment-by-moment write to a system temp file during active recording, which is encrypted and removed the instant recording stops.")
                Text("The master key is a 256-bit random key generated on first launch and stored in the iOS Keychain with the strictest scope available — ‘when unlocked, this device only’. It is never synced to iCloud Keychain and never included in unencrypted backups.")
                    .braunBody()
            }
        }
    }

    private var attacksCard: some View {
        BraunCard(title: "What this protects against") {
            VStack(alignment: .leading, spacing: 14) {
                attack(scenario: "Lost device, locked",
                       outcome: "Files unreadable. iOS file protection plus AES on top.")
                attack(scenario: "Lost device, unlocked",
                       outcome: "Face ID gate on Parley blocks access to recordings.")
                attack(scenario: "Stranger uses another app to peek at the file system",
                       outcome: "Sees opaque AES blobs. Useless without the key.")
                attack(scenario: "Encrypted iTunes / Finder backup",
                       outcome: "Backup contains encrypted blobs only. The master key is marked device-only and excluded.")
                attack(scenario: "iCloud backup compromise",
                       outcome: "Same. Key never leaves your device.")
                attack(scenario: "Jailbreak with file extraction",
                       outcome: "Gets the AES blobs. Cannot decrypt without the Keychain key, which requires the device to be unlocked and Parley to be running.")
            }
        }
    }

    private var authorCard: some View {
        BraunCard(title: "Author") {
            VStack(alignment: .leading, spacing: 4) {
                Text("David Bryant")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BraunPalette.foreground)
                Text("Built with Claude in May 2026.")
                    .braunBody()
                    .foregroundStyle(BraunPalette.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Text("·").braunBody()
                    Text(item).braunBody()
                }
            }
        }
    }

    private func layer(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).braunLabel(size: 10)
            Text(body).braunBody()
        }
    }

    private func attack(scenario: String, outcome: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(scenario).braunLabel(size: 10)
            Text(outcome).braunBody()
        }
    }
}
