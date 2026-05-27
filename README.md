# Whisperlocal

An iOS app that records audio, transcribes it, and summarizes it — **entirely on your device**. No cloud, no analytics, no network.

> Status: **scaffold (Phase 1)**. Recording + UI flow work end-to-end with mock transcription/summary. Real `whisper.cpp` and `llama.cpp` integration are Phase 2 and 3.

## Privacy posture

- No network entitlements requested.
- `NSAppTransportSecurity` blocks arbitrary loads.
- No iCloud / CloudKit containers.
- Microphone usage string is explicit about local-only processing.
- Models (added in Phase 2/3) live in the app's sandbox; you may opt to download them on first launch from a server you control, then run fully offline thereafter.

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
- **Phase 2:** Integrate [whisper.cpp](https://github.com/ggerganov/whisper.cpp) via Swift Package Manager. Add a small Obj-C++ bridge. First-launch download of a quantized model (e.g. `ggml-small.en-q5_1.bin`, ~250 MB) into Application Support, with a progress UI. Real `WhisperCppTranscriptionService`.
- **Phase 3:** Integrate [llama.cpp](https://github.com/ggerganov/llama.cpp) the same way with a quantized small instruct model (e.g. Llama 3.2 3B Q4_K_M). Real `LlamaCppSummarizationService` with a summarization prompt template.
- **Phase 4 polish:** Recording library with on-device search, export to plain text, share sheet (user-initiated), background processing, accessibility.

## License

TBD — pick one before publishing.
