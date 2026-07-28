import Foundation
import XCTest
@testable import CodexLimits

@MainActor
final class UsageMonitorHistoryTests: XCTestCase {
    func testDeleteAnalyticsHistoryPreservesPreferencesAndDoesNotRestoreLegacySamples() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
                    fetchedAt: Date(timeIntervalSince1970: 1_900_000)
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

    func testRefreshSelectsTheObservedAccountBeforeRecording() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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

    func testRefreshShowsUsageButDoesNotRecordWhenAccountIdentityIsUnavailable() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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

        XCTAssertEqual(monitor.readerSnapshot.account?.mainLimit.window.remainingPercent, 80)
        XCTAssertTrue(monitor.samples.isEmpty)
    }

    func testExplicitRebuildReadsCodexAgainInsteadOfUsingTheCachedSnapshot() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cached = makeFetchResult(
            identity: "user@example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_900_000),
            remaining: 80
        )
        let fresh = makeFetchResult(
            identity: "user@example.com",
            fetchedAt: Date(timeIntervalSince1970: 1_900_060),
            remaining: 70
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
    }

    func testObservedUnknownAuthTransitionStartsAnIsolatedPartition() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
            restarted.readerSnapshot.account?.mainLimit.window.remainingPercent,
            20
        )
        XCTAssertEqual(restarted.readerSnapshot.chart.observed.count, 1)
        XCTAssertNil(restarted.readerSnapshot.guidance)
    }

    func testVersionedStoreWarningDoesNotMigrateFallbackSamplesToAnotherAccount() async throws {
        let suiteName = "UsageMonitorHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        remaining: Double
    ) -> CodexFetchResult {
        makeFetchResult(
            account: .stable(identity: identity),
            fetchedAt: fetchedAt,
            remaining: remaining
        )
    }

    private func makeFetchResult(
        account: CodexAccountObservation,
        fetchedAt: Date,
        remaining: Double
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
                fetchedAt: fetchedAt
            ),
            account: account
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

private struct StoredStateFixture: Codable {
    let snapshot: UsageSnapshot?
    let samples: [UsageSample]
    let previousStatus: PaceStatus?
}
