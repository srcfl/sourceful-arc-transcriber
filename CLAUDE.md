# CLAUDE.md

A macOS menu-bar app that records mic + system audio and transcribes it locally. Intended to feed transcripts into the Sourceful Arc backend.

## What this is (and isn't)

- **Is**: a personal / team productivity tool for capturing meeting and voice-note transcripts locally, on-device.
- **Isn't**: energy infrastructure. It lives under the `srcfl` GitHub org alongside Arc but shares none of that domain code. Please keep it that way — don't import anything from other Sourceful repos here without a very good reason.

## Build and run

No Xcode project. Pure SwiftPM executable, `build.sh` assembles the `.app` bundle by hand:

```
swift build -c release
→ copy binary into build/Transcriber.app/Contents/MacOS/
→ copy Resources/Info.plist into Contents/
→ codesign --sign -            # ad-hoc, required so TCC grants persist across rebuilds
```

Platform floor is **macOS 14**. Target is Apple Silicon. Opening the `.app` for the first time triggers the macOS mic prompt and, when starting a recording, the Screen Recording prompt (needed for system-audio capture). **Screen Recording permission only activates after an app relaunch** — this is a macOS quirk, not a bug here.

## Source layout

Everything is in `Sources/Transcriber/`. One file per responsibility:

| File | What lives here |
|---|---|
| `main.swift` | `AppDelegate` (the actual orchestrator). Owns recorders, transcribers, windows, and the status item. `@MainActor`. |
| `MicRecorder.swift` | `AVAudioEngine` + tap. Writes a `.caf` at native hw format, exposes `currentLevel` and optional 16 kHz mono Float samples for live transcription. |
| `SystemAudioRecorder.swift` | `SCStream` capture. Writes a `.caf` via `AVAssetWriter`, computes RMS for the purple meter. |
| `DiarizationRunner.swift` | FluidAudio wrapper. Loads audio as 16 kHz mono Float, returns `[SpeakerTurn]`. |
| `LiveTranscriber.swift` | Rolling 30 s sample buffer + re-transcribe-every-2 s loop. Best-effort, not persisted. |
| `TranscriptMerger.swift` | Merges Whisper segments into speaker-tagged markdown — `You/Others` for channel-tagged, `Speaker 1/2/…` for diarized. |
| `TranscriptsStore.swift` | Scans `~/Documents/Transcripts/`, provides `[TranscriptItem]`, and handles delete (also removes co-located `.wav/.caf`). |
| `AppSettings.swift` | `UserDefaults`-backed ObservableObject. Observed both in `SettingsView` and `main.swift` (for model-change invalidation). |
| `RecordingState.swift` | ObservableObject shared between `AppDelegate` and SwiftUI views — bridges imperative state into SwiftUI. |
| `FloatingControlView.swift` / `TranscriptsView.swift` / `SettingsView.swift` | SwiftUI surfaces. |

## Why the architecture looks the way it does

- **AppKit-first**, SwiftUI only for content. We hit too many sharp edges using `@main` + `MenuBarExtra` from a plain SPM executable, so the app uses `NSApplication`, `NSStatusItem`, and `NSPanel` directly and hosts SwiftUI via `NSHostingController`. That's also why `main.swift` ends with a `MainActor.assumeIsolated { … }` block to start the run loop.
- **`@MainActor` on `AppDelegate`**, recorders are `@unchecked Sendable` with their own serial queues. Each recorder hands levels to the main actor via a lock-protected property read from a polling `Task` — we explicitly avoid shoving `AVAssetWriterInput` / `AVAudioFile` across isolation boundaries.
- **Mic audio is native format, not 16 kHz WAV.** Whisper handles resampling. Keeping native format means the `AVAudioEngine` tap can write directly without a second converter in the hot path — the 16 kHz path exists only for the live transcriber.
- **Meter polling is a single `Task.sleep(50 ms)` loop on the main actor**, not a `Timer`. Timer closures with Swift 6 isolation checks were painful; polling reads `recorder.currentLevel` on each tick.
- **The pill is an `NSPanel` with `.nonactivatingPanel`**, not a `Window`. This keeps it above fullscreen apps (Zoom) without stealing focus. Set to `.canJoinAllSpaces | .stationary | .fullScreenAuxiliary`.
- **Diarization only runs on mic-only recordings.** When both mic and system audio are captured, the channel tag (You / Others) is more accurate than any voice-based diarization. Don't wire FluidAudio into the mic+system path.

## Models

- **Whisper**: `openai_whisper-large-v3-v20240930_turbo` is the default (~630 MB). Available models are listed in `AppSettings.swift` and pulled from `argmaxinc/whisperkit-coreml` on Hugging Face. First transcription after a model change triggers a download. Names use an **underscore** before `turbo` (`…v3_turbo`), not a hyphen — easy to get wrong.
- **Diarization**: FluidAudio pulls its segmentation + embedding models on first use (~300 MB). Cached by FluidAudio in its own directory.
- Both caches live under `~/Library/Application Support/huggingface/` (Whisper) and FluidAudio's default model directory.

## Transcript format

Written to `~/Documents/Transcripts/recording-<stamp>.md`. Header block is parsed by `TranscriptsStore` for preview and upload state:

```
# Transcript

- Source: mic + system audio       # or "mic only", or "mic only (diarized)"
- Model: <model id>
- Detected language: sv, en        # or "auto"
- Created: <Date>
- Arc upload: none                 # placeholder for Arc integration

---

**You** [0:00] …
**Others** [0:03] …
```

The `Arc upload:` line is **placeholder** — the parser treats absence or `none` as "not uploaded", which currently means everything. When Arc upload is wired up, we'll write a real value (project id + timestamp) here. The delete-confirmation dialog uses this to warn users.

## Pending

- **Persist floating pill position** across launches (currently snaps to top-right on every start).
- **Global hotkey** for start/stop — small and high-leverage.

## Releasing

`.github/workflows/release.yml` mirrors the pattern from `srcful-nova-app`:
commit-prefix versioning, build + sign + notarize on macos-14 runners,
`softprops/action-gh-release` for the Release. See `RELEASING.md` for
the day-to-day how-to.

**Auto-update lives in `AutoUpdater.swift`.** It polls the repo's
`/releases/latest` every 6 h, compares `tag_name` to the bundle's
`CFBundleShortVersionString`, and on confirm downloads the asset zip,
writes a small bash helper (`install.sh` under a temp dir) that waits
for the current process to exit, swaps the `.app` bundles, and
relaunches. No Sparkle, no appcast.xml — matches nova's pattern. The
menu bar's "Check for updates…" item is a one-shot check; the
periodic loop still runs either way.

**Signing**: hardened runtime with `Resources/entitlements.plist`.
WhisperKit + FluidAudio need `allow-unsigned-executable-memory` and
`disable-library-validation` — both load CoreML models through
Accelerate / Metal and hardened runtime blocks those by default.
Ad-hoc signing (`build.sh`) is fine for local dev; CI signs with the
Developer ID.

## Committing

Default branch is `main`. Commits with `patch:` / `minor:` / `major:`
prefixes trigger a release build on push. Any other commit on main
runs no CI (saves minutes). Don't commit `.build/` or `build/` — `.gitignore`
handles both, but verify `git status` is clean before adding. Never
commit the HuggingFace model caches.
