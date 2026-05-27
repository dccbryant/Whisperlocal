# Whisperlocal

An iOS app that records audio, transcribes it, and summarizes it — **entirely on your device**. No cloud, no analytics, no telemetry.

> Status: **Phase 2**. Recording + real on-device transcription via [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) work end-to-end. Summarization is still mock (Phase 3).

## Privacy posture

- `NSAppTransportSecurity` blocks arbitrary loads (HTTPS-only).
- No iCloud / CloudKit containers; no analytics SDKs.
- Microphone usage string is explicit about local-only processing.
- **One network call, ever**: the first launch lets WhisperKit fetch the Whisper CoreML model from Hugging Face. After that, audio and transcripts never leave the device.

## Requirements

- macOS with Xcode 15.3+
- iOS 17.0+ device or simulator
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Getting started

```bash
brew install xcodegen        # one-time
xcodegen generate            # produces Whisperlocal.xcodeproj
open Whisperlocal.xcodeproj
```

In Xcode: pick an **iPhone 15 Pro** simulator in the destination picker, then ▶ Run. First launch downloads the WhisperKit model in the background; you'll see "Preparing on-device model…" until it's ready.

## Project layout

```
Whisperlocal/
├── WhisperlocalApp.swift              # @main entry
├── SessionStore.swift                 # state machine: record → transcribe → summarize
├── Info.plist
├── Whisperlocal.entitlements
├── Audio/
│   └── AudioRecorder.swift            # AVAudioRecorder wrapper
├── Transcription/
│   ├── TranscriptionService.swift     # protocol + mock
│   └── WhisperKitTranscriptionService.swift  # real on-device impl
├── Summarization/
│   └── SummarizationService.swift     # protocol + mock (Phase 3 lands here)
├── Models/
│   └── Recording.swift
└── Views/
    └── RootView.swift
```

## Roadmap

- **Phase 1 (done):** Scaffold + recording + mock services + UI flow.
- **Phase 2 (done):** WhisperKit for on-device transcription. CoreML-backed, runs on the Neural Engine on supported iPhones. Model auto-downloads on first launch.
- **Phase 3:** Integrate [llama.cpp](https://github.com/ggerganov/llama.cpp) (or Apple's Foundation Models on capable devices) for on-device summarization.
- **Phase 4 polish:** Recording library with on-device search, export to plain text, share sheet, background processing, accessibility.

## Choosing a different Whisper model

WhisperKit defaults to `openai_whisper-base.en` (small, fast, English-only). To use a different one — e.g. the more accurate `openai_whisper-small.en` or multilingual `openai_whisper-base` — change `defaultModel` in `Whisperlocal/Transcription/WhisperKitTranscriptionService.swift`. Available models are listed in WhisperKit's README.

## License

TBD — pick one before publishing.
