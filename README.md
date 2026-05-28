# Whisperlocal

An iOS app that records audio, transcribes it, and summarizes it — **entirely on your device**. No cloud, no analytics, no telemetry.

> Status: **Phase 3**. End-to-end on-device pipeline: record → speaker diarization (SpeakerKit) → transcription (WhisperKit) → summarization (Apple Foundation Models). Share sheet for the result. Date/time on every recording.

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
- **Phase 2 (done):** WhisperKit for on-device transcription on the Neural Engine.
- **Phase 3 (done):** SpeakerKit diarization, Apple Foundation Models summarization, share sheet, date/time on results.
- **Phase 4 ideas:** Persistent recording library with on-device search, recording playback, background processing, accessibility, multilingual model option.

## Apple Intelligence requirement for summarization

The on-device summarizer uses Apple's `FoundationModels` framework, which needs **iOS 26+** running on an Apple Intelligence capable device (iPhone 15 Pro / Pro Max / 16 family or newer). On any other device, summarization gracefully degrades to a placeholder — transcription and diarization still work everywhere iOS 17+ runs.

## Choosing a different Whisper model

WhisperKit defaults to `openai_whisper-base.en` (small, fast, English-only). To use a different one — e.g. the more accurate `openai_whisper-small.en` or multilingual `openai_whisper-base` — change `defaultModel` in `Whisperlocal/Transcription/WhisperKitTranscriptionService.swift`. Available models are listed in WhisperKit's README.

## License

TBD — pick one before publishing.
