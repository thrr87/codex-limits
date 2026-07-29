import Foundation
import XCTest
@testable import CodexLimits

@MainActor
final class UsageMonitorHistoryTests: XCTestCase {
    func testDeleteAnalyticsHistoryPreservesPreferencesAndDoesNotRestoreLegacySamples() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        defaults.set(7.0, forKey: UsageMonitor.safetyBufferKey)
        defaults.set(true, forKey: LoginItem.preferenceKey)
        defaults.set(true, forKey: "resetReminderEnabled")
        defaults.set(
            try JSONEncoder().encode(StoredStateFixture(
                snapshot: UsageSnapshot(
                    mainLimit: LimitReading(
                        limitId: "codex",
                        name: "Codex",
                        window: UsageWindow(
                            remainingPercent: 80,
                            resetsAt: Date(timeIntervalSince1970: 2_000_000),
                            durationMinutes: 10_080
                        )
                    ),
                    otherLimits: [],
                    tokenHistory: [
                        TokenDay(
                            date: Date(timeIntervalSince1970: 1_800_000),
                            tokens: 1_000
                        )
                    ],
                    emergencyResetCount: 0,
                    fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                    accountFacts: AccountFacts(
                        lifetimeTokens: 1_500,
                        peakDailyTokens: nil,
                        longestRunningTurnSeconds: nil,
                        currentStreakDays: nil,
                        longestStreakDays: nil,
                        credits: nil,
                        spendControl: nil
                    )
                ),
                samples: [sample],
                previousStatus: .slowDown
            )),
            forKey: "usageState"
        )
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false
        )

        await monitor.deleteAnalyticsHistory()

        XCTAssertTrue(monitor.samples.isEmpty)
        XCTAssertEqual(monitor.historyDeletionStatus, .complete)
        XCTAssertEqual(defaults.double(forKey: UsageMonitor.safetyBufferKey), 7)
        XCTAssertTrue(defaults.bool(forKey: LoginItem.preferenceKey))
        XCTAssertTrue(defaults.bool(forKey: "resetReminderEnabled"))
        XCTAssertEqual(
            monitor.readerSnapshot.accountFacts?.lifetimeTokens,
            1_500
        )
        let storedData = try XCTUnwrap(defaults.data(forKey: "usageState"))
        let storedState = try JSONDecoder().decode(StoredStateFixture.self, from: storedData)
        XCTAssertNil(storedState.previousStatus)
        XCTAssertTrue(try XCTUnwrap(storedState.snapshot).tokenHistory.isEmpty)

        let restarted = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false
        )
        XCTAssertTrue(restarted.samples.isEmpty)
    }

    func testLocalDeletionFailureIsReportedAsPending() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let blockedParent = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParent)
        let collector = LocalActivityCollector(
            rootDirectory: root,
            stateDirectory: blockedParent.appendingPathComponent("state")
        )
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("history"),
            startsAutomatically: false,
            localActivityCollector: collector
        )

        await monitor.deleteAnalyticsHistory()

        XCTAssertEqual(monitor.historyDeletionStatus, .pendingLocal)
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(
            at: blockedParent,
            withIntermediateDirectories: true
        )

        await monitor.retryHistoryDeletion()

        XCTAssertEqual(monitor.historyDeletionStatus, .complete)
        XCTAssertNil(defaults.object(forKey: "localHistoryDeletionCutoff"))
    }

    func testLocalDeletionIntentSurvivesRestart() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let blockedParent = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParent)
        let failedCollector = LocalActivityCollector(
            rootDirectory: root,
            stateDirectory: blockedParent.appendingPathComponent("state")
        )
        let first = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("history"),
            startsAutomatically: false,
            localActivityCollector: failedCollector
        )
        await first.deleteAnalyticsHistory()

        let restartedCollector = LocalActivityCollector(
            rootDirectory: root,
            stateDirectory: blockedParent.appendingPathComponent("state")
        )
        let restarted = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("history"),
            startsAutomatically: false,
            localActivityCollector: restartedCollector
        )

        XCTAssertEqual(restarted.historyDeletionStatus, .pendingLocal)
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(
            at: blockedParent,
            withIntermediateDirectories: true
        )
        await restarted.retryHistoryDeletion()

        XCTAssertEqual(restarted.historyDeletionStatus, .complete)
        XCTAssertNil(defaults.object(forKey: "localHistoryDeletionCutoff"))
    }

    func testRefreshSelectsTheObservedAccountBeforeRecording() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let first = makeFetchResult(
            identity: "first@example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_900_000),
            remaining: 80
        )
        let second = makeFetchResult(
            identity: "second@example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_900_060),
            remaining: 70
        )
        let third = makeFetchResult(
            identity: "first@example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_900_120),
            remaining: 79
        )
        let source = FetchSequence([first, second, third])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.refresh()
        XCTAssertEqual(monitor.samples.map(\.remainingPercent), [80])
        await monitor.refresh()
        XCTAssertEqual(monitor.samples.map(\.remainingPercent), [70])
        await monitor.refresh()
        XCTAssertEqual(monitor.samples.map(\.remainingPercent), [80, 79])
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains {
            String(describing: $0).contains("@example.com")
        })
    }

    func testReturningToAnAccountStartsANewObservationEpoch() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let weeklyStart = Date(timeIntervalSince1970: 1_395_200)
        let source = FetchSequence([
            makeFetchResult(
                identity: "first@example.com",
                fetchedAt: weeklyStart,
                remaining: 100,
                lifetimeTokens: 1_000
            ),
            makeFetchResult(
                identity: "second@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_500_000),
                remaining: 90,
                lifetimeTokens: 500
            ),
            makeFetchResult(
                identity: "first@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80,
                lifetimeTokens: 1_600
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.refresh()
        await monitor.refresh()
        await monitor.refresh()

        XCTAssertEqual(monitor.samples.map(\.lifetimeTokens), [1_000, 1_600])
        XCTAssertEqual(
            monitor.readerSnapshot.accountTokenActivity.state,
            .unavailable
        )
        XCTAssertNil(monitor.readerSnapshot.accountTokenActivity.tokens)
        XCTAssertEqual(
            monitor.readerSnapshot.accountTokenActivity.reason,
            "No lifetime token reading at the weekly boundary"
        )
    }

    func testPlanChangeRecordsADurableComparisonBreak() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let source = FetchSequence([
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 90,
                planType: "pro"
            ),
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_060),
                remaining: 80,
                planType: "pro"
            ),
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_120),
                remaining: 70,
                planType: "business"
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.refresh()
        await monitor.refresh()
        await monitor.refresh()

        XCTAssertEqual(
            monitor.samples.map(\.comparisonBreak),
            [true, false, true]
        )
    }

    func testFirstKnownPlanStartsNewComparisonCohort() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let source = FetchSequence([
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 90
            ),
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_060),
                remaining: 80,
                planType: "pro"
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.refresh()
        await monitor.refresh()

        XCTAssertEqual(
            monitor.samples.map(\.comparisonBreak),
            [true, true]
        )
    }

    func testRefreshDoesNotRecordAPreservedLifetimeFactAsANewReading() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let firstReadAt = Date(timeIntervalSince1970: 1_900_000)
        let secondReadAt = Date(timeIntervalSince1970: 1_900_060)
        let source = FetchSequence([
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: firstReadAt,
                remaining: 80,
                lifetimeTokens: 1_000,
                lifetimeTokensObservedAt: firstReadAt
            ),
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: secondReadAt,
                remaining: 79,
                lifetimeTokens: 1_000,
                lifetimeTokensObservedAt: firstReadAt
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.refresh()
        await monitor.refresh()

        XCTAssertEqual(monitor.samples.count, 2)
        XCTAssertEqual(monitor.samples[0].lifetimeTokens, 1_000)
        XCTAssertNil(monitor.samples[1].lifetimeTokens)
    }

    func testConcurrentRefreshRequestsShareOneInFlightRead() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let source = DelayedFetchSource(
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            )
        )
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        let firstRefresh = Task { await monitor.refresh() }
        while !monitor.isRefreshing {
            await Task.yield()
        }
        await monitor.refresh()
        await firstRefresh.value

        let callCount = await source.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(
            monitor.readerSnapshot.account?.mainLimit?.window.remainingPercent,
            80
        )
    }

    func testFailedRefreshRetainsTheLastReaderSnapshot() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let source = FetchSequence([
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )
        await monitor.refresh()

        await monitor.refresh()

        XCTAssertEqual(
            monitor.readerSnapshot.account?.mainLimit?.window.remainingPercent,
            80
        )
        XCTAssertEqual(monitor.readerSnapshot.freshness, .stale)
        XCTAssertEqual(
            monitor.readerSnapshot.sourceMessage,
            "Codex returned data this app could not read. Update Codex CLI and try again."
        )
    }

    func testRestartCanRestoreLocalFactsWhenAccountRefreshFails() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let localRoot = root.appendingPathComponent(
            "rollouts",
            isDirectory: true
        )
        let stateRoot = root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let historyRoot = root.appendingPathComponent(
            "history",
            isDirectory: true
        )
        let firstAt = Date(timeIntervalSince1970: 1_700_000)
        let secondAt = Date(timeIntervalSince1970: 1_800_000)
        let tokenAt = Date(timeIntervalSince1970: 1_750_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents(
            [.year, .month, .day],
            from: tokenAt
        )
        let directory = localRoot
            .appendingPathComponent(
                String(format: "%04d", parts.year!),
                isDirectory: true
            )
            .appendingPathComponent(
                String(format: "%02d", parts.month!),
                isDirectory: true
            )
            .appendingPathComponent(
                String(format: "%02d", parts.day!),
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let timestamps = [
            formatter.string(from: tokenAt.addingTimeInterval(-120)),
            formatter.string(from: tokenAt.addingTimeInterval(-60)),
            formatter.string(from: tokenAt)
        ]
        let lines = [
            #"{"timestamp":"\#(timestamps[0])","ordinal":0,"type":"session_meta","payload":{"id":"task-1","cli_version":"0.145.0"}}"#,
            #"{"timestamp":"\#(timestamps[1])","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#,
            #"{"timestamp":"\#(timestamps[2])","ordinal":2,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":500}}}}"#
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(
            to: directory.appendingPathComponent(
                "rollout-1970-01-21T00-00-00-task-1.jsonl"
            )
        )
        let source = FetchSequence([
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: firstAt,
                remaining: 90
            ),
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: secondAt,
                remaining: 80
            )
        ])
        let firstMonitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: historyRoot,
            startsAutomatically: false,
            localActivityCollector: LocalActivityCollector(
                rootDirectory: localRoot,
                stateDirectory: stateRoot
            ),
            fetchUsage: { try await source.next() }
        )
        await firstMonitor.refresh()
        await firstMonitor.refresh()
        XCTAssertEqual(
            firstMonitor.readerSnapshot.localTokenActivity.tokens,
            400
        )

        let restarted = UsageMonitor(
            defaults: defaults,
            historyDirectory: historyRoot,
            startsAutomatically: false,
            localActivityCollector: LocalActivityCollector(
                rootDirectory: localRoot,
                stateDirectory: stateRoot
            ),
            fetchUsage: { throw CodexClientError.invalidResponse }
        )
        await restarted.refresh()

        XCTAssertEqual(restarted.readerSnapshot.localTokenActivity.tokens, 400)
        XCTAssertEqual(restarted.readerSnapshot.localTokenActivity.coverage, .low)
        XCTAssertEqual(
            restarted.readerSnapshot.localTokenActivity.reason,
            "Codex account identity could not be checked"
        )
    }

    func testMissingWeeklyRefreshClearsWeeklyOutputsAndKeepsOtherLimits() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let first = makeFetchResult(
            identity: "user@example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_900_000),
            remaining: 80
        )
        let otherWindow = UsageWindow(
            remainingPercent: 40,
            resetsAt: Date(timeIntervalSince1970: 1_920_000),
            durationMinutes: 300
        )
        let missingWeekly = CodexFetchResult(
            snapshot: UsageSnapshot(
                mainLimit: nil,
                otherLimits: [
                    LimitReading(
                        limitId: "codex",
                        name: "5-hour window",
                        window: otherWindow
                    ),
                    LimitReading(
                        limitId: "model",
                        name: "Example model",
                        window: otherWindow
                    )
                ],
                tokenHistory: [],
                emergencyResetCount: 0,
                fetchedAt: Date(timeIntervalSince1970: 1_900_060)
            ),
            account: .stable(identity: "user@example.com")
        )
        let source = FetchSequence([first, missingWeekly])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.refresh()
        await monitor.refresh()

        XCTAssertNil(monitor.readerSnapshot.weeklyUsageRemaining)
        XCTAssertEqual(monitor.readerSnapshot.menuBarText, "—")
        XCTAssertNil(monitor.readerSnapshot.interval)
        XCTAssertNil(monitor.readerSnapshot.guidance)
        XCTAssertEqual(monitor.readerSnapshot.evidence.coverage, .unavailable)
        XCTAssertEqual(monitor.readerSnapshot.evidence.confidence, .unavailable)
        XCTAssertTrue(monitor.readerSnapshot.chart.target.isEmpty)
        XCTAssertTrue(monitor.readerSnapshot.chart.observed.isEmpty)
        XCTAssertEqual(
            monitor.readerSnapshot.otherLimits.map(\.name),
            ["5-hour window", "Example model"]
        )
        XCTAssertEqual(monitor.samples.count, 1)
    }

    func testRefreshShowsUsageButDoesNotRecordWhenAccountIdentityIsUnavailable() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let result = CodexFetchResult(
            snapshot: makeFetchResult(
                identity: "unused@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            ).snapshot,
            account: nil
        )
        let source = FetchSequence([result])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.refresh()

        XCTAssertEqual(
            monitor.readerSnapshot.account?.mainLimit?.window.remainingPercent,
            80
        )
        XCTAssertTrue(monitor.samples.isEmpty)
    }

    func testExplicitRebuildReadsCodexAgainInsteadOfUsingTheCachedSnapshot() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let cached = makeFetchResult(
            identity: "user@example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_900_000),
            remaining: 80
        )
        let fresh = makeFetchResult(
            identity: "user@example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_900_060),
            remaining: 70,
            lifetimeTokens: 1_500
        )
        let source = FetchSequence([cached, fresh])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )
        await monitor.refresh()
        await monitor.deleteAnalyticsHistory()

        await monitor.rebuildAvailableHistory()

        XCTAssertEqual(monitor.samples.map(\.remainingPercent), [70])
        XCTAssertEqual(monitor.samples.map(\.lifetimeTokens), [1_500])
    }

    func testObservedUnknownAuthTransitionStartsAnIsolatedPartition() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let source = FetchSequence([
            makeFetchResult(
                account: .unknown(state: "apiKey"),
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            ),
            makeFetchResult(
                account: .unknown(state: "apiKey"),
                fetchedAt: Date(timeIntervalSince1970: 1_900_060),
                remaining: 79
            ),
            makeFetchResult(
                account: .unknown(state: "signed-out"),
                fetchedAt: Date(timeIntervalSince1970: 1_900_120),
                remaining: 70
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.refresh()
        await monitor.refresh()
        XCTAssertEqual(monitor.samples.map(\.remainingPercent), [80, 79])
        await monitor.refresh()
        XCTAssertEqual(monitor.samples.map(\.remainingPercent), [70])
    }

    func testUnknownAccountCannotEnableSharedHistory() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let source = FetchSequence([
            makeFetchResult(
                account: .unknown(state: "apiKey"),
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("local", isDirectory: true),
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.connectHistoryFolder(shared)

        XCTAssertNil(monitor.syncFolderName)
        XCTAssertEqual(
            monitor.syncErrorMessage,
            "Codex account details are unavailable, so history sync is off."
        )
    }

    func testUnverifiedAccountSnapshotDoesNotUseRestoredHistoryForGuidance() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let times = Array(stride(
            from: 1_395_200.0,
            through: 1_890_000.0,
            by: 21_600.0
        )) + [1_900_000]
        let observations: [(TimeInterval, Double)] = times.enumerated().map {
            ($0.element, max(100 - Double($0.offset) * 3, 25))
        }
        let firstSource = FetchSequence(observations.map {
            makeFetchResult(
                identity: "first@example.com",
                fetchedAt: Date(timeIntervalSince1970: $0.0),
                remaining: $0.1
            )
        })
        let first = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await firstSource.next() }
        )
        for _ in observations {
            await first.refresh()
        }
        XCTAssertGreaterThan(first.readerSnapshot.chart.observed.count, 1)
        let unverifiedSnapshot = makeFetchResult(
            identity: "unused@example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_900_060),
            remaining: 20
        ).snapshot
        let unavailableAccount = FetchSequence([
            CodexFetchResult(snapshot: unverifiedSnapshot, account: nil)
        ])
        let restarted = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await unavailableAccount.next() }
        )

        await restarted.refresh()

        XCTAssertEqual(
            restarted.readerSnapshot.account?.mainLimit?.window.remainingPercent,
            20
        )
        XCTAssertEqual(restarted.readerSnapshot.chart.observed.count, 1)
        XCTAssertNil(restarted.readerSnapshot.guidance)
    }

    func testVersionedStoreWarningDoesNotMigrateFallbackSamplesToAnotherAccount() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let firstSource = FetchSequence([
            makeFetchResult(
                identity: "first@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            )
        ])
        let first = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await firstSource.next() }
        )
        await first.refresh()
        let firstSample = try XCTUnwrap(first.samples.first)
        defaults.set(
            try JSONEncoder().encode(StoredStateFixture(
                snapshot: first.readerSnapshot.account,
                samples: [firstSample],
                previousStatus: nil
            )),
            forKey: "usageState"
        )
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        let dailyFile = try XCTUnwrap(
            enumerator.compactMap { $0 as? URL }.first {
                $0.pathExtension == "json"
                    && $0.path.contains("/installations/")
            }
        )
        try Data("broken".utf8).write(
            to: dailyFile.deletingLastPathComponent()
                .appendingPathComponent("malformed.json")
        )
        let secondSource = FetchSequence([
            makeFetchResult(
                identity: "second@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_060),
                remaining: 70
            )
        ])
        let restarted = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await secondSource.next() }
        )

        await restarted.refresh()

        XCTAssertEqual(restarted.samples.map(\.remainingPercent), [70])
    }

    func testRestartWithAnotherAccountDoesNotMigrateRestoredFileSamples() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let firstSource = FetchSequence([
            makeFetchResult(
                identity: "first@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            )
        ])
        let first = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await firstSource.next() }
        )
        await first.refresh()
        XCTAssertEqual(first.samples.map(\.remainingPercent), [80])
        let secondSource = FetchSequence([
            makeFetchResult(
                identity: "second@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_060),
                remaining: 70
            )
        ])
        let restarted = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await secondSource.next() }
        )

        await restarted.refresh()

        XCTAssertEqual(restarted.samples.map(\.remainingPercent), [70])
    }

    func testRestartedSyncUsesTheSavedFolderBindingWhenCodexReadFails() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let local = root.appendingPathComponent("local", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let source = FetchSequence([
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            ),
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_060),
                remaining: 79
            )
        ])
        let first = UsageMonitor(
            defaults: defaults,
            historyDirectory: local,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )
        await first.connectHistoryFolder(shared)
        await first.refresh()

        let remoteWriter = UsageHistory(
            localDirectory: root.appendingPathComponent("remote", isDirectory: true),
            installationID: "remote"
        )
        _ = await remoteWriter.load()
        _ = await remoteWriter.connect(
            to: shared,
            accountIdentity: "user@example.com"
        )
        _ = await remoteWriter.record(UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_120),
            remainingPercent: 78,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        ))
        let unavailable = FetchSequence([])
        let restarted = UsageMonitor(
            defaults: defaults,
            historyDirectory: local,
            startsAutomatically: false,
            fetchUsage: { try await unavailable.next() }
        )

        await restarted.refresh()

        XCTAssertEqual(restarted.samples.map(\.remainingPercent), [79, 78])
    }

    func testLegacySamplesMigrateAfterTheAccountIsObserved() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let legacy = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_899_940),
            remainingPercent: 81,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        defaults.set(
            try JSONEncoder().encode(StoredStateFixture(
                snapshot: nil,
                samples: [legacy],
                previousStatus: nil
            )),
            forKey: "usageState"
        )
        let source = FetchSequence([
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.refresh()

        XCTAssertEqual(monitor.samples.map(\.remainingPercent), [81, 80])
    }

    func testUnresolvableSavedSyncTargetKeepsDeletionPending() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("unresolvable".utf8), forKey: "historySyncBookmark")
        let root = temporaryDirectory()
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root,
            startsAutomatically: false
        )

        await monitor.deleteAnalyticsHistory()

        XCTAssertEqual(monitor.historyDeletionStatus, .pendingSync)
        XCTAssertNotNil(defaults.data(forKey: "historySyncBookmark"))
    }

    func testChoosingAHistoryFolderObservesTheAccountBeforeConnecting() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let source = FetchSequence([
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("local", isDirectory: true),
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await monitor.connectHistoryFolder(shared)

        XCTAssertTrue(
            try XCTUnwrap(defaults.string(forKey: "historyAccountState"))
                .hasPrefix("stable:account-")
        )
        XCTAssertEqual(monitor.syncFolderName, "shared")
    }

    func testChoosingAFolderCompletesAnUnresolvedPendingDeletion() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("unresolvable".utf8), forKey: "historySyncBookmark")
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let source = FetchSequence([
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("local", isDirectory: true),
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )
        await monitor.deleteAnalyticsHistory()
        XCTAssertEqual(monitor.historyDeletionStatus, .pendingSync)

        await monitor.connectHistoryFolder(shared)

        XCTAssertEqual(monitor.historyDeletionStatus, .complete)
        XCTAssertEqual(monitor.syncFolderName, "shared")
        XCTAssertNil(monitor.syncErrorMessage)
    }

    func testPendingDeletionCanReconnectWhenCodexAccountReadIsUnavailable() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("unresolvable".utf8), forKey: "historySyncBookmark")
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let source = FetchSequence([])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("local", isDirectory: true),
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )
        await monitor.deleteAnalyticsHistory()

        await monitor.connectHistoryFolder(shared)

        XCTAssertEqual(monitor.historyDeletionStatus, .complete)
        XCTAssertNil(monitor.syncFolderName)
        XCTAssertEqual(
            monitor.syncErrorMessage,
            "History was deleted. Codex account details are unavailable, so history sync is off."
        )
        XCTAssertNil(defaults.data(forKey: "historySyncBookmark"))
    }

    func testRestartedPendingDeletionCanReconnectWhenAccountReadIsUnavailable() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("unresolvable".utf8), forKey: "historySyncBookmark")
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let first = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("local", isDirectory: true),
            startsAutomatically: false
        )
        await first.deleteAnalyticsHistory()
        XCTAssertEqual(first.historyDeletionStatus, .pendingSync)
        let source = FetchSequence([])
        let restarted = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("local", isDirectory: true),
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )

        await restarted.connectHistoryFolder(shared)

        XCTAssertEqual(restarted.historyDeletionStatus, .complete)
        XCTAssertNil(restarted.syncFolderName)
        XCTAssertEqual(
            restarted.syncErrorMessage,
            "History was deleted. Codex account details are unavailable, so history sync is off."
        )
    }

    func testAccountTransitionKeepsTheTargetOfAPendingDeletion() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let source = FetchSequence([
            makeFetchResult(
                identity: "first@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            ),
            makeFetchResult(
                identity: "second@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_060),
                remaining: 70
            ),
            makeFetchResult(
                identity: "second@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_120),
                remaining: 69
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("local", isDirectory: true),
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )
        await monitor.connectHistoryFolder(shared)
        try FileManager.default.moveItem(at: shared, to: parked)
        await monitor.deleteAnalyticsHistory()

        await monitor.refresh()

        XCTAssertEqual(monitor.historyDeletionStatus, .pendingSync)
        XCTAssertNotNil(defaults.data(forKey: "historySyncBookmark"))
        XCTAssertTrue(defaults.bool(forKey: "historySyncSelected"))

        try FileManager.default.moveItem(at: parked, to: shared)
        await monitor.retryHistoryDeletion()

        XCTAssertEqual(monitor.historyDeletionStatus, .complete)
        XCTAssertNil(monitor.syncFolderName)
        XCTAssertEqual(
            monitor.syncErrorMessage,
            "This history folder belongs to a different Codex account."
        )

        await monitor.refresh()

        XCTAssertEqual(monitor.historyDeletionStatus, .none)
        XCTAssertNil(monitor.syncFolderName)
        let sharedFiles = FileManager.default.enumerator(
            at: shared.appendingPathComponent("installations", isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey]
        )?.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        XCTAssertTrue(sharedFiles.isEmpty)
    }

    func testFailedFolderSwitchKeepsTheWorkingFolderConfigured() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory()
        let working = root.appendingPathComponent("working", isDirectory: true)
        let invalid = root.appendingPathComponent("invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("not history".utf8).write(to: invalid.appendingPathComponent("file.txt"))
        let source = FetchSequence([
            makeFetchResult(
                identity: "user@example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_900_000),
                remaining: 80
            )
        ])
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent("local", isDirectory: true),
            startsAutomatically: false,
            fetchUsage: { try await source.next() }
        )
        await monitor.connectHistoryFolder(working)

        await monitor.connectHistoryFolder(invalid)

        XCTAssertEqual(monitor.syncFolderName, "working")
        XCTAssertNotNil(monitor.syncErrorMessage)
        var stale = false
        let saved = try XCTUnwrap(defaults.data(forKey: "historySyncBookmark"))
        let savedURL = try URL(
            resolvingBookmarkData: saved,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        XCTAssertEqual(savedURL.standardizedFileURL, working.standardizedFileURL)
    }

    private func makeFetchResult(
        identity: String,
        fetchedAt: Date,
        remaining: Double,
        lifetimeTokens: Int64? = nil,
        lifetimeTokensObservedAt: Date? = nil,
        planType: String? = nil
    ) -> CodexFetchResult {
        makeFetchResult(
            account: .stable(identity: identity),
            fetchedAt: fetchedAt,
            remaining: remaining,
            lifetimeTokens: lifetimeTokens,
            lifetimeTokensObservedAt: lifetimeTokensObservedAt,
            planType: planType
        )
    }

    private func makeFetchResult(
        account: CodexAccountObservation,
        fetchedAt: Date,
        remaining: Double,
        lifetimeTokens: Int64? = nil,
        lifetimeTokensObservedAt: Date? = nil,
        planType: String? = nil
    ) -> CodexFetchResult {
        CodexFetchResult(
            snapshot: UsageSnapshot(
                mainLimit: LimitReading(
                    limitId: "codex",
                    name: "Codex",
                    window: UsageWindow(
                        remainingPercent: remaining,
                        resetsAt: Date(timeIntervalSince1970: 2_000_000),
                        durationMinutes: 10_080
                    )
                ),
                otherLimits: [],
                tokenHistory: [],
                emergencyResetCount: 0,
                fetchedAt: fetchedAt,
                accountFacts: lifetimeTokens.map {
                    AccountFacts(
                        lifetimeTokens: $0,
                        peakDailyTokens: nil,
                        longestRunningTurnSeconds: nil,
                        currentStreakDays: nil,
                        longestStreakDays: nil,
                        credits: nil,
                        spendControl: nil,
                        lifetimeTokensObservedAt: lifetimeTokensObservedAt
                            ?? fetchedAt
                    )
                }
            ),
            account: account,
            planType: planType
        )
    }
}

private actor FetchSequence {
    private var results: [CodexFetchResult]

    init(_ results: [CodexFetchResult]) {
        self.results = results
    }

    func next() throws -> CodexFetchResult {
        guard !results.isEmpty else {
            throw CodexClientError.invalidResponse
        }
        return results.removeFirst()
    }
}

private actor DelayedFetchSource {
    private let result: CodexFetchResult
    private var calls = 0

    init(_ result: CodexFetchResult) {
        self.result = result
    }

    var callCount: Int { calls }

    func next() async throws -> CodexFetchResult {
        calls += 1
        try await Task.sleep(nanoseconds: 50_000_000)
        return result
    }
}

private struct StoredStateFixture: Codable {
    let snapshot: UsageSnapshot?
    let samples: [UsageSample]
    let previousStatus: PaceStatus?
}
