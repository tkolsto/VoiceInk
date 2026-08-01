import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import os

struct AudioRetranscriptionResult {
    let transcription: Transcription
    let enhancementFailure: String?
}

@MainActor
class AudioTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentError: TranscriptionError?

    private let modelContext: ModelContext
    private let enhancementService: AIEnhancementService?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionService")
    private let serviceRegistry: TranscriptionServiceRegistry

    enum TranscriptionError: Error {
        case noAudioFile
        case transcriptionFailed
        case modelNotLoaded
        case invalidAudioFormat
    }

    init(modelContext: ModelContext, engine: VoiceInkEngine) {
        self.modelContext = modelContext
        self.enhancementService = engine.enhancementService
        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager, modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: modelContext)
    }

    init(
        modelContext: ModelContext, serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.enhancementService = enhancementService
        self.serviceRegistry = serviceRegistry
    }

    func retranscribeAudio(from url: URL, using model: any TranscriptionModel, mode: ModeConfig? = nil) async throws
        -> AudioRetranscriptionResult
    {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }

        await MainActor.run {
            isTranscribing = true
        }

        do {
            let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
            let language = TranscriptionLanguageSupport.validLanguageOrFallback(
                mode?.selectedLanguage,
                for: model,
                realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
            )
            let requestContext = TranscriptionRequestContext(
                language: language,
                prompt: model.provider == .whisper ? UserDefaults.standard.string(forKey: "TranscriptionPrompt") : nil
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

            let audioAsset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
            let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
                0
            ]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("Recordings")

            let fileName = "retranscribed_\(UUID().uuidString).wav"
            let permanentURL = recordingsDirectory.appendingPathComponent(fileName)

            do {
                try FileManager.default.copyItem(at: url, to: permanentURL)
            } catch {
                logger.error("❌ Failed to create permanent copy of audio: \(error, privacy: .public)")
                isTranscribing = false
                throw error
            }

            let permanentURLString = permanentURL.absoluteString

            let originalText = cleanedText
            let enhancementConfiguration =
                enhancementService
                .flatMap { service in
                    service.getAIService().map { aiService in
                        ModeRuntimeResolver.currentEnhancementConfiguration(
                            mode: mode,
                            enhancementService: service,
                            aiService: aiService
                        )
                    }
                }

            // Apply AI enhancement if enabled
            if let enhancementService = enhancementService,
                let enhancementConfiguration,
                enhancementConfiguration.isEnabled,
                enhancementService.isConfigured(for: enhancementConfiguration)
            {
                do {
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                        text,
                        configuration: enhancementConfiguration
                    )
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: duration,
                        enhancedText: enhancedText,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        aiEnhancementModelName: enhancementConfiguration.modelName
                            ?? enhancementConfiguration.provider?.defaultModel,
                        promptName: promptName,
                        transcriptionDuration: transcriptionDuration,
                        enhancementDuration: enhancementDuration,
                        aiRequestSystemMessage: enhancementService.lastSystemMessageSent,
                        aiRequestUserMessage: enhancementService.lastUserMessageSent,
                        modeName: modeName,
                        modeEmoji: modeEmoji
                    )
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
                    }
                    await MainActor.run {
                        isTranscribing = false
                    }

                    return AudioRetranscriptionResult(
                        transcription: newTranscription,
                        enhancementFailure: nil
                    )
                } catch {
                    let failureDescription = EnhancementFailureFormatter.description(for: error)
                    let failureMessage = EnhancementFailureFormatter.message(description: failureDescription)
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: duration,
                        enhancedText: failureMessage,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        promptName: nil,
                        transcriptionDuration: transcriptionDuration,
                        modeName: modeName,
                        modeEmoji: modeEmoji
                    )
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
                    }

                    await MainActor.run {
                        isTranscribing = false
                    }

                    return AudioRetranscriptionResult(
                        transcription: newTranscription,
                        enhancementFailure: failureDescription
                    )
                }
            } else {
                let newTranscription = Transcription(
                    text: originalText,
                    duration: duration,
                    audioFileURL: permanentURLString,
                    transcriptionModelName: model.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration,
                    modeName: modeName,
                    modeEmoji: modeEmoji
                )
                modelContext.insert(newTranscription)
                do {
                    try modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                } catch {
                    logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
                }

                await MainActor.run {
                    isTranscribing = false
                }

                return AudioRetranscriptionResult(
                    transcription: newTranscription,
                    enhancementFailure: nil
                )
            }
        } catch {
            logger.error("❌ Transcription failed: \(error, privacy: .public)")
            currentError = .transcriptionFailed
            isTranscribing = false
            throw error
        }
    }

    /// Re-runs transcription (and optional enhancement) for an existing record,
    /// mutating it in place rather than inserting a new one. `url` must be the
    /// record's already-permanent audio file — it is not copied again.
    /// Returns nil on success, or the enhancement-failure description when the transcript was saved but enhancement failed.
    @discardableResult
    func retranscribeInPlace(
        _ transcription: Transcription,
        from url: URL,
        using model: any TranscriptionModel,
        mode: ModeConfig? = nil
    ) async throws -> String? {
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
            var enhancementFailure: String? = nil

            if let enhancementService,
                let enhancementConfiguration,
                enhancementConfiguration.isEnabled,
                enhancementService.isConfigured(for: enhancementConfiguration)
            {
                do {
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                        cleanedText,
                        configuration: enhancementConfiguration
                    )
                    newEnhancedText = enhancedText
                    newAIModelName =
                        enhancementConfiguration.modelName ?? enhancementConfiguration.provider?.defaultModel
                    newPromptName = promptName
                    newEnhancementDuration = enhancementDuration
                    newSystemMessage = enhancementService.lastSystemMessageSent
                    newUserMessage = enhancementService.lastUserMessageSent
                } catch {
                    let failureDescription = EnhancementFailureFormatter.description(for: error)
                    enhancementFailure = failureDescription
                    newEnhancedText = EnhancementFailureFormatter.message(description: failureDescription)
                }
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
            return enhancementFailure
        } catch {
            logger.error("❌ In-place retranscription failed: \(error, privacy: .public)")
            currentError = .transcriptionFailed
            await MainActor.run { isTranscribing = false }
            throw error
        }
    }
}
