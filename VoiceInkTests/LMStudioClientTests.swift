import XCTest
import LLMkit
@testable import VoiceInk

final class LMStudioClientTests: XCTestCase {
    func test_parseModels_extractsIds() throws {
        let json = """
        {"object":"list","data":[{"id":"gemma-4-e4b-it","object":"model"},{"id":"llama-3.2-3b-instruct","object":"model"}]}
        """.data(using: .utf8)!
        let ids = try LMStudioService.parseModels(from: json)
        XCTAssertEqual(ids, ["gemma-4-e4b-it", "llama-3.2-3b-instruct"])
    }

    func test_normalizedBaseURL_stripsChatCompletionsAndTrailingSlash() {
        XCTAssertEqual(LMStudioService.normalizedBaseURL("http://localhost:1234/v1/chat/completions"), "http://localhost:1234/v1")
        XCTAssertEqual(LMStudioService.normalizedBaseURL("http://localhost:1234/v1/"), "http://localhost:1234/v1")
        XCTAssertEqual(LMStudioService.normalizedBaseURL("http://localhost:1234/v1"), "http://localhost:1234/v1")
    }

    /// Live integration: exercises the production `.lmStudio` dispatch in
    /// `AIService.completeChat` against a running LM Studio server.
    /// Skips (does not fail) when no server is listening on the default port.
    func test_lmStudio_dispatch_cleansTranscript_againstLiveServer() async throws {
        let modelsURL = URL(string: "http://localhost:1234/v1/models")!
        guard let (data, response) = try? await URLSession.shared.data(from: modelsURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let model = try? LMStudioService.parseModels(from: data).first else {
            throw XCTSkip("LM Studio server not running on localhost:1234")
        }

        let aiService = await MainActor.run { AIService() }
        let transcript = "So um the meeting is on Tuesday, sorry not that, actually Wednesday, and uh bring three things: laptop, uh charger and um the notes"
        let systemPrompt = """
        Clean up the dictated text: remove filler words, apply spoken self-corrections, \
        fix punctuation. Do not add any information not present in the dictated text. \
        Return only the cleaned text.
        """

        let result = try await aiService.completeChat(
            provider: .lmStudio,
            modelName: model,
            messages: [ChatMessage.user(transcript)],
            systemPrompt: systemPrompt,
            timeout: 120
        )

        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(result.localizedCaseInsensitiveContains("wednesday"),
                      "self-correction not applied, got: \(result)")
        XCTAssertFalse(result.localizedCaseInsensitiveContains("so um"),
                       "fillers not removed, got: \(result)")
    }
}
