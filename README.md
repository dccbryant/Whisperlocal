# Parley

An iOS app that records conversations, identifies speakers, transcribes them, and summarizes them — **entirely on your device**. No cloud, no analytics, no telemetry.

Originally prototyped under the name *Whisperlocal*. Renamed to Parley — an English word for a private confidential conversation.

> Status: **Phase 4**. End-to-end on-device pipeline: record → speaker diarization (SpeakerKit) → transcription (WhisperKit) → summarization (Apple Foundation Models). Braun-inspired UI. Persistent recording library. Share-sheet export.

## Privacy posture

- `NSAppTransportSecurity` blocks arbitrary loads (HTTPS-only).
- No iCloud / CloudKit containers; no analytics SDKs.
- Microphone usage string is explicit about local-only processing.
- **One network call, ever**: the first launch lets WhisperKit fetch the Whisper CoreML model from Hugging Face. After that, audio and transcripts never leave the device.

## Requirements

- macOS with Xcode 15.3+
- iOS 17.0+ device or simulator (real device strongly recommended — Whisper's CoreML pipeline is unreliable on the iOS Simulator)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Getting started

```bash
brew install xcodegen        # one-time
xcodegen generate            # produces Parley.xcodeproj
open Parley.xcodeproj
```

In Xcode: pick your iPhone in the destination picker, then ▶ Run. First launch downloads the on-device speech and speaker models in the background; you'll see "Preparing models…" until they're ready.

## Project layout

```
Parley/
├── ParleyApp.swift                # @main entry
├── SessionStore.swift             # state machine: record → transcribe → summarize
├── Info.plist
├── Parley.entitlements
├── Audio/
│   └── AudioRecorder.swift
├── Transcription/
│   ├── AudioFileReader.swift
│   └── WhisperKitTranscriptionService.swift
├── Summarization/
│   └── SummarizationService.swift
├── Models/
│   ├── Recording.swift
│   ├── RecordingStore.swift       # persistent library
│   └── RecordingExport.swift      # share-sheet formatting
└── Views/
    ├── DesignSystem.swift         # Braun 1968 palette + type
    ├── RootView.swift
    ├── LibraryView.swift
    └── RecordingDetailView.swift
```

## Roadmap

- **Phase 1 (done):** Scaffold + recording + mock services + UI flow.
- **Phase 2 (done):** WhisperKit for on-device transcription on the Neural Engine.
- **Phase 3 (done):** SpeakerKit diarization, Apple Foundation Models summarization, share sheet, date/time on results.
- **Phase 4 (done):** Braun 1968 redesign, persistent recording library, formatted share output.
- **Phase 5 ideas:** Recording playback, on-device search, accessibility audit, app icon + launch screen, multilingual model option.

## Apple Intelligence requirement for summarization

The on-device summarizer uses Apple's `FoundationModels` framework, which needs **iOS 26+** running on an Apple Intelligence capable device (iPhone 15 Pro / Pro Max / 16 family or newer). On any other device, summarization gracefully degrades to a placeholder — transcription and diarization still work everywhere iOS 17+ runs.

## Choosing a different Whisper model

WhisperKit defaults to `openai_whisper-base.en` (small, fast, English-only). To use a different one — e.g. the more accurate `openai_whisper-small.en` or multilingual `openai_whisper-base` — change `defaultWhisperModel` in `Parley/Transcription/WhisperKitTranscriptionService.swift`. Available models are listed in WhisperKit's README.

## License

Apache License 2.0. See [LICENSE](LICENSE). Copyright 2026 David Bryant.
