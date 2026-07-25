# Transcribe Queue Row: Reprocess & Playback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user play/scrub a clip and reprocess it with a different mode (full whisper) or re-translate it with a different prompt (AI-only) directly from a completed row in the Transcribe Audio view, replacing the result in place.

**Architecture:** Reuse the existing History `AudioPlayerView` by embedding it in the expanded completed row. Add a `RetranscribeStrategy` parameter so full retranscribe can mutate the row's existing `Transcription` in place (via a new `AudioTranscriptionService.retranscribeInPlace`) instead of inserting a new record. Re-translate already mutates in place and needs no backend change. Two defaulted visibility flags hide History-only chrome (Finder/Info) in the row.

**Tech Stack:** Swift, SwiftUI, SwiftData, AVFoundation, Xcode project `VoiceInk.xcodeproj` (scheme `VoiceInk`, macOS app).

## Global Constraints

- Language/UI: Swift + SwiftUI, macOS only. No changes to the live-recording pipeline (`Transcription/Engine/TranscriptionPipeline.swift`).
- In-place reprocess must mutate the **same** `Transcription` object the queue item holds (`item.transcription`), which is the same object in History — never insert a new record from the queue row.
- The audio source for the row's player and reprocess is the permanent copy at `transcription.audioFileURL` (a `Recordings/*.wav`), **not** `item.url` (the original dropped file, which may be gone).
- The existing `AudioPlayerView` History call sites and `AudioTranscriptionService.retranscribeAudio(from:using:mode:)` append behavior must remain unchanged (new params are all defaulted).
- No unit-test harness exists for the whisper/enhancement pipeline; per-task verification is a successful build, and the feature is verified behaviorally in the running app (final task).
- Persistent recordings dir: `applicationSupportDirectory/com.prakashjoshipax.VoiceInk/Recordings/`.
- Commit after each task. No AI attribution in commit messages.

**Build/verify command** (used as each task's "test cycle"). This repo requires
local ad-hoc signing via `LocalBuild.xcconfig` — a plain `xcodebuild ... build`
fails with a provisioning-profile error. Use the incremental local build (reuses
`.local-build`, do NOT wipe it):
```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  build 2>&1 | tail -6
```
Expected on success: `** BUILD SUCCEEDED **`. (`make local` does the same but wipes
`.local-build` first for a full rebuild — slower. Requires the prebuilt
`whisper.xcframework` at `~/VoiceInk-Dependencies/…`, already present.)

---

### Task 0: Merge outstanding upstream commits

Isolated first step so the upstream changes are verified independently of the feature.

**Files:**
- No hand edits — a git merge of `upstream/main` (touches `VoiceInk/Modes/BrowserURLService.swift`, `VoiceInk/Resources/diaURL.scpt`, `VoiceInk/Services/LicenseManager.swift`).

**Interfaces:**
- Consumes: nothing.
- Produces: nothing the later tasks depend on (isolated).

- [ ] **Step 1: Fetch and inspect the delta**

```bash
git fetch upstream
git log --oneline main..upstream/main
git diff --stat main...upstream/main
```
Expected: 3 commits (`bb1b294` Dia browser support, `56ebd94` license-storage revert, `50f75d2` merge), ~3 files changed, no overlap with fork files.

- [ ] **Step 2: Merge**

```bash
git merge upstream/main
```
Expected: clean merge (fast-forward or no-conflict merge commit).

- [ ] **Step 3: Build to confirm the tree still compiles**

Run the Build/verify command above.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit (only if the merge created a merge commit that needs a message; a clean FF needs no commit)**

If a merge commit is required:
```bash
git commit --no-edit
```

---

### Task 1: Add `retranscribeInPlace` to `AudioTranscriptionService`

Re-run whisper (+ optional enhancement) on an already-permanent audio file and update the passed-in `Transcription` in place, instead of inserting a new record. Mirrors the existing `retranscribeAudio` pipeline but reuses the existing `audioFileURL` (no new file copy) and mutates rather than inserts.

**Files:**
- Modify: `VoiceInk/Services/AudioFileTranscriptionService.swift` (add a method; existing `retranscribeAudio` untouched).

**Interfaces:**
- Consumes: `ModeRuntimeResolver.transcriptionFormattingConfiguration(mode:)`, `ModeRuntimeResolver.currentEnhancementConfiguration(mode:enhancementService:aiService:)`, `TranscriptionOutputFilter.filter`, `ParagraphFormatter.format`, `WordReplacementService.shared.applyReplacements(to:using:)`, `TranscriptionLanguageSupport.validLanguageOrFallback`, `serviceRegistry.transcribe(audioURL:model:context:)`, `enhancementService.enhance(_:configuration:)`.
- Produces: `func retranscribeInPlace(_ transcription: Transcription, from url: URL, using model: any TranscriptionModel, mode: ModeConfig?) async throws` — used by Task 2.

- [ ] **Step 1: Add the method**

Add this method inside `class AudioTranscriptionService`, directly below the existing `retranscribeAudio(...)` method (before the closing brace of the class):

```swift
    /// Re-runs transcription (and optional enhancement) for an existing record,
    /// mutating it in place rather than inserting a new one. `url` must be the
    /// record's already-permanent audio file — it is not copied again.
    func retranscribeInPlace(
        _ transcription: Transcription,
        from url: URL,
        using model: any TranscriptionModel,
        mode: ModeConfig? = nil
    ) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }

        await MainActor.run { isTranscribing = true }

        do {
            let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
            let language = TranscriptionLanguageSupport.validLanguageOrFallback(
                mode?.selectedLanguage,
                for: model,
                realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
            )
            let requestContext = TranscriptionRequestContext(
                language: language,
                prompt: model.provider == .whisper
                    ? UserDefaults.standard.string(forKey: "TranscriptionPrompt") : nil
            )
            let modeName = (mode?.isEnabled == true) ? mode?.name : nil
            let modeEmoji = (mode?.isEnabled == true) ? mode?.icon.value : nil

            let transcriptionStart = Date()
            var text = try await serviceRegistry.transcribe(audioURL: url, model: model, context: requestContext)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            text = TranscriptionOutputFilter.filter(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)
            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }
            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = text

            let enhancementConfiguration = enhancementService.flatMap { service in
                service.getAIService().map { aiService in
                    ModeRuntimeResolver.currentEnhancementConfiguration(
                        mode: mode,
                        enhancementService: service,
                        aiService: aiService
                    )
                }
            }

            var newEnhancedText: String? = nil
            var newAIModelName: String? = nil
            var newPromptName: String? = nil
            var newEnhancementDuration: TimeInterval = 0
            var newSystemMessage: String? = nil
            var newUserMessage: String? = nil

            if let enhancementService,
                let enhancementConfiguration,
                enhancementConfiguration.isEnabled,
                enhancementService.isConfigured(for: enhancementConfiguration)
            {
                let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                    cleanedText,
                    configuration: enhancementConfiguration
                )
                newEnhancedText = enhancedText
                newAIModelName = enhancementConfiguration.modelName ?? enhancementConfiguration.provider?.defaultModel
                newPromptName = promptName
                newEnhancementDuration = enhancementDuration
                newSystemMessage = enhancementService.lastSystemMessageSent
                newUserMessage = enhancementService.lastUserMessageSent
            }

            await MainActor.run {
                transcription.text = cleanedText
                transcription.enhancedText = newEnhancedText
                transcription.transcriptionModelName = model.displayName
                transcription.aiEnhancementModelName = newAIModelName
                transcription.promptName = newPromptName
                transcription.transcriptionDuration = transcriptionDuration
                transcription.enhancementDuration = newEnhancementDuration
                transcription.aiRequestSystemMessage = newSystemMessage
                transcription.aiRequestUserMessage = newUserMessage
                transcription.modeName = modeName
                transcription.modeEmoji = modeEmoji
                try? modelContext.save()
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
                isTranscribing = false
            }
        } catch {
            logger.error("❌ In-place retranscription failed: \(error, privacy: .public)")
            currentError = .transcriptionFailed
            await MainActor.run { isTranscribing = false }
            throw error
        }
    }
```

- [ ] **Step 2: Verify the `Transcription` property names compile**

Confirm the mutated properties exist and are settable on the `@Model`. Open `VoiceInk/Models/Transcription.swift` and check each of: `text`, `enhancedText`, `transcriptionModelName`, `aiEnhancementModelName`, `promptName`, `transcriptionDuration`, `enhancementDuration`, `aiRequestSystemMessage`, `aiRequestUserMessage`, `modeName`, `modeEmoji`. (These are the same fields `AudioPlayerView.reEnhanceOnly` and `retranscribeAudio` already set, so they exist and are `var`.) If any name differs, adjust the assignment to match the model.

- [ ] **Step 3: Build**

Run the Build/verify command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add VoiceInk/Services/AudioFileTranscriptionService.swift
git commit -m "feat: add in-place retranscribe to AudioTranscriptionService"
```

---

### Task 2: Add `RetranscribeStrategy` + chrome toggles to `AudioPlayerView`

Parameterize the player so the Transcribe row can request in-place replacement and hide History-only buttons, while History keeps its current append behavior via defaults.

**Files:**
- Modify: `VoiceInk/Views/AudioPlayerView.swift` (add enum + stored properties; route `retranscribeAudio()`; gate Finder/Info buttons).

**Interfaces:**
- Consumes: `AudioTranscriptionService.retranscribeInPlace(_:from:using:mode:)` (Task 1); existing `ModeRuntimeResolver.transcriptionConfiguration(mode:transcriptionModelManager:)`.
- Produces: new initializer surface on `AudioPlayerView`:
  - `RetranscribeStrategy` enum: `.append` and `.replace(Transcription)`.
  - `retranscribeStrategy: RetranscribeStrategy` (default `.append`).
  - `showsFinderButton: Bool` (default `true`), `showsInfoButton: Bool` (default `true`). Consumed by Task 3.

- [ ] **Step 1: Add the strategy enum and stored properties**

At the top of `struct AudioPlayerView` (just below `struct AudioPlayerView: View {` and the existing `let url` / `let transcription` / `var onInfoTap` lines, around `AudioPlayerView.swift:349-352`), add:

```swift
    enum RetranscribeStrategy {
        case append                 // History: insert a new Transcription record
        case replace(Transcription) // Queue: mutate this record in place
    }

    var retranscribeStrategy: RetranscribeStrategy = .append
    var showsFinderButton: Bool = true
    var showsInfoButton: Bool = true
```

(Because these have defaults, the existing History call sites `AudioPlayerView(url:transcription:onInfoTap:)` still compile unchanged.)

- [ ] **Step 2: Gate the Finder button**

In `body`, find the Finder button (`AudioPlayerView.swift:407-408`):

```swift
                    CircleIconButton(icon: "folder", action: showInFinder)
                        .help("Show in Finder")
```
Wrap it:
```swift
                    if showsFinderButton {
                        CircleIconButton(icon: "folder", action: showInFinder)
                            .help("Show in Finder")
                    }
```

- [ ] **Step 3: Gate the Info button**

In `body`, find the Info button block (`AudioPlayerView.swift:465-468`):

```swift
                    if let onInfoTap {
                        CircleIconButton(icon: "info.circle", action: onInfoTap)
                            .help("View details")
                    }
```
Change the condition to also require `showsInfoButton`:
```swift
                    if showsInfoButton, let onInfoTap {
                        CircleIconButton(icon: "info.circle", action: onInfoTap)
                            .help("View details")
                    }
```

- [ ] **Step 4: Route `retranscribeAudio()` by strategy**

Replace the body of `retranscribeAudio()` (`AudioPlayerView.swift:643-682`) — specifically the `Task { do { ... } }` block's service call — so it branches on strategy. Change the inner call from:

```swift
        Task {
            do {
                let _ = try await transcriptionService.retranscribeAudio(
                    from: url,
                    using: transcriptionConfiguration.model,
                    mode: selectedMode
                )
                await MainActor.run {
                    isRetranscribing = false
                    showSuccessFeedback(.retranscribeSuccess, title: String(localized: "Retranscription successful"))
                }
            } catch {
```
to:
```swift
        Task {
            do {
                switch retranscribeStrategy {
                case .append:
                    let _ = try await transcriptionService.retranscribeAudio(
                        from: url,
                        using: transcriptionConfiguration.model,
                        mode: selectedMode
                    )
                case .replace(let target):
                    try await transcriptionService.retranscribeInPlace(
                        target,
                        from: url,
                        using: transcriptionConfiguration.model,
                        mode: selectedMode
                    )
                }
                await MainActor.run {
                    isRetranscribing = false
                    showSuccessFeedback(.retranscribeSuccess, title: String(localized: "Retranscription successful"))
                }
            } catch {
```
(Leave the rest of the method — the `guard let selectedMode`, the `transcriptionConfiguration` guard, the `catch` block — unchanged.)

- [ ] **Step 5: Build**

Run the Build/verify command.
Expected: `** BUILD SUCCEEDED **`. History call sites still compile because all new params are defaulted.

- [ ] **Step 6: Commit**

```bash
git add VoiceInk/Views/AudioPlayerView.swift
git commit -m "feat: add retranscribe strategy and chrome toggles to AudioPlayerView"
```

---

### Task 3: Embed the player in the completed Transcribe row

Render `AudioPlayerView` in the expanded completed row, wired for in-place replacement, using the record's permanent audio file. Row text refreshes automatically because reprocess mutates the same `@Published transcription` object.

**Files:**
- Modify: `VoiceInk/Views/AudioFileRow.swift` (extend the expanded `completedRows` branch; add a URL-resolver helper).

**Interfaces:**
- Consumes: `AudioPlayerView(url:transcription:retranscribeStrategy:showsFinderButton:showsInfoButton:)` (Task 2). Environment objects `VoiceInkEngine`, `AIEnhancementService`, and `\.modelContext` are inherited from the app root injection in `VoiceInk.swift` (verified: they flow down through `AudioTranscribeView` to this row).
- Produces: nothing downstream.

- [ ] **Step 1: Add the audio-URL resolver helper**

In `struct AudioFileRow`, in the `// MARK: - Helpers` section (next to `formatDuration`, `AudioFileRow.swift:214-220`), add:

```swift
    /// The permanent audio copy for this record, if it still exists on disk.
    /// Uses `transcription.audioFileURL` (the Recordings/*.wav copy) — not
    /// `item.url`, which may point at a moved/deleted original.
    private func resolvedAudioURL(for transcription: Transcription) -> URL? {
        guard let urlString = transcription.audioFileURL,
              let url = URL(string: urlString),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
```

- [ ] **Step 2: Embed the player in the expanded branch**

In `completedRows`, the expanded block currently ends with the model/prompt metadata `HStack` (`AudioFileRow.swift:151-163`). Insert the player **between** the text `ScrollView` (ends line 150) and that metadata `HStack`. After:

```swift
            ScrollView {
                MarkdownContentView(
                    displayText,
                    fontSize: 14,
                    foregroundColor: AppTheme.Text.primary
                )
            }
            .frame(maxHeight: 350)
```
add:
```swift
            if let audioURL = resolvedAudioURL(for: transcription) {
                AudioPlayerView(
                    url: audioURL,
                    transcription: transcription,
                    retranscribeStrategy: .replace(transcription),
                    showsFinderButton: false,
                    showsInfoButton: false
                )
            }
```
(The existing metadata `HStack` with the `cpu`/`sparkles` labels stays directly below this.)

- [ ] **Step 3: Build**

Run the Build/verify command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add VoiceInk/Views/AudioFileRow.swift
git commit -m "feat: embed audio player with in-place reprocess in transcribe row"
```

---

### Task 4: Behavioral verification in the running app

No automated test covers the whisper/enhancement pipeline; verify the feature by driving the real app. Use the `/verify` skill if available, otherwise the manual steps below.

**Files:**
- None (verification only).

**Interfaces:**
- Consumes: the full feature (Tasks 1–3).
- Produces: nothing.

- [ ] **Step 1: Launch the app**

Build & run in Xcode (⌘R) or:
```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/VoiceInk-*/Build/Products/Debug/VoiceInk.app
```

- [ ] **Step 2: Transcribe a clip**

Go to **Transcribe Audio**, drop a ~1-minute Thai clip, pick mode A in the top bar, Start. Wait for the row to reach completed and auto-expand.

- [ ] **Step 3: Playback**

In the expanded row, confirm the waveform renders; play/pause works; drag-to-scrub seeks; the speed button cycles 1×/1.5×/2×. Confirm there is **no** Finder or Info button in the row (hidden by the flags).

- [ ] **Step 4: Reprocess with a different mode (in place)**

Click the row's mode selector, choose mode B, click the reprocess (↻) button. Confirm: the Original/Enhanced text updates in the same row (no second row appears), and opening **History** shows the **same** entry updated — no new duplicate record.

- [ ] **Step 5: Re-translate with a different prompt (AI-only, in place)**

Click the wand button, pick a different prompt. Confirm the Enhanced text updates in place while the Original (whisper) text is unchanged.

- [ ] **Step 6: Missing-audio fallback**

Quit the app. Delete the underlying `Recordings/*.wav` for a completed clip (or use an older History record lacking `audioFileURL`). Relaunch, expand that row. Confirm the player is absent and the row otherwise behaves as before (text, copy/save, tabs).

- [ ] **Step 7: History unaffected**

Open a clip in **History**, confirm its player still shows the Finder and Info buttons and its retranscribe still creates a new record (append behavior unchanged).

---

## Self-Review Notes

- **Spec coverage:** Playback/scrub → Task 3 (embeds `AudioPlayerView`). Reprocess-with-mode in place → Tasks 1+2+3. Re-translate-with-prompt in place → already in `AudioPlayerView.reEnhanceOnly`, exercised via Task 3 (verified Task 4 Step 5). Upstream merge → Task 0. Missing-audio / no-mode / enhancement-off edge cases → handled in `resolvedAudioURL` (Task 3) and the in-place method clearing `enhancedText` when enhancement is off (Task 1, `newEnhancedText` defaults to `nil`). Hidden History chrome → Task 2 flags. No new History UI → confirmed (defaults preserve History). No live-pipeline changes → confirmed.
- **Placeholder scan:** none — every code step shows full code.
- **Type consistency:** `retranscribeInPlace(_:from:using:mode:)` signature identical in Task 1 (definition) and Task 2 (call). `RetranscribeStrategy` cases `.append` / `.replace(Transcription)` consistent across Tasks 2 and 3. `resolvedAudioURL(for:)` defined and used in Task 3. Mutated `Transcription` fields match those already set by existing `retranscribeAudio` (verified against `AudioFileTranscriptionService.swift`).
