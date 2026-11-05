import XCTest
@testable import Orbit

/// A source whose fetch waits until the test releases it.
private actor FakeSource: UsageSource {
    let provider = Provider.claude
    private var results: [ProviderUsage]
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var held: Bool
    private(set) var fetches = 0

    init(_ results: [ProviderUsage], held: Bool = false) {
        self.results = results
        self.held = held
    }

    func fetch() async -> ProviderUsage {
        fetches += 1
        if held { await withCheckedContinuation { waiting.append($0) } }
        return results.count > 1 ? results.removeFirst() : results[0]
    }

    func release() {
        held = false
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func started() async {
        while fetches == 0 { await Task.yield() }
    }
}

@MainActor
final class AccountRefresherTests: XCTestCase {
    private let work = Account(id: UUID(), provider: .claude, name: "Work", folder: "/work")
    private let other = Account(id: UUID(), provider: .claude, name: "Other", folder: "/other")
    private let good = ProviderUsage(provider: .claude, session: UsageWindow(usedPercent: 10), updatedAt: Date(timeIntervalSince1970: 100))

    private func model(_ accounts: [Account]) -> GalaxyModel {
        let model = GalaxyModel()
        model.accounts = accounts // assigned directly, so nothing is saved
        return model
    }

    private func refresh(_ refresher: AccountRefresher) async {
        await withCheckedContinuation { done in refresher.refresh { done.resume() } }
    }

    func testSourcesSurviveAddAndRemove() {
        let model = model([work])
        var made: [UUID] = []
        let instances = [work.id: FakeSource([good]), other.id: FakeSource([good])]
        let refresher = AccountRefresher(model: model) { made.append($0.id); return instances[$0.id]! }
        let first = refresher.sources[work.id] as? FakeSource
        model.accounts.append(other)
        refresher.sync()
        XCTAssertEqual(made, [work.id, other.id], "only the new account gets a source")
        XCTAssertTrue(refresher.sources[work.id] as? FakeSource === first, "backoff and last-good state live in this instance")
        model.accounts.removeAll { $0.id == other.id }
        refresher.sync()
        XCTAssertNil(refresher.sources[other.id])
        XCTAssertTrue(refresher.sources[work.id] as? FakeSource === first)
    }

    func testResultForAccountRemovedDuringFetchIsDropped() async {
        let model = model([work, other])
        let held = FakeSource([good], held: true)
        let refresher = AccountRefresher(model: model) { $0.id == self.work.id ? held : FakeSource([self.good]) }
        let finished = expectation(description: "pass ended")
        refresher.refresh { finished.fulfill() }
        await held.started()
        model.accounts.removeAll { $0.id == work.id }
        await held.release()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNil(model.usage[work.id])
        XCTAssertNotNil(model.usage[other.id])
        XCTAssertFalse(model.refreshing)
    }

    func testRequestDuringAPassRunsOneMoreWithTheNewAccount() async {
        let model = model([work])
        let held = FakeSource([good], held: true)
        let added = FakeSource([good])
        let refresher = AccountRefresher(model: model) { $0.id == self.work.id ? held : added }
        var passes = 0
        let both = expectation(description: "two passes")
        both.expectedFulfillmentCount = 2
        let finished = { passes += 1; both.fulfill() }
        refresher.refresh(finished: finished)
        await held.started()
        model.accounts.append(other)
        refresher.sync()
        refresher.refresh(finished: finished)
        refresher.refresh(finished: finished) // coalesced with the one above
        await held.release()
        await fulfillment(of: [both], timeout: 5)
        XCTAssertEqual(passes, 2)
        XCTAssertNotNil(model.usage[other.id])
        let counts = await (held.fetches, added.fetches)
        XCTAssertEqual(counts.0, 2)
        XCTAssertEqual(counts.1, 1)
    }

    func testOneSlowAccountDoesNotHoldBackTheOthers() async {
        let model = model([work, other])
        let held = FakeSource([good], held: true)
        let refresher = AccountRefresher(model: model) { $0.id == self.work.id ? held : FakeSource([self.good]) }
        let finished = expectation(description: "pass ended")
        refresher.refresh { finished.fulfill() }
        await held.started()
        while model.usage[other.id] == nil { await Task.yield() }
        XCTAssertNil(model.usage[work.id])
        XCTAssertTrue(model.refreshing)
        await held.release()
        await fulfillment(of: [finished], timeout: 5)
    }

    /// The panel refits from this callback, so it has to run while a slow account still holds the pass open.
    func testEachResultSignalsWithTheResultAlreadyInTheModel() async {
        let model = model([work, other])
        let held = FakeSource([good], held: true)
        let refresher = AccountRefresher(model: model) { $0.id == self.work.id ? held : FakeSource([self.good]) }
        var seen: [Int] = []
        refresher.resultApplied = { seen.append(model.usage.count) }
        let finished = expectation(description: "pass ended")
        refresher.refresh { finished.fulfill() }
        await held.started()
        // Bounded, so a missing callback fails instead of hanging the suite.
        let deadline = Date(timeIntervalSinceNow: 5)
        while seen.isEmpty, Date() < deadline { await Task.yield() }
        XCTAssertEqual(seen, [1])
        XCTAssertTrue(model.refreshing)
        await held.release()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(seen, [1, 2])
    }

    func testLastGoodQuotaIsKeptPerAccountUntilSignInIsNeeded() async {
        var failure = ProviderUsage(provider: .claude)
        failure.error = "HTTP 500"
        var signedOut = ProviderUsage(provider: .claude)
        signedOut.error = "login"
        signedOut.needsConnection = true
        let model = model([work])
        let refresher = AccountRefresher(model: model) { _ in FakeSource([self.good, failure, signedOut]) }
        await refresh(refresher)
        XCTAssertEqual(model.usage[work.id]?.session?.usedPercent, 10)
        await refresh(refresher)
        XCTAssertEqual(model.usage[work.id]?.error, "HTTP 500")
        XCTAssertEqual(model.usage[work.id]?.session?.usedPercent, 10)
        XCTAssertEqual(model.usage[work.id]?.updatedAt, good.updatedAt)
        await refresh(refresher)
        XCTAssertNil(model.usage[work.id]?.session)
        XCTAssertTrue(model.usage[work.id]?.needsConnection == true)
    }
}
