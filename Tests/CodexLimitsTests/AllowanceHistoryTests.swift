import ClaudeIntegrationCore
import Combine
import Darwin
import Foundation
import XCTest
@testable import CodexLimits

final class AllowanceHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDailyAppendRepairsAnInterruptedTailAndDeduplicatesCacheSeeds() throws {
        let directory = temporaryDirectory().appendingPathComponent("History")
        let first = point(now.addingTimeInterval(-600), remaining: 90)
        let second = point(now.addingTimeInterval(-300), remaining: 80)
        let third = point(now.addingTimeInterval(-60), remaining: 70)
        try AllowanceHistory.append([first, second], in: directory)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let original = try Data(contentsOf: file)
        try AllowanceHistory.append([first, second], in: directory)
        XCTAssertEqual(try Data(contentsOf: file), original)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"metric":"interrupted"#.utf8))
        try handle.close()
        XCTAssertEqual(try AllowanceHistory.read(in: directory, now: now), [first, second])
        try AllowanceHistory.append([third], in: directory)

        XCTAssertEqual(try AllowanceHistory.read(in: directory, now: now), [first, second, third])
        XCTAssertEqual(try Data(contentsOf: file).last, 10)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber, 0o600)
    }

    func testReadUsesExactRollingBoundsWithoutDeletingOlderHistory() throws {
        let directory = temporaryDirectory().appendingPathComponent("History")
        let old = point(now.addingTimeInterval(-90 * 86_400), remaining: 90)
        let boundary = point(now.addingTimeInterval(-84 * 86_400), remaining: 80)
        let current = point(now.addingTimeInterval(-60), remaining: 70)
        let future = point(now.addingTimeInterval(60), remaining: 60)
        try AllowanceHistory.append([old, boundary, current, future], in: directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let oldestFile = try XCTUnwrap(files.first)
        // Out-of-range archives are neither enumerated nor decoded by the reader.
        try Data("unread old archive".utf8).write(to: oldestFile)

        XCTAssertEqual(try AllowanceHistory.read(in: directory, now: now), [boundary, current])
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldestFile.path))
        try AllowanceHistory.delete(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testInvalidCommittedRecordsAndReadBoundsAreReported() throws {
        let directory = temporaryDirectory().appendingPathComponent("History")
        try AllowanceHistory.append([point(now, remaining: 90)], in: directory)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("not-json\n".utf8).write(to: file)
        XCTAssertThrowsError(try AllowanceHistory.read(in: directory, now: now)) {
            XCTAssertEqual($0 as? AllowanceHistoryError, .invalidRecord)
        }
        try Data(repeating: 0x20, count: AllowanceHistory.maximumFileBytes + 1).write(to: file)
        XCTAssertThrowsError(try AllowanceHistory.read(in: directory, now: now)) {
            XCTAssertEqual($0 as? AllowanceHistoryError, .readLimitExceeded)
        }
        XCTAssertThrowsError(try AllowanceHistory.append([
            AllowanceObservation(metric: "grok-weekly", observedAt: now, remainingPercent: .nan, resetsAt: now.addingTimeInterval(60))
        ], in: directory))
        XCTAssertThrowsError(try AllowanceHistory.append([
            AllowanceObservation(metric: "grok-weekly", observedAt: now, remainingPercent: 50, resetsAt: now.addingTimeInterval(60), startsAt: now.addingTimeInterval(1))
        ], in: directory))
        XCTAssertFalse(AllowanceObservation(
            metric: "grok-weekly", observedAt: now, remainingPercent: 50,
            resetsAt: now.addingTimeInterval(60), source: "raw\nresponse"
        ).isValid)
        let expiredDirectory = temporaryDirectory().appendingPathComponent("History")
        try AllowanceHistory.append([
            AllowanceObservation(metric: "grok-weekly", observedAt: now, remainingPercent: 50, resetsAt: now)
        ], in: expiredDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredDirectory.path))
    }

    func testCurrentPeriodReadSkipsOlderDailyFilesAndKeepsExistingReadBounds() throws {
        let directory = temporaryDirectory().appendingPathComponent("History")
        let old = point(now.addingTimeInterval(-20 * 86_400), remaining: 90)
        let current = point(now.addingTimeInterval(-60), remaining: 70)
        try AllowanceHistory.append([old, current], in: directory)
        let oldestFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.first)
        try Data("invalid older archive\n".utf8).write(to: oldestFile)
        XCTAssertEqual(try AllowanceHistory.read(in: directory, now: now, since: now.addingTimeInterval(-7 * 86_400)), [current])
        XCTAssertThrowsError(try AllowanceHistory.read(in: directory, now: now))
        XCTAssertTrue(try AllowanceHistory.read(in: directory, now: now, since: now.addingTimeInterval(1)).isEmpty)
        XCTAssertThrowsError(try AllowanceHistory.read(in: directory, now: now, since: Date(timeIntervalSince1970: .nan)))
    }

    func testContendedDayFileReturnsWithoutAnUnboundedWait() throws {
        let directory = temporaryDirectory().appendingPathComponent("History")
        let first = point(now.addingTimeInterval(-60), remaining: 90)
        try AllowanceHistory.append([first], in: directory)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let descriptor = open(file.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let started = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(try AllowanceHistory.append([point(now, remaining: 80)], in: directory)) {
            XCTAssertEqual($0 as? AllowanceHistoryError, .writeFailed)
        }

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(try AllowanceHistory.read(in: directory, now: now), [first])
    }

    @MainActor
    func testHiddenClaudeRelayRecordsHistoryAndVisibleStoreMigratesAndDeletesIt() async throws {
        let fixture = try claudeFixture()
        let service = ClaudeCodeSetupService(paths: fixture)
        _ = try await service.setUp()
        let first = claudeSnapshot(at: Date().addingTimeInterval(-180), remaining: 90)
        let second = claudeSnapshot(at: first.observedAt.addingTimeInterval(60), remaining: 80)
        let third = claudeSnapshot(at: second.observedAt.addingTimeInterval(60), remaining: 70)
        try JSONEncoder().encode(first).write(to: fixture.cacheURL)
        let store = ClaudeCodeIntegrationStore(isEnabled: true, menuBarSourceActive: false, service: service)
        for snapshot in [second, third] {
            XCTAssertTrue(try ClaudeRelay.storeIfNewer(snapshot, at: fixture.cacheURL, enabledMarkerURL: fixture.enabledMarkerURL))
        }
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertNil(store.snapshot)

        await store.setVisible(true)

        XCTAssertEqual(store.snapshot, third)
        XCTAssertEqual(store.history.count, 6)
        XCTAssertEqual(Set(store.history.map(\.metric)), ["claude-five-hour", "claude-seven-day"])
        XCTAssertEqual(Set(store.history.compactMap(\.source)), ["statusLine.rate_limits"])
        XCTAssertEqual(store.history.first?.observedAt, first.observedAt)
        XCTAssertNil(store.historyIssue)
        await store.setVisible(false)
        XCTAssertTrue(store.history.isEmpty)
        await store.setVisible(true)
        XCTAssertEqual(store.history.count, 6)

        await store.deleteData()

        XCTAssertTrue(store.history.isEmpty)
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyDirectory.path))
        XCTAssertFalse(store.hasStoredData)
        XCTAssertThrowsError(try ClaudeRelay.storeIfNewer(third, at: fixture.cacheURL, enabledMarkerURL: fixture.enabledMarkerURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyDirectory.path))
    }

    @MainActor
    func testClaudeHistoryFailureKeepsTheLatestAllowanceAndReportsTheIssue() async throws {
        let fixture = try claudeFixture()
        let service = ClaudeCodeSetupService(paths: fixture)
        _ = try await service.setUp()
        try Data("blocked history directory".utf8).write(to: fixture.historyDirectory)
        let snapshot = claudeSnapshot(at: Date().addingTimeInterval(-60), remaining: 65)

        XCTAssertTrue(try ClaudeRelay.storeIfNewer(snapshot, at: fixture.cacheURL, enabledMarkerURL: fixture.enabledMarkerURL))
        let persisted = try ClaudeRelay.readSnapshot(at: fixture.cacheURL)
        XCTAssertEqual(persisted.sevenDay, snapshot.sevenDay)
        XCTAssertEqual(persisted.historyWriteFailed, true)
        let store = ClaudeCodeIntegrationStore(isEnabled: true, menuBarSourceActive: false, service: service)
        await store.setVisible(true)
        XCTAssertEqual(store.snapshot?.sevenDay, snapshot.sevenDay)
        XCTAssertNotNil(store.historyIssue)
        XCTAssertTrue(store.history.isEmpty)
    }

    @MainActor
    func testOverviewDoesNotReadHistoryAndDetailStillLoadsWithoutLatestCache() async throws {
        let fixture = try claudeFixture()
        let service = ClaudeCodeSetupService(paths: fixture)
        _ = try await service.setUp()
        let snapshot = claudeSnapshot(at: Date().addingTimeInterval(-60), remaining: 70)
        try AllowanceHistory.append(snapshot.historyObservations, in: fixture.historyDirectory)
        let store = ClaudeCodeIntegrationStore(isEnabled: true, menuBarSourceActive: false, service: service)

        await store.setVisible(true, includeHistory: false)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertNil(store.overview)
        XCTAssertNil(store.historyIssue)
        await store.setVisible(true)

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.history.count, 2)
        XCTAssertNil(store.historyIssue)
        await store.setVisible(false)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.historyDirectory, includingPropertiesForKeys: nil).first)
        try Data("invalid history\n".utf8).write(to: file)
        await store.setVisible(true, includeHistory: false)
        XCTAssertNil(store.historyIssue)
        await store.setVisible(true)
        XCTAssertNotNil(store.historyIssue)
    }

    @MainActor
    func testClaudeOverviewUsesOnlyCurrentPeriodAndReleasesItsCompactSnapshot() async throws {
        let fixture = try claudeFixture()
        let service = ClaudeCodeSetupService(paths: fixture)
        _ = try await service.setUp()
        let snapshot = claudeSnapshot(at: Date().addingTimeInterval(-60), remaining: 70)
        try JSONEncoder().encode(snapshot).write(to: fixture.cacheURL)
        let previous = snapshot.historyObservations.map {
            AllowanceObservation(metric: $0.metric, observedAt: $0.observedAt.addingTimeInterval(-600),
                                 remainingPercent: 80, resetsAt: $0.resetsAt, startsAt: $0.startsAt, source: $0.source)
        }
        try AllowanceHistory.append(previous, in: fixture.historyDirectory)
        let old = claudeSnapshot(at: Date().addingTimeInterval(-20 * 86_400), remaining: 90)
        let oldPoint = AllowanceObservation(metric: "claude-seven-day", observedAt: old.observedAt,
                                           remainingPercent: 90, resetsAt: old.observedAt.addingTimeInterval(60))
        try AllowanceHistory.append([oldPoint], in: fixture.historyDirectory)
        let oldestFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.historyDirectory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.first)
        try Data("invalid old archive\n".utf8).write(to: oldestFile)
        let store = ClaudeCodeIntegrationStore(isEnabled: true, menuBarSourceActive: false, service: service)

        await store.setVisible(true, includeHistory: false, safetyBuffer: 5)

        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.overview?.observedSegments.flatMap { $0 }.count, 2)
        XCTAssertEqual(store.overview?.latest?.remaining, 70)
        XCTAssertEqual(store.overview?.target.last?.remaining, 5)
        XCTAssertNil(store.historyIssue)
        await store.setVisible(true)
        XCTAssertNil(store.overview)
        XCTAssertNotNil(store.historyIssue)
        await store.setVisible(false)
        let newestFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.historyDirectory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.last)
        try Data("invalid current archive\n".utf8).write(to: newestFile)
        await store.setVisible(true, includeHistory: false)
        XCTAssertEqual(store.overview?.observedSegments.flatMap { $0 }.count, 1)
        XCTAssertNotNil(store.historyIssue)
        await store.setEnabled(false)
        XCTAssertNil(store.overview)
        await store.deleteData()
        XCTAssertNil(store.overview)
    }

    @MainActor
    func testNotificationDuringHistoryReadTriggersOneLatestCacheRead() async throws {
        let fixture = try claudeFixture()
        let service = ClaudeCodeSetupService(paths: fixture)
        _ = try await service.setUp()
        let observedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 86_400) * 86_400 - 43_200)
        let first = claudeSnapshot(at: observedAt, remaining: 90)
        let second = claudeSnapshot(at: observedAt.addingTimeInterval(60), remaining: 80)
        try JSONEncoder().encode(first).write(to: fixture.cacheURL)
        let store = ClaudeCodeIntegrationStore(isEnabled: true, menuBarSourceActive: false, service: service)
        await store.setVisible(true)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.historyDirectory, includingPropertiesForKeys: nil).first)
        let descriptor = open(file.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        var cacheWasRead = false
        let observation = store.$snapshot.dropFirst().sink { _ in cacheWasRead = true }
        defer { observation.cancel() }
        let reading = Task { await store.checkForNewObservation(priority: .automatic) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !cacheWasRead, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(cacheWasRead)
        try await Task.sleep(for: .milliseconds(10))

        try JSONEncoder().encode(second).write(to: fixture.cacheURL, options: .atomic)
        await store.checkForNewObservation(priority: .automatic)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        await reading.value
        while store.snapshot?.observedAt != second.observedAt, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(store.snapshot?.observedAt, second.observedAt)
        XCTAssertEqual(store.snapshot?.sevenDay?.remainingPercent, 80)
    }

    private func point(_ observedAt: Date, remaining: Double) -> AllowanceObservation {
        AllowanceObservation(
            metric: "grok-weekly", observedAt: observedAt,
            remainingPercent: remaining, resetsAt: observedAt.addingTimeInterval(86_400),
            startsAt: observedAt.addingTimeInterval(-6 * 86_400), source: "creditUsagePercent"
        )
    }

    private func claudeSnapshot(at observedAt: Date, remaining: Double) -> ClaudeAllowanceSnapshot {
        let reset = Date().addingTimeInterval(3_600)
        return ClaudeAllowanceSnapshot(
            observedAt: observedAt, cliVersion: "2.1.231",
            fiveHour: ClaudeAllowanceWindowSnapshot(remainingPercent: remaining, resetsAt: reset),
            sevenDay: ClaudeAllowanceWindowSnapshot(remainingPercent: remaining, resetsAt: reset)
        )
    }

    private func claudeFixture() throws -> ClaudeCodeIntegrationPaths {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return ClaudeCodeIntegrationPaths(
            executableCandidates: [executable], settingsURL: root.appendingPathComponent("settings.json"),
            dataDirectory: root.appendingPathComponent("data"), helperURL: executable
        )
    }
}
