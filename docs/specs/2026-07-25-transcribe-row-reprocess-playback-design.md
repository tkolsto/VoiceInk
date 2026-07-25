# Reprocess & Play Clips from the Transcribe Queue Row

**Date:** 2026-07-25
**Status:** Approved design, pending implementation plan

## Problem

The primary workflow is recording ~1-minute audio snippets for near-realtime
Thai→English translation. Getting a usable translation is iterative: the first
mode often produces a poor result, so the user retries with a different mode.

Today, retrying a file from the **Transcribe Audio** view is a three-step chore:
change the active mode in the top bar, then re-add the same file to the queue,
then reprocess. Queue rows (`AudioFileRow`) also offer no way to play back the
clip. Both capabilities exist in the **History** audio player but not on the
queue rows where the record→transcribe loop actually happens.

## Goal

Bring playback and mode-based reprocessing directly onto the completed queue
row, so the user can, without leaving the row:

1. Play and scrub the clip (waveform, like History).
2. **Reprocess with a chosen mode** — full whisper re-run (fixes bad transcription).
3. **Re-translate with a chosen prompt** — AI-only re-run reusing the whisper
   text (fixes bad translation; already exists in the History player).

Both reprocess actions **replace the result in place** — no accumulation of
throwaway transcription records.

## Key context (current code)

- `Views/AudioTranscribeView.swift` — the queue view; rows rendered as
  `AudioFileRow`. Has a top-bar mode picker and Start button feeding
  `AudioTranscriptionManager.startProcessing(modelContext:engine:mode:)`.
- `Views/AudioFileRow.swift` — the row. `@ObservedObject var item:
  AudioFileQueueItem`. Expanded `completedRows` branch shows Original/Enhanced
  tabs + text ScrollView + a model/prompt metadata footer.
- `Models/AudioFileQueueItem.swift` — `@MainActor class AudioFileQueueItem`,
  `@Published var transcription: Transcription?` and `let url: URL` (the
  originally dropped file).
- `Models/Transcription.swift` — SwiftData `@Model`; `audioFileURL: String?`
  points at a permanent WAV copy in
  `Application Support/com.prakashjoshipax.VoiceInk/Recordings/`.
- `Views/AudioPlayerView.swift` — self-contained player taking `url` +
  `transcription`. Provides waveform scrubbing (`WaveformView`,
  `AudioPlayerManager`), play/speed, a **mode selector** (`ModePopover`),
  **retranscribe**, and **re-enhance**.
  - `reEnhanceOnly(prompt:)` — **mutates the existing `Transcription` in place**
    (updates `enhancedText`, `aiEnhancementModelName`, `promptName`,
    `enhancementDuration`, request messages) and saves. No whisper.
  - `retranscribeAudio()` — calls
    `AudioTranscriptionService.retranscribeAudio(from:using:mode:)`, which
    **inserts a NEW `Transcription`** (History-append behavior).
- `Services/AudioFileTranscriptionService.swift` —
  `AudioTranscriptionService.retranscribeAudio(from:using:mode:)`: re-runs
  whisper on the file, copies audio to `retranscribed_<uuid>.wav`, applies
  enhancement per mode, inserts a new record.
- `Modes/ModeRuntimeConfiguration.swift` — `ModeRuntimeResolver` is where the
  pipeline reads a `ModeConfig` (transcription model/language, enhancement
  prompt/provider/model).

**Load-bearing fact:** the `Transcription` object held by a queue item
(`item.transcription`) is the *same* object inserted into SwiftData and shown in
History. Mutating it in place updates both surfaces with no extra wiring.

## Design

### 1. Behavior

When a queue item is `.completed` and expanded, the row embeds the History-style
audio player below the result text: scrubable waveform, play/pause, speed, a
mode selector, a reprocess button (full whisper), and a re-translate button
(AI-only, pick a prompt). Both reprocess actions replace the result in place by
mutating the row's `Transcription`. History-only chrome (Show in Finder, Info)
is hidden in this context.

### 2. Backend — in-place retranscribe

Add a sibling to the existing append method in `AudioTranscriptionService`:

```swift
func retranscribeInPlace(_ transcription: Transcription,
                         from url: URL,
                         using model: TranscriptionModel,
                         mode: ModeConfig) async throws
```

It runs the same whisper + optional enhancement pipeline as
`retranscribeAudio`, but **updates the passed-in `Transcription`** instead of
inserting a new one:

- `text`, `enhancedText` (or clear it when the mode has enhancement off),
  `modeName`, `transcriptionModelName`, `promptName`, `duration`, and the
  enhancement/request-message fields.
- `modelContext.save()`.
- Reuse the existing helpers for audio decode, whisper call, text
  filtering/formatting/word-replacement, and enhancement so behavior matches
  the append path exactly.

The existing `retranscribeAudio(from:using:mode:)` append method stays
untouched so History keeps its current behavior.

Mirror the in-place mutation shape already established by
`AudioPlayerView.reEnhanceOnly` for consistency (which fields get set, save
timing, error propagation).

### 3. AudioPlayerView — a strategy flag + chrome toggles

Add parameters (all defaulted so History's call site is unchanged):

```swift
enum RetranscribeStrategy {
    case append                       // History: insert a new record
    case replace(Transcription)       // Queue: mutate this record in place
}

let retranscribeStrategy: RetranscribeStrategy   // default .append
let showsFinderButton: Bool                       // default true
let showsInfoButton: Bool                          // default true
```

- In `retranscribeAudio()`, when `.replace(target)`, call the new
  `retranscribeInPlace(target, ...)`; otherwise keep the current append call.
- Gate the Finder button and the info button on the new bools.
- `reEnhanceOnly` already mutates in place — unchanged, correct for both
  contexts.

### 4. AudioFileRow integration

In the expanded `completedRows` branch, insert the player **after the text
`ScrollView` and above the existing model/prompt metadata footer** (the footer
stays — it still reflects the current record after in-place reprocess):

```swift
if let t = item.transcription, let audioURL = resolvedAudioURL(for: t) {
    AudioPlayerView(
        url: audioURL,
        transcription: t,
        retranscribeStrategy: .replace(t),
        showsFinderButton: false,
        showsInfoButton: false
    )
}
```

- `resolvedAudioURL(for:)` resolves `t.audioFileURL` via `URL(string:)` and
  checks `FileManager.default.fileExists`, returning `nil` when absent. This is
  the same permanent-copy source History uses (not `item.url`, which may have
  been moved/deleted).
- Because reprocess mutates `t` in place and
  `AudioFileQueueItem.transcription` is `@Published` on the same object, the
  row's text/tabs refresh automatically.
- `AudioPlayerView` needs the `VoiceInkEngine` and `AIEnhancementService`
  environment objects and `\.modelContext`; confirm the Transcribe view's
  environment provides them (History does). Add them at the queue view level if
  missing.

### 5. Upstream merge (separate first step)

Fold in the 3 outstanding upstream commits, isolated from the feature so it can
be verified independently:

- `bb1b294` — Dia browser support for URL-based mode triggers.
- `56ebd94` — restore prior license-storage behavior in `LicenseManager.swift`.
- `50f75d2` — merge commit for the Dia work.

No file overlap with the fork's local commits; `git merge upstream/main`
fast-forwards cleanly. Low risk.

## Edge cases

- **Missing audio file** (source deleted, or legacy record with no
  `audioFileURL`): `resolvedAudioURL` returns `nil`, player is not rendered, row
  behaves exactly as today.
- **No mode selected** on reprocess: reuse `AudioPlayerView`'s existing
  "No mode selected" error path.
- **Mode with enhancement disabled**: in-place retranscribe must clear/refresh
  `enhancedText` so a stale translation from a previous mode doesn't linger.
- **In-flight reprocess**: reuse `isOperationInProgress` to disable the action
  buttons and prevent double-firing.
- **Enhancement not configured** on re-translate: reuse the existing
  "AI Enhancement is not enabled or configured" error path.

## Non-goals / scope guard

- No changes to the live-recording pipeline (`TranscriptionPipeline`).
- No new History UI beyond the two defaulted visibility flags.
- No "keep every attempt" / comparison UI — replace-in-place only.
- No unit tests for the whisper/enhancement pipeline (untested in this repo);
  verification is behavioral.

## Verification

Behavioral, via the `/verify` flow:

1. Merge upstream, build, confirm app launches and Dia/license changes are inert
   for normal use.
2. Drop a ~1-min clip in Transcribe Audio, transcribe with mode A, expand the
   row.
3. Scrub the waveform, play/pause, change speed.
4. Reprocess with mode B → confirm the row's Original/Enhanced text updates in
   place and the matching History entry reflects the same change (no new
   record).
5. Re-translate with a different prompt → confirm enhanced text updates in
   place, whisper text unchanged.
6. Delete the underlying audio file, reopen → confirm the row renders without a
   player and stays functional.
