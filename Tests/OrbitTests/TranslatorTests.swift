import XCTest
@testable import Orbit

final class TranslatorTests: XCTestCase {
    func testOnlyEnglishLinesGoToTheTranslator() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("On-device translation needs macOS 15") }
        XCTAssertTrue(Translator.english("Your session has expired. Please sign in again."))
        XCTAssertTrue(Translator.english("Rate limit exceeded, try again later"))
        XCTAssertFalse(Translator.english("Não foi possível buscar o uso do Claude"))
        XCTAssertFalse(Translator.english("Login do Claude não encontrado"))
    }
}
