# Parley — Technical Reference

## 1. What it is

iOS app that records conversations and produces structured notes (title, summary, topics, transcript) entirely on-device. No backend, no cloud inference, no analytics. The only network call is the first-launch download of the ML models from a public model repository.

## 2. Platform target

- **iOS 17.0** minimum deployment target
- **iOS 26.0** required for summarization (Apple Foundation Models). On earlier iOS or non-Apple-Intelligence devices, summarization degrades to a mock; transcription and diarization still work.
- **iPhone only** (`TARGETED_DEVICE_FAMILY: "1"`)
- **Portrait orientation only**
- **Light mode locked** (`.preferredColorScheme(.light)` — the Braun palette doesn't translate to dark)
- **Swift 5.9**, built with **Xcode 15.3+**

## 3. Architecture

Two-target Xcode project, generated from `project.yml` via **XcodeGen**:

1. **Parley** — the main app
2. **ParleyLiveActivity** — a WidgetKit extension hosting the Live Activity

Source layout:

```
Parley/
├── ParleyApp.swift              @main + LockGate
├── SessionStore.swift           Pipeline state machine
├── Info.plist
├── Parley.entitlements
├── Audio/
│   ├── AudioRecorder.swift      AVAudioRecorder wrapper
│   ├── AudioPlayer.swift        AVAudioPlayer wrapper
│   └── RecordingActivityManager.swift   ActivityKit lifecycle
├── Transcription/
│   ├── AudioFileReader.swift    File → [Float] for WhisperKit
│   └── WhisperKitTranscriptionService.swift  Diarize + transcribe
├── Summarization/
│   └── SummarizationService.swift   Apple FM + mock
├── Models/
│   ├── Recording.swift          Codable domain model
│   ├── RecordingStore.swift     Encrypted persistence
│   ├── RecordingExport.swift    Share text formatter
│   ├── ParleyCrypto.swift       Master AES key
│   └── EncryptedStore.swift     File I/O helpers + audio staging
├── Resources/Assets.xcassets/   AppIcon + LaunchBackground color
└── Views/
    ├── DesignSystem.swift       Braun palette + type
    ├── RootView.swift           Home screen
    ├── LibraryView.swift        Recordings list
    ├── RecordingDetailView.swift   Detail / playback / edit
    ├── LockGate.swift           Biometric gate
    ├── AboutView.swift          About sheet
    ├── AppIconDesign.swift      In-app icon exporter
    └── WaveformView.swift       AVAssetReader-based waveform

ParleyLiveActivity/
├── ParleyLiveActivityBundle.swift   @main widget bundle
├── RecordingLiveActivity.swift      Lock screen + Dynamic Island UI
└── Info.plist

Shared/
└── RecordingActivityAttributes.swift   ActivityKit Codable shape (used by both targets)
```

## 4. ML models

### 4.1 Transcription — WhisperKit (Argmax OSS)

- **Package**: `argmax-oss-swift` (`https://github.com/argmaxinc/argmax-oss-swift`), tracking `main`
- **Product**: `WhisperKit`
- **Model**: `openai_whisper-small.en` (~250 MB), CoreML-compiled, English-only
- **Compute units**: Neural Engine (with automatic CPU fallback on simulator since the simulator has no ANE)
- **Input format**: 16 kHz mono Float32 PCM, normalized to [-1, 1]
- **API used**: `whisper.transcribe(audioArray: [Float])` — we never use the file-path variant because it had decode issues with certain m4a files on simulator during development
- **Transcription strategy**: the full audio is transcribed in **bounded ~2-minute windows** (sequentially, with a brief rest and a one-shot retry per window), not one giant call and not one call per speaker turn. The single-giant-call approach hammered the ANE continuously until CoreML's "ML Program prediction" watchdog timed out on long recordings; the old per-speaker-turn slicing paid ~5 s of fixed per-call overhead on every segment (hundreds of calls on a long meeting). Windowing keeps each call within a proven-safe size while staying fast — an hour transcribes in minutes, not 8–10+.
- **Token cleanup**: Whisper's per-segment text carries raw special/timestamp tokens (`<|startoftranscript|>`, `<|0.00|>`); these are stripped and whitespace collapsed before display.
- **Model download**: handled by WhisperKit on first call; caches under the app's sandbox

### 4.2 Speaker diarization — SpeakerKit (Argmax OSS, same package)

- **Product**: `SpeakerKit`
- **Backbone**: Pyannote-based CoreML pipeline
- **Input format**: same 16 kHz mono Float32 PCM
- **API used**: `speakers.diarize(audioArray: [Float])` → `DiarizationResult` with `segments: [SpeakerSegment]`
- **Speaker labels**: raw cluster IDs from Pyannote (which can be sparse — `0, 3, 7`) are remapped to dense 1-based labels `Speaker 1`, `Speaker 2`, … in first-appearance (time) order
- **Speaker assignment**: because transcription is windowed (not sliced per speaker turn), each Whisper segment is assigned a speaker by **maximum timestamp overlap** with the diarization ranges (nearest-range fallback when a segment lands in a gap). Consecutive same-speaker segments are then merged into one "Speaker N" turn.

### 4.3 Summarization, title, topics — Apple Foundation Models

- **Framework**: `FoundationModels` (iOS 26+)
- **Model**: `SystemLanguageModel.default` (Apple Intelligence's ~3B-parameter on-device model)
- **API**: `LanguageModelSession(instructions:)` + `session.respond(to:)` for free-form output
- **Structured output**: `@Generable` macro for topics (`GenerableTopics`/`GenerableTopic`) so they return as typed Swift structs rather than parsed JSON
- **Availability gating**: `@available(iOS 26.0, *)`. Falls back to `MockSummarizationService` on older iOS or non-Apple-Intelligence devices.
- **What it produces**: `analyze(_:)` returns a `MeetingExtraction` of **summary + topics**; `title(for:)` is a separate call (3–5 word headline; input truncated to 4 K chars). Action items, decisions, attendees, open questions, and key dates have all been removed from the pipeline.
- **Chunking + map-reduce**: transcripts are split on speaker-turn (newline) boundaries at ~6 K chars/chunk (keeps the full prompt under the model's ~4096-token window). Summary runs hierarchical map-reduce (per-chunk brief → recursive compress while >3.5 K → final reduce); topics are unioned per chunk then fuzzy-deduped.
- **Sequential + paced**: the per-chunk sub-passes (brief summary, topics) run **sequentially with a short `breathe()` between each call**, not concurrently. Firing them concurrently per chunk tripped the on-device model's rate limiter on long meetings, cascading until every pass returned empty. `title()` also takes a beat before firing so it doesn't land on the limiter right after the analyze burst.
- **Failure handling**:
  - **Refusals are not retried** (content-safety refusals are deterministic — a retry only wastes a session and adds rate-limit pressure); **rate-limit errors back off ~3 s** before a single retry; other transient errors retry after 500 ms.
  - **Summary never blanks on a failed reduce**: if the final polish pass fails, the summary falls back to the joined per-chunk briefs already produced.
  - **A successful transcript is never discarded** if summarization fails — the recording is saved and the detail view offers a **Generate summary** retry (`SessionStore.resummarize(_:)`, which re-runs `analyze` + `title` on the saved transcript, no re-transcription).
- **Dedupe**: lowercased, punctuation-stripped, stopwords removed (`the`, `a`, `to`, `for`, `and`, `or`, `but`, `by`, `of`, `in`, `on`, `with`, `from`, `is`, `it`, `this`, `that`, `be`, `will`); substring-containment treated as duplicate; topics also use Jaccard word-overlap ≥ 0.45 and are capped at 5.

## 5. Audio pipeline

### 5.1 Recording

- **Engine**: `AVAudioRecorder`
- **Session category**: `.record`, mode `.measurement` (no playback mixing)
- **Format**: 16 kHz mono 16-bit Linear PCM in `.wav` container — exactly what Whisper needs internally, no transcode required
- **Buffer settings**: `isMeteringEnabled = true` for the level meter
- **Plaintext location**: `NSTemporaryDirectory/ParleyRecording/<ISO-8601>-<8-char UUID>.wav`
- **Background**: `UIBackgroundModes = [audio]`; idle timer disabled while recording so the screen doesn't auto-lock
- **Interruption handling**: subscribes to `AVAudioSession.interruptionNotification`. On `.began` (e.g., incoming call), pauses the recorder, freezes the elapsed timer; on `.ended` with `.shouldResume`, reactivates the session, shifts `startedAt` forward by the paused duration, resumes. UI reflects pause state with a "Paused" pill + dimmed level meter.
- **Live Activity**: started on `record()`, updated every meter tick (~10 Hz throttled to scene phase), ended on stop. Uses `Text(timerInterval:)` for the elapsed counter so iOS handles tick rendering after the app backgrounds.

### 5.2 Playback

- **Engine**: `AVAudioPlayer(contentsOf:)`
- **Session category swapped to `.playback`** when playback starts (the recording session would have routed to the earpiece)
- **Audio is always played from a decrypted temp file** staged in `NSTemporaryDirectory/parley-stage-<UUID>.<ext>`; the encrypted blob on disk is never read by AVFoundation
- **Cleanup**: temp file is removed on `RecordingDetailView.onDisappear`

### 5.3 Waveform

- **Engine**: `AVAssetReader` (not `AVAudioFile` — that was stricter about formats and failed silently on some imported m4a files)
- **Settings**: decoded to mono Float32 PCM up front
- **Algorithm**: streams 64 K-frame buffers; accumulates per-bucket peak amplitudes; normalizes to the loudest bucket; 200 buckets target, downsampled at display time based on view width

## 6. Encryption

Three layers stacked on top of iOS's default file protection.

### 6.1 Layer 1 — iOS Data Protection class

All persisted files written with `.completeFileProtection` (NSFileProtectionComplete). Files become unreadable the moment the device locks, not just before first boot-unlock. Exceptions:
- The active recording file (in temp dir) uses `.completeFileProtectionUnlessOpen` so writes survive a mid-recording screen lock
- Staged decrypted audio files (also temp) use `.completeFileProtectionUnlessOpen` so playback survives a lock

### 6.2 Layer 2 — AES-GCM on sidecar metadata

Every transcript / summary / title / action item / speaker name lives in a JSON sidecar (`<filename>.wav.json`) under `Documents/Recordings/`. Before writing, the JSON bytes are sealed with **AES-256-GCM** using `CryptoKit`'s `AES.GCM.seal(_:using:)`. A 4-byte magic header `PRLY` (`0x50 0x52 0x4C 0x59`) is prepended so we can distinguish encrypted blobs from any legacy plaintext (used for the one-shot migration of pre-encryption recordings).

### 6.3 Layer 3 — AES-GCM on audio

Same scheme applied to the audio file bytes themselves. The encrypted audio file keeps a `.wav` extension for convenience but the bytes inside are a sealed blob. Decryption happens at the boundary: when the user opens a recording's detail view, the encrypted bytes are read, decrypted in memory, written to a `.completeFileProtectionUnlessOpen` temp file, and that temp URL is what `AVAudioPlayer` / `AVAssetReader` consume. Temp file is removed on dismiss.

### 6.4 Master key

- **Algorithm**: 256-bit AES, `CryptoKit.SymmetricKey(size: .bits256)`
- **Storage**: iOS Keychain (`kSecClassGenericPassword`)
- **Account**: `com.davidbryant.parley.dataKey`
- **Accessibility**: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
  - **WhenUnlocked** → key not accessible while device is locked
  - **ThisDeviceOnly** → key never syncs to iCloud Keychain; **excluded from unencrypted backups**
- **Lifecycle**: generated on first launch; cached in memory for the app process; cleared from cache when the lock gate re-locks (the on-disk Keychain item persists)
- **Lifetime**: nothing in the codebase ever migrates, rotates, or exports this key — losing the device or wiping Keychain destroys the data forever. Documented as such in the About sheet.

### 6.5 Threat coverage table

| Scenario | Outcome |
|---|---|
| Device lost, locked | Encrypted at the iOS layer + AES layer |
| Device lost, unlocked | Face ID gate on the app blocks access |
| File system extraction via another app | Sees opaque PRLY-prefixed AES-GCM blobs |
| Encrypted iTunes/Finder backup | Backup contains the encrypted blobs but not the key (ThisDeviceOnly) |
| iCloud backup compromise | Same — key never leaves the device |
| Jailbreak + file extraction while logged in | Gets the AES blobs; needs the Keychain key, which requires app process + unlocked device |

## 7. Privacy posture

- **No analytics SDKs**, no telemetry, no crash reporters
- **No iCloud / CloudKit containers**
- **App Transport Security**: arbitrary loads blocked (HTTPS-only)
- **One outbound network use**: WhisperKit downloads its model from Hugging Face on first launch. No user data is transmitted with that request — it's a plain HTTPS GET of public model files. After that, the app operates entirely offline.
- **Microphone usage description**: explicit about local-only processing
- **Permissions requested**:
  - `NSMicrophoneUsageDescription` — recording
  - `NSFaceIDUsageDescription` — app lock

## 8. App-lock gate

- **Framework**: `LocalAuthentication`
- **Policy**: `LAPolicy.deviceOwnerAuthenticationWithBiometrics`
- **On cold launch**: if biometrics are available, the app starts locked. Tapping anywhere triggers Face ID.
- **Grace period**: 30 seconds. If the app is backgrounded for less than 30 s (e.g., a share-sheet round-trip), it stays unlocked on return. Longer absence re-locks.
- **Cancellation handling**: `userCancel`, `systemCancel`, `appCancel` LAErrors are swallowed silently — the lock screen stays available with a manual "Unlock" button. Real errors (lockout, not enrolled) surface as messages.
- **UserDefaults flag**: `ParleyBiometricLockEnabled` — defaults to true when biometrics are available, false otherwise. No UI to toggle yet.

## 9. Data model

```swift
struct Recording: Identifiable, Hashable, Codable {
    let id: UUID
    let audioFilename: String          // relative to Documents/Recordings
    let createdAt: Date
    var duration: TimeInterval
    var segments: [TranscriptSegment]  // diarized + transcribed
    var summary: String?
    var title: String?                  // 3–5 word headline
    var topics: [Topic]                 // main topics, each with supporting points
    // Retained for Codable compatibility with older saved recordings, but no longer
    // populated by the pipeline:
    var decisions: [String]
    var actionItems: [ActionItem]
    var attendees: [String]
    var openQuestions: [String]
    var keyDates: [String]
    var customSpeakerNames: [String: String]  // "Speaker 1" → "Sarah"
}

struct TranscriptSegment: Identifiable, Hashable, Codable {
    var id = UUID()
    let speakerLabel: String  // raw cluster label, "Speaker N"
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct Topic: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String           // 3–6 word label
    var points: [String]        // 2–3 supporting sentences
}

// ActionItem still exists for decoding older recordings, but is never produced anymore.
struct ActionItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var assignee: String
    var task: String
    var dueDate: String?
}
```

Backwards-compat: `Recording.init(from:)` uses `decodeIfPresent` for every field added after the original Phase 4 storage format, so older recordings still load (deprecated fields decode to whatever was saved; new recordings leave them empty).

Display-time speaker resolution: `Recording.resolveSpeakerReferences(in:)` walks any text and replaces "Speaker N" with the custom display name (longest-label-first so "Speaker 10" doesn't get clobbered by "Speaker 1"). Applied to summary, topic points, transcript, and share output. Single source of truth = the `customSpeakerNames` map.

## 10. UI

- **Framework**: SwiftUI throughout
- **Design system** (`DesignSystem.swift`):
  - Background: warm off-white `RGB(0.945, 0.925, 0.875)`
  - Surface (card): beige `RGB(0.910, 0.885, 0.825)`
  - Foreground: charcoal `RGB(0.145, 0.145, 0.145)`
  - Secondary: warm gray `RGB(0.435, 0.415, 0.380)`
  - Divider hairline: `RGB(0.780, 0.745, 0.665)`
  - Accent (Braun orange): `RGB(0.905, 0.290, 0.110)`
  - Recording red: `RGB(0.700, 0.150, 0.080)`
- **Type roles** (all SF Pro):
  - `braunLabel` — 10 pt semibold, kerning 2.2, uppercase, secondary color
  - `braunBody` — 15 pt regular, foreground, line spacing 2
  - `braunDigit` — 13 pt medium, monospaced design (used in library row timestamps, transport timer, segment time ranges)
- **State management**:
  - `SessionStore` (@MainActor ObservableObject) — pipeline state machine (`.idle / .recording / .transcribing / .summarizing / .done / .failed`)
  - `RecordingStore` (@MainActor ObservableObject) — persistent library, owns the Recordings/ directory
  - `LockState` (@MainActor ObservableObject) — biometric gate
  - `AudioRecorder` / `AudioPlayer` / `WaveformModel` — view-local ObservableObjects
  - Combine forwarding from `AudioRecorder.objectWillChange` into `SessionStore.objectWillChange` so nested @Published values (elapsed, peakLevel) propagate to views observing the SessionStore via @EnvironmentObject

## 11. Live Activity

- **Framework**: ActivityKit (iOS 16.1+)
- **Attributes**: `RecordingActivityAttributes` lives in `Shared/`, compiled into both the app and the widget extension targets so they share the same Codable shape
- **State**: `startedAt: Date`, `peakLevel: Float`
- **Lock screen rendering**: charcoal-on-beige card with mic icon, "PARLEY · RECORDING" label, ticking `Text(timerInterval:)`
- **Dynamic Island**: leading mic icon, trailing timer, expanded view adds a level bar
- **Widget bundle ID**: `com.davidbryant.parley.LiveActivity`
- **Info.plist**: `NSExtensionPointIdentifier = com.apple.widgetkit-extension`

## 12. Background recording

- **`UIBackgroundModes: [audio]`** in Info.plist — allows the AVAudioSession to stay active when backgrounded or locked
- **Idle timer**: disabled in `AudioRecorder.start()`, re-enabled in `stop()` — keeps the screen awake while recording
- **AVAudioSession category**: `.record`, mode `.measurement` — compatible with background audio

## 13. Share output

`RecordingExport.body(for:)` produces a single plain-text string with visible separator markers so structure survives Gmail's whitespace collapse:

```
PARLEY · TITLE
Friday, May 31, 2026 at 7:06 PM · 03:42

────── SUMMARY ──────
[prose summary, speaker references resolved]

────── TOPICS ──────
Topic title
• [supporting point]
• [supporting point]

────── TRANSCRIPT ──────
Sarah: ...
Speaker 2: ...
```

Empty sections are omitted, so the now-unused Action Items branch never renders (action items are no longer produced). Speaker rename map is applied to summary, topic points, and transcript before formatting. Plain text only — the earlier attempt at a Transferable with an HTML representation caused iOS Mail to deliver blank composes.

## 14. Dependencies

| Package | Used for | Version |
|---|---|---|
| `argmax-oss-swift` | `WhisperKit`, `SpeakerKit` | `branch: main` |
| Apple `CryptoKit` | AES-256-GCM | system |
| Apple `Security` | Keychain | system |
| Apple `LocalAuthentication` | Face ID gate | system |
| Apple `FoundationModels` | Summarization (iOS 26+) | system |
| Apple `ActivityKit` | Live Activity | system |
| Apple `WidgetKit` | Live Activity widget | system |
| Apple `AVFoundation` | Recording, playback, waveform | system |

Project is generated with **XcodeGen 2.x** from `project.yml`. The `.xcodeproj` is `.gitignore`d.

## 15. Build configuration

- **Bundle ID**: `com.davidbryant.parley` (main), `com.davidbryant.parley.LiveActivity` (widget)
- **Team ID**: `2A29M932WB`
- **Code signing**: Automatic
- **`ITSAppUsesNonExemptEncryption: false`** — qualifies for the standard exemption (AES-GCM + TLS, both via Apple's OS-provided crypto)
- **`LSSupportsOpeningDocumentsInPlace: false`** + **`UISupportsDocumentBrowser: false`** — Parley copies imports into its sandbox, doesn't edit files in place
- **`CFBundleDocumentTypes`** — registers Parley as a handler for `public.audio`, `public.mp3`, `public.mpeg-4-audio`, `com.microsoft.waveform-audio` (for "Open in Parley" from Files)

## 16. Known limitations

- Apple Foundation Models has a ~4K-token context. Long transcripts are chunked at speaker-turn boundaries; hierarchical map-reduce can occasionally produce vague summaries on very long meetings (>1 hour).
- Topics are fuzzy-deduped (substring + Jaccard ≥ 0.45), not Levenshtein-based, so a near-duplicate phrasing can occasionally slip through.
- Transcription is windowed at fixed ~2-minute boundaries; a word landing exactly on a window edge can be clipped (rare; no overlap stitching yet).
- Speaker assignment is by timestamp overlap with diarization, so crosstalk or imprecise diarization boundaries can misattribute a short segment.
- No way to disable the Face ID gate from inside the app yet (would need a Settings screen). The flag can be flipped via UserDefaults if needed.
- Imported audio files lose original container metadata (artist, album, etc.) — Parley only cares about the audio samples.
- Mock summarizer output is bracketed with `[mock summary]` to make it obvious when Apple Intelligence isn't available — on a non-AI device the summary section will look stub-like.

## 17. Repo URLs

- **Source**: <https://github.com/dccbryant/Whisperlocal> (named after the working prototype; the app renamed to Parley in Phase 4)
- **Privacy policy**: <https://dccbryant.github.io/Whisperlocal/PRIVACY.html>
- **App Store bundle**: `com.davidbryant.parley`
