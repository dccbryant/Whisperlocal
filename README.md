# Whisperlocal

An iOS app that records audio, transcribes it, and summarizes it — **entirely on your device**. No cloud, no analytics, no network.

> Status: **Phase 2**. Recording + real on-device transcription via `whisper.cpp` work end-to-end. Summarization is still mock (Phase 3).

## Privacy posture

- `NSAppTransportSecurity` blocks arbitrary loads (HTTPS-only).
- No iCloud / CloudKit containers; no analytics SDKs.
- Microphone usage string is explicit about local-only processing.
- **One network call, ever**: the first launch downloads the Whisper model from Hugging Face. After that, audio and transcripts never leave the device. The download can be replaced by bundling the model file into `Whisperlocal/Resources/Models/` if you'd prefer zero network use.

## Requirements

- macOS with Xcode 15.3+
- iOS 17.0+ device or simulator (mic recording works on device; simulator mic works on macOS hosts with input)
- Optional but recommended: [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Getting started

### Option A — XcodeGen (recommended)

```bash
brew install xcodegen      # one-time
xcodegen generate          # produces Whisperlocal.xcodeproj
open Whisperlocal.xcodeproj
```

Then in Xcode: select the **Whisperlocal** scheme, choose your device, and Run.

### Option B — Hand-rolled Xcode project

1. Xcode → File → New → Project → iOS → App.
2. Product Name: `Whisperlocal`. Interface: SwiftUI. Language: Swift. Min deployment: iOS 17.0.
3. Delete the generated `ContentView.swift` and `WhisperlocalApp.swift`.
4. Drag the `Whisperlocal/` folder from this repo into the project navigator (Copy if needed, Create groups).
5. Replace the generated `Info.plist` with `Whisperlocal/Info.plist`, or copy these keys over:
   - `NSMicrophoneUsageDescription`
   - `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = false`
6. Add `Whisperlocal/Whisperlocal.entitlements` to the target (Signing & Capabilities → drag in).
7. Build & Run.

## Project layout

```
Whisperlocal/
├── WhisperlocalApp.swift         # @main entry
├── SessionStore.swift            # app state machine: record → transcribe → summarize
├── Info.plist
├── Whisperlocal.entitlements
├── Audio/
│   └── AudioRecorder.swift       # AVAudioRecorder wrapper, 16 kHz mono AAC
├── Transcription/
│   └── TranscriptionService.swift  # protocol + Mock impl. Whisper.cpp impl lands in Phase 2.
├── Summarization/
│   └── SummarizationService.swift  # protocol + Mock impl. Llama.cpp impl lands in Phase 3.
├── Models/
│   └── Recording.swift
├── Views/
│   └── RootView.swift            # SwiftUI UI
└── Resources/                    # bundled assets; downloaded models live under Models/ (gitignored)
```

## Roadmap

- **Phase 1 (done):** Scaffold + recording + mock services + UI flow.
- **Phase 2 (done):** [whisper.cpp](https://github.com/ggerganov/whisper.cpp) via SwiftPM. First-launch download of `ggml-small.en-q5_1.bin` (~190 MB) into Application Support, with progress UI. Real `WhisperCppTranscriptionService` decoding AAC → 16 kHz PCM via AVFoundation and running Whisper on-device.
- **Phase 3:** Integrate [llama.cpp](https://github.com/ggerganov/llama.cpp) with a quantized small instruct model (e.g. Llama 3.2 3B Q4_K_M). Real `LlamaCppSummarizationService` with a summarization prompt template.
- **Phase 4 polish:** Recording library with on-device search, export to plain text, share sheet (user-initiated), background processing, accessibility.

## Bundling the model instead of downloading it

If you'd rather ship the model inside the app (zero network use, larger `.ipa`):

1. Download `ggml-small.en-q5_1.bin` from <https://huggingface.co/ggerganov/whisper.cpp> on your Mac.
2. Drop it into `Whisperlocal/Resources/Models/`.
3. In Xcode, make sure the file is included in the **Whisperlocal** target (check it under Target Membership in the File Inspector).
4. `ModelStore.bundledURL()` will find it and skip the download.

## License

TBD — pick one before publishing.
