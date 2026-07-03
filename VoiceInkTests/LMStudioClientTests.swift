import XCTest
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
}
