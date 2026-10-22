import XCTest
@testable import Orbit

final class AppUpdaterTests: XCTestCase {
    func testReleaseBuildNumbersAndDowngrades() {
        XCTAssertTrue(OrbitRelease.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertTrue(OrbitRelease.isNewer("1.1.1", than: "1.0.999"))
        XCTAssertTrue(OrbitRelease.isNewer("1.0.3", than: "1.0"))
        XCTAssertFalse(OrbitRelease.isNewer("1.0.2", than: "1.0.2"))
        XCTAssertFalse(OrbitRelease.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(OrbitRelease.isNewer("1.0.2", than: "1.0.10"))
        for invalid in ["", "1..0", "-1.0", "1.0-beta", "v1.0", "１.０", "1/0", "1.$(id)"] {
            XCTAssertNil(OrbitRelease.components(invalid), invalid)
            XCTAssertFalse(OrbitRelease.isNewer(invalid, than: "1.0"))
        }
    }

    func testReleaseEligibility() throws {
        func release(tag: String = "v1.0.3", draft: Bool = false, prerelease: Bool = false,
                     asset: String = "Orbit-1.0.dmg") -> OrbitRelease {
            OrbitRelease(tag_name: tag, draft: draft, prerelease: prerelease,
                         assets: [.init(name: asset, digest: nil)])
        }
        XCTAssertNotNil(release().update(from: "1.0.2"))
        XCTAssertNil(release(draft: true).update(from: "1.0.2"))
        XCTAssertNil(release(prerelease: true).update(from: "1.0.2"))
        XCTAssertNil(release(tag: "1.0.3").update(from: "1.0.2"))
        XCTAssertNil(release(tag: "v1.0.3-beta").update(from: "1.0.2"))
        XCTAssertNil(release(asset: "unrelated.dmg").update(from: "1.0.2"))
        XCTAssertNil(release(asset: "Orbit-../../bad.dmg").update(from: "1.0.2"))
        XCTAssertNil(release().update(from: "1.0.4"))
        let json = Data(#"{"tag_name":"v1.0.3","draft":false,"prerelease":false,"assets":[{"name":"Orbit-1.0.dmg","digest":"sha256:abc"}]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(OrbitRelease.self, from: json).diskImage?.digest, "sha256:abc")
    }

    @MainActor
    func testDailyChecksAndClockChanges() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(AppUpdater.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(AppUpdater.isDue(lastCheck: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(AppUpdater.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(AppUpdater.isDue(lastCheck: now.addingTimeInterval(-172_800), now: now))
        XCTAssertTrue(AppUpdater.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }

    func testChecksumRejectsMissingOrTamperedAssets() throws {
        let data = Data("abc".utf8)
        try UpdateTools.verifyDigest(data, expected: "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertThrowsError(try UpdateTools.verifyDigest(data, expected: nil))
        XCTAssertThrowsError(try UpdateTools.verifyDigest(Data("tampered".utf8), expected: "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    }

    func testCommandFailureAndTimeout() throws {
        XCTAssertEqual(try UpdateTools.run("/usr/bin/printf", ["ok"]), Data("ok".utf8))
        XCTAssertThrowsError(try UpdateTools.run("/usr/bin/false", []))
        let start = Date()
        XCTAssertThrowsError(try UpdateTools.run("/bin/sleep", ["30"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
