import XCTest
import ClaudeIntegrationCore
@testable import CodexLimits

@MainActor
final class GrokIntegrationTests: XCTestCase {
    func testOmittedZeroAfterResetSurvivesRelaunchAndTracksSubsequentUsage() async throws {
        let clock = GrokTestClock()
        let first = fixture(at: clock.now())
        let source = GrokFetchProbe(snapshot: first)
        let cache = temporaryDirectory().appendingPathComponent("snapshot.json")
        let store = makeStore(clock: clock, source: source, cache: cache)
        await store.setVisible(true)
        let originalHistory = store.history
        clock.advance(3_601)
        let formatter = ISO8601DateFormatter()
        let reset = clock.now().addingTimeInterval(7 * 86_400)
        let reply = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
        "start":"\(formatter.string(from: clock.now()))","end":"\(formatter.string(from: reset))"},\
        "prepaidBalance":{}},"subscription_tier":"Example plan"}
        """
        let zero = try GrokAllowanceSnapshot.decode(Data(reply.utf8), observedAt: clock.now(), sourceVersion: "1.2.3")
        await source.setSnapshot(zero)
        await store.refresh()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.currentSnapshot?.resetsAt, reset)
        XCTAssertEqual(store.snapshot?.observedAt, clock.now())
        XCTAssertEqual(store.snapshot?.subscriptionTier, "Example plan")
        XCTAssertEqual(store.menuBarText, "100%")
        let zeroHistory = originalHistory + [try XCTUnwrap(zero.historyObservation)]
        XCTAssertEqual(store.history, zeroHistory)
        let chart = try XCTUnwrap(IntegrationAllowanceChart(
            metric: zero.historyMetric, observations: store.history, current: zero.historyObservation,
            now: clock.now(), isStale: store.isStale, safetyBuffer: 3
        ))
        XCTAssertTrue(chart.chart.currentProjection.isEmpty, "An estimate cannot cross the reset")
        await store.setVisible(true, includeHistory: false)
        XCTAssertEqual(store.overview?.latest?.remaining, 100)
        await store.setEnabled(false)

        let restored = makeStore(clock: clock, source: source, cache: cache)
        await restored.setVisible(true)
        XCTAssertEqual(restored.snapshot, zero)
        XCTAssertEqual(restored.history, zeroHistory)
        XCTAssertEqual(restored.currentSnapshot?.remainingPercent, 100)

        clock.advance(600)
        let usedReply = reply.replacingOccurrences(of: #""config":{"#, with: #""config":{"creditUsagePercent":1,"#)
        let used = try GrokAllowanceSnapshot.decode(Data(usedReply.utf8), observedAt: clock.now(), sourceVersion: "1.2.3")
        await source.setSnapshot(used)
        await restored.refresh()
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.menuBarText, "99%")
        XCTAssertEqual(restored.history, zeroHistory + [try XCTUnwrap(used.historyObservation)])
        await restored.deleteData()
    }

    func testFreshCacheWithoutPercentageFetchesBeforeShowingCurrentUsage() async throws {
        let clock = GrokTestClock()
        let current = fixture(at: clock.now())
        let source = GrokFetchProbe(snapshot: current)
        let cache = temporaryDirectory().appendingPathComponent("snapshot.json")
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        saved.removeValue(forKey: "reportedUsedPercent")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: saved).write(to: cache)
        let store = makeStore(clock: clock, source: source, cache: cache)
        await store.setVisible(true)
        let calls = await source.calls
        XCTAssertEqual(calls, 1, "A partial 0.3.1 cache must not delay a current measurement")
        XCTAssertEqual(store.menuBarText, "75%")
        XCTAssertEqual(store.history, [try XCTUnwrap(current.historyObservation)])
        await store.deleteData()
    }

    func testOverviewReadsCurrentPeriodWithoutRetainingDetailAndFallsBackToLatest() async throws {
        let clock = GrokTestClock()
        let current = fixture(at: clock.now())
        let currentObservation = try XCTUnwrap(current.historyObservation)
        let source = GrokFetchProbe(snapshot: current)
        let cache = temporaryDirectory().appendingPathComponent("snapshot.json")
        let historyDirectory = cache.deletingLastPathComponent().appendingPathComponent("History")
        let previous = AllowanceObservation(
            metric: currentObservation.metric, observedAt: current.observedAt.addingTimeInterval(-600),
            remainingPercent: 80, resetsAt: current.resetsAt,
            startsAt: currentObservation.startsAt, source: current.measurementSource
        )
        let old = try XCTUnwrap(fixture(at: clock.now().addingTimeInterval(-20 * 86_400)).historyObservation)
        try AllowanceHistory.append([old, previous], in: historyDirectory)
        try JSONEncoder().encode(current).write(to: cache)
        let files = try FileManager.default.contentsOfDirectory(at: historyDirectory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let oldest = try XCTUnwrap(files.first)
        try Data("invalid old archive\n".utf8).write(to: oldest)
        let store = makeStore(clock: clock, source: source, cache: cache)
        await store.refresh(force: false)
        XCTAssertNil(store.overview)
        XCTAssertNil(store.historyIssue)

        await store.setVisible(true, includeHistory: false, safetyBuffer: 5)

        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.overview?.observedSegments.flatMap { $0 }.count, 2)
        XCTAssertEqual(store.overview?.latest?.remaining, 75)
        XCTAssertEqual(store.overview?.target.last?.remaining, 5)
        XCTAssertNil(store.historyIssue)
        var calls = await source.calls
        XCTAssertEqual(calls, 0, "Overview demand must reuse a fresh cache")
        await store.setVisible(true)
        XCTAssertNil(store.overview)
        XCTAssertNotNil(store.historyIssue)
        await store.setVisible(false)
        XCTAssertNil(store.overview)
        let newest = try XCTUnwrap(files.last)
        try Data("invalid current archive\n".utf8).write(to: newest)
        await store.setVisible(true, includeHistory: false)
        XCTAssertEqual(store.overview?.observedSegments.flatMap { $0 }.count, 1)
        XCTAssertEqual(store.overview?.latest?.remaining, 75)
        XCTAssertNotNil(store.historyIssue)
        calls = await source.calls
        XCTAssertEqual(calls, 0)
        await store.setEnabled(false)
        XCTAssertNil(store.overview)
        await store.deleteData()
        XCTAssertNil(store.overview)
    }

    func testSwitchingToOverviewDuringSharedFetchPublishesOnlyCompactHistory() async throws {
        let clock = GrokTestClock()
        let source = GrokFetchProbe(snapshot: fixture(at: clock.now()), held: true)
        let store = makeStore(clock: clock, source: source)
        let detail = Task { await store.setVisible(true) }
        await waitForCall(source)
        let overview = Task { await store.setVisible(true, includeHistory: false) }
        await Task.yield()
        await source.release()
        await detail.value
        await overview.value
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.overview?.observedSegments.flatMap { $0 }.count, 1)
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
        await store.deleteData()
        XCTAssertNil(store.overview)
    }

    func testRecordedHistoryMigratesLatestCacheAndSurvivesRelaunchUntilDeletion() async throws {
        let clock = GrokTestClock()
        let first = fixture(at: clock.now())
        let source = GrokFetchProbe(snapshot: first)
        let cache = temporaryDirectory().appendingPathComponent("snapshot.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(first).write(to: cache)
        let store = makeStore(clock: clock, source: source, cache: cache)
        await store.setVisible(true)
        XCTAssertEqual(store.history, [try XCTUnwrap(first.historyObservation)], "Migrate one real cached observation only")
        clock.advance(600)
        let second = fixture(at: clock.now())
        await source.setSnapshot(second)
        await store.refresh()
        XCTAssertEqual(store.history, [first, second].compactMap(\.historyObservation))
        await store.setEnabled(false)
        let restored = makeStore(clock: clock, source: source, cache: cache)
        await restored.setVisible(true)
        XCTAssertEqual(restored.history, [first, second].compactMap(\.historyObservation))
        await restored.setVisible(false)
        XCTAssertTrue(restored.history.isEmpty, "Hidden detail releases resident history")
        await restored.setVisible(true)
        XCTAssertEqual(restored.history.count, 2)
        await restored.deleteData()
        XCTAssertTrue(restored.history.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.deletingLastPathComponent().appendingPathComponent("History").path))
    }

    func testOnlyEnabledDemandFetchesAndTheCacheSurvivesRelaunch() async throws {
        let clock = GrokTestClock()
        let source = GrokFetchProbe(snapshot: fixture(at: clock.now()))
        let cache = temporaryDirectory().appendingPathComponent("snapshot.json")
        let store = makeStore(enabled: false, clock: clock, source: source, cache: cache)
        await store.settingsPresented()
        await store.refresh()
        await store.setVisible(true)
        var calls = await source.calls
        XCTAssertEqual(calls, 0)

        await store.setEnabled(true)
        XCTAssertEqual(store.menuBarText, "75%")
        calls = await source.calls
        XCTAssertEqual(calls, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        await store.setVisible(false)
        await store.setEnabled(false)

        let restored = makeStore(enabled: true, clock: clock, source: source, cache: cache)
        await restored.settingsPresented()
        XCTAssertNil(restored.snapshot)
        await restored.setVisible(true)
        XCTAssertEqual(restored.snapshot, store.snapshot)
        calls = await source.calls
        XCTAssertEqual(calls, 1, "Opening a fresh cache must not start a provider process")
        await restored.setVisible(false)
        clock.advance(700)
        await restored.refresh(force: false, priority: .visible)
        calls = await source.calls
        XCTAssertEqual(calls, 1, "Hidden and unselected Grok has no source demand")
        await restored.deleteData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertNil(restored.snapshot)
        XCTAssertFalse(restored.hasStoredData)
    }

    func testThrottledFailuresKeepUsageUntilResetAndBackOff() async throws {
        let clock = GrokTestClock()
        let source = GrokFetchProbe(snapshot: fixture(at: clock.now()))
        let store = makeStore(clock: clock, source: source)
        await store.refresh()
        clock.advance(31)
        await source.fail(with: .failed)
        await store.refresh()
        XCTAssertEqual(store.menuBarText, "75%")
        XCTAssertTrue(store.isStale)
        await store.refresh()
        var calls = await source.calls
        XCTAssertEqual(calls, 2, "Explicit refresh must honor the 30-second floor")
        clock.advance(600)
        await store.refresh(force: false)
        calls = await source.calls
        XCTAssertEqual(calls, 3)
        clock.advance(600)
        await store.refresh(force: false)
        calls = await source.calls
        XCTAssertEqual(calls, 3, "A second failure backs off for 20 minutes")
        clock.advance(3_000)
        store.updateDisplayTime()
        XCTAssertEqual(store.menuBarText, "—")
        XCTAssertNotNil(store.snapshot)
        XCTAssertNil(store.currentSnapshot)
        XCTAssertFalse(store.isStale, "Reset expiration takes precedence over stale usage")
    }

    func testWallClockChangesCannotBypassTheLaunchFloor() async {
        let clock = GrokTestClock()
        let source = GrokFetchProbe(snapshot: fixture(at: clock.now()))
        let store = makeStore(clock: clock, source: source)
        await store.refresh()
        clock.advance(3_600, uptime: 0)
        await store.refresh()
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.menuBarText, "—")
    }

    func testDeletionWaitsForLateWorkAndSupersedesExecutableSelection() async throws {
        let clock = GrokTestClock()
        let source = GrokFetchProbe(snapshot: fixture(at: clock.now()), held: true)
        let cache = temporaryDirectory().appendingPathComponent("snapshot.json")
        let store = makeStore(clock: clock, source: source, cache: cache)
        let selection = Task { await store.selectExecutable(URL(fileURLWithPath: "/usr/bin/true")) }
        await waitForCall(source)
        let deletion = Task { await store.deleteData() }
        while store.isRefreshing { await Task.yield() }
        await source.release()
        let selected = await selection.value
        await deletion.value
        XCTAssertFalse(selected, "Settings must not restore an executable after deletion")
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        await store.refresh()
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
    }

    func testExplicitRefreshPromotesQueuedFreshCacheWork() async throws {
        let clock = GrokTestClock()
        let source = GrokFetchProbe(snapshot: fixture(at: clock.now()))
        let coordinator = IntegrationWorkCoordinator()
        let gate = GrokFetchProbe(snapshot: fixture(at: clock.now()), held: true)
        let blocker = Task {
            await coordinator.run(priority: .explicit) { _ = try? await gate.fetch() }
        }
        await waitForCall(gate)
        let cache = temporaryDirectory().appendingPathComponent("snapshot.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(fixture(at: clock.now())).write(to: cache)
        let store = makeStore(clock: clock, source: source, cache: cache, coordinator: coordinator)
        let visible = Task { await store.setVisible(true) }
        await Task.yield()
        let explicit = Task { await store.refresh() }
        await Task.yield()
        await gate.release()
        await blocker.value
        await visible.value
        await explicit.value
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
        await store.setVisible(false)
    }

    func testDismissedSettingsDoesNotPublishQueuedReadiness() async throws {
        let clock = GrokTestClock()
        let source = GrokFetchProbe(snapshot: fixture(at: clock.now()))
        let coordinator = IntegrationWorkCoordinator()
        let gate = GrokFetchProbe(snapshot: fixture(at: clock.now()), held: true)
        let blocker = Task {
            await coordinator.run(priority: .explicit) { _ = try? await gate.fetch() }
        }
        await waitForCall(gate)
        let cache = temporaryDirectory().appendingPathComponent("snapshot.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(fixture(at: clock.now())).write(to: cache)
        let store = makeStore(clock: clock, source: source, cache: cache, coordinator: coordinator)
        let settings = Task { await store.settingsPresented() }
        await Task.yield()
        store.settingsDismissed()
        await gate.release()
        await blocker.value
        await settings.value
        XCTAssertFalse(store.hasStoredData)
        let calls = await source.calls
        XCTAssertEqual(calls, 0)
    }

    private func makeStore(
        enabled: Bool = true, clock: GrokTestClock, source: GrokFetchProbe,
        cache: URL? = nil, coordinator: IntegrationWorkCoordinator = IntegrationWorkCoordinator()
    ) -> GrokIntegrationStore {
        GrokIntegrationStore(
            isEnabled: enabled,
            selectedExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            cacheURL: cache ?? temporaryDirectory().appendingPathComponent("snapshot.json"),
            integrationWorkCoordinator: coordinator,
            fetchUsage: { _ in try await source.fetch() },
            now: { clock.now() }, uptime: { clock.uptime() }
        )
    }

    private func fixture(at now: Date) -> GrokAllowanceSnapshot {
        GrokAllowanceSnapshot(
            reportedUsedPercent: 25, period: .weekly,
            resetsAt: now.addingTimeInterval(3_600), observedAt: now,
            sourceVersion: "1.2.3", subscriptionTier: nil,
            prepaidBalanceUSD: nil, onDemandUsedUSD: nil, onDemandCapUSD: nil,
            isUnifiedBilling: true, measurementSource: "creditUsagePercent"
        )
    }

    private func waitForCall(_ source: GrokFetchProbe) async {
        for _ in 0..<1_000 {
            if await source.calls > 0 { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Source work did not start")
    }
}

private final class GrokTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var elapsed: TimeInterval = 0
    func now() -> Date { lock.withLock { date } }
    func uptime() -> TimeInterval { lock.withLock { elapsed } }
    func advance(_ seconds: TimeInterval, uptime: TimeInterval? = nil) {
        lock.withLock {
            date.addTimeInterval(seconds)
            elapsed += uptime ?? seconds
        }
    }
}

private actor GrokFetchProbe {
    private var snapshot: GrokAllowanceSnapshot
    private var error: GrokBillingError?
    private var held: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(snapshot: GrokAllowanceSnapshot, held: Bool = false) {
        self.snapshot = snapshot
        self.held = held
    }
    func fail(with error: GrokBillingError) { self.error = error }
    func setSnapshot(_ snapshot: GrokAllowanceSnapshot) { self.snapshot = snapshot }
    func fetch() async throws -> GrokAllowanceSnapshot {
        calls += 1
        if held { await withCheckedContinuation { continuation = $0 } }
        if let error { throw error }
        return snapshot
    }
    func release() {
        held = false
        continuation?.resume()
        continuation = nil
    }
}
