import XCTest
@testable import Orbit

final class PanelScaleTests: XCTestCase {
    func testStoredValuesAndSteps() {
        // Raw values are the saved "panelSize" preference from before S/M/L/XL.
        XCTAssertEqual(PanelScale(rawValue: "normal"), .normal)
        XCTAssertEqual(PanelScale(rawValue: "largest")?.title, "XL")
        XCTAssertEqual(PanelScale.small.stepped(-1), .small)
        XCTAssertEqual(PanelScale.normal.stepped(1), .larger)
        XCTAssertEqual(PanelScale.largest.stepped(1), .largest)
    }

    func testPortugueseKeepsPlaceholders() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Localization/pt-BR.lproj/Localizable.strings")
        let strings = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        XCTAssertFalse(strings.isEmpty)
        let placeholder = try NSRegularExpression(pattern: "%(\\d\\$)?@")
        func count(_ s: String) -> Int { placeholder.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) }
        for (key, value) in strings { XCTAssertEqual(count(key), count(value), key) }
    }
}
