import SwiftData
import XCTest
@testable import VoiceInk

final class WordReplacementServiceTests: XCTestCase {
    func testApplyReplacementsDoesNotMatchInsideUnicodeWords() throws {
        let context = try makeContext()
        context.insert(WordReplacement(originalText: "ern", replacementText: "EAN"))

        let result = WordReplacementService.shared.applyReplacements(
            to: "Bitte vergrößern.",
            using: context
        )

        XCTAssertEqual(result, "Bitte vergrößern.")
    }

    func testApplyReplacementsStillMatchesAtPunctuationBoundaries() throws {
        let context = try makeContext()
        context.insert(WordReplacement(originalText: "c++", replacementText: "C Plus Plus"))

        let result = WordReplacementService.shared.applyReplacements(
            to: "Use c++.",
            using: context
        )

        XCTAssertEqual(result, "Use C Plus Plus.")
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WordReplacement.self, configurations: configuration)
        return ModelContext(container)
    }
}
