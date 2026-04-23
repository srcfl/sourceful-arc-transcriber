# Transcriber

A minimal macOS menu bar app for recording and (eventually) transcribing audio locally with Whisper.

## Status

- **M1 — mic recording (current):** Menu bar icon, Start/Stop, saves 16 kHz mono WAV to `~/Documents/Transcripts/`.
- M2 — local Whisper transcription on stop (WhisperKit).
- M3 — live streaming transcription in a popover.
- M4 — system audio capture via ScreenCaptureKit (capture meeting audio).
- M5 — polish: auto-detect meetings, hotkey, model picker, history.

## Build & run

Requires macOS 13+, Xcode command line tools, Swift 5.9+.

```bash
./build.sh
open build/Transcriber.app
```

The icon (waveform) appears in the menu bar. Click it → **Start Recording**. macOS will prompt for microphone permission on first run. Click **Stop Recording** and the WAV is written to `~/Documents/Transcripts/`.

## Layout

```
Package.swift              # SPM executable
Sources/Transcriber/
  main.swift               # AppKit status item + AVAudioRecorder
Resources/
  Info.plist               # LSUIElement + NSMicrophoneUsageDescription
build.sh                   # swift build → .app bundle → ad-hoc sign
```

## Design notes

- AppKit (`NSStatusItem`) instead of SwiftUI `MenuBarExtra` — simpler lifecycle when the binary is a plain SPM executable bundled manually.
- `.accessory` activation policy so no Dock icon.
- Ad-hoc codesigning (`codesign --sign -`) is enough for local dev; TCC microphone permission is tied to the bundle's code signature, so rebuilds keep the same grant.
- 16 kHz mono matches what Whisper wants — no resampling later.
