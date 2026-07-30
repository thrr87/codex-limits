import Darwin
import Foundation
import XCTest
@testable import CodexLimits

final class LocalActivityPerformanceTests: XCTestCase {
    func testStableUsageEvaluationReusesLargeLocalHistory() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let window = UsageWindow(
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(2 * 86_400),
            durationMinutes: UsageHistoryPolicy.weeklyDurationMinutes
        )
        let account = UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "codex",
                name: "Codex",
                window: window
            ),
            otherLimits: [],
            tokenHistory: [],
            emergencyResetCount: 0,
            fetchedAt: now
        )
        let samples = [
            UsageSample(
                observedAt: window.startsAt,
                remainingPercent: 100,
                resetsAt: window.resetsAt,
                lifetimeTokens: 0
            ),
            UsageSample(
                observedAt: now,
                remainingPercent: 80,
                resetsAt: window.resetsAt,
                lifetimeTokens: 100_000
            )
        ]
        let source = LocalActivitySourceMetadata(
            source: .rolloutJSONL,
            sourceVersion: "0.145.0",
            schemaVersion: "rollout-jsonl-v1",
            sourceGeneration: 0,
            historyMode: nil,
            observedAt: now
        )
        let timestamp = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-60)
        )
        let facts = (0 ..< 100_000).map {
            LocalActivityFact(
                key: .token,
                availability: .available,
                value: nil,
                numericDelta: 1,
                tokenSegment: 0,
                reason: nil,
                eventID: "token-\($0)",
                eventTimestamp: timestamp,
                source: source
            )
        }
        let observation = LocalActivityObservation.continuous(
            sourceVersion: "0.145.0",
            observedAt: now
        )
        let compatibleSources: Set<LocalTokenDefinitionSource> = [
            LocalTokenDefinitionSource(source)
        ]
        let first = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a",
                localActivityFacts: [],
                localActivityHistoryFacts: facts,
                localActivityObservation: observation,
                localActivityContentRevision: 7,
                compatibleTokenSources: compatibleSources
            )
        )
        let start = ProcessInfo.processInfo.systemUptime

        let refreshed = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a",
                localActivityFacts: [],
                localActivityHistoryFacts: facts,
                localActivityObservation: observation,
                localActivityContentRevision: 7,
                reusableLocalAggregates:
                    try XCTUnwrap(first.reusableLocalAggregates),
                compatibleTokenSources: compatibleSources
            )
        )
        let milliseconds =
            (ProcessInfo.processInfo.systemUptime - start) * 1_000

        print(
            String(
                format: "STABLE_USAGE_EVALUATION facts=%d elapsed_ms=%.3f",
                facts.count,
                milliseconds
            )
        )
        XCTAssertEqual(
            refreshed.usagePerToken.current?.localTokenActivity,
            100_000
        )
        XCTAssertLessThan(milliseconds, 100)
    }

    func testTimestampParsingStaysResponsive() {
        let parser = LocalEventTimestampParser()
        let timestamp = "2026-07-29T20:46:09.123Z"
        let iterations = 50_000
        let start = ProcessInfo.processInfo.systemUptime
        var parsed: Date?

        for _ in 0..<iterations {
            parsed = parser.date(from: timestamp)
        }

        let milliseconds =
            (ProcessInfo.processInfo.systemUptime - start) * 1_000
        print(
            String(
                format: "TIMESTAMP_PARSE count=%d elapsed_ms=%.3f",
                iterations,
                milliseconds
            )
        )
        XCTAssertNotNil(parsed)
        XCTAssertLessThan(milliseconds, 1_000)
    }

    func testPersistedFactRestoreStaysResponsive() async throws {
        let root = temporaryDirectory()
        let rolloutDirectory = root.appendingPathComponent(
            "2026/07/28",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rolloutDirectory,
            withIntermediateDirectories: true
        )
        let rollout = rolloutDirectory.appendingPathComponent(
            "rollout-2026-07-28T10-00-00-benchmark.jsonl"
        )
        let recordCount = 20_000
        var fixture =
            #"{"timestamp":"2026-07-28T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"benchmark","cli_version":"0.145.0"}}"#
            + "\n"
        fixture.reserveCapacity(recordCount * 180)
        for ordinal in 1...recordCount {
            fixture +=
                #"{"timestamp":"2026-07-28T10:00:01.000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","model_context_window":272000,"info":{"total_token_usage":{"total_tokens":\#(ordinal * 100)},"last_token_usage":{"total_tokens":\#(ordinal)}}}}"#
                + "\n"
        }
        try Data(fixture.utf8).write(to: rollout)
        fixture.removeAll(keepingCapacity: false)

        let stateDirectory = root.appendingPathComponent(
            "state",
            isDirectory: true
        )
        let interval = DateInterval(
            start: try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-07-28T00:00:00Z")
            ),
            end: try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-07-29T00:00:00Z")
            )
        )
        let first = LocalActivityCollector(
            rootDirectory: root,
            stateDirectory: stateDirectory
        )
        await first.selectPartition("benchmark")
        var built = await first.refresh(interval: interval)
        var buildRefreshes = 1
        while built.facts.filter({ $0.key == .token }).count
            < recordCount - 1 {
            built = await first.refresh(interval: interval)
            buildRefreshes += 1
            XCTAssertLessThan(buildRefreshes, 10)
        }

        let restarted = LocalActivityCollector(
            rootDirectory: root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("benchmark")
        let residentBefore = currentResidentBytes()
        var start = ProcessInfo.processInfo.systemUptime
        var restored = await restarted.refresh(interval: interval)
        let pendingAfterFirstRefresh = await restarted.hasPendingImport()
        XCTAssertTrue(pendingAfterFirstRefresh)
        var refreshCount = 1
        var maximumRefreshMilliseconds =
            (ProcessInfo.processInfo.systemUptime - start) * 1_000
        while restored.facts.filter({ $0.key == .token }).count
            < recordCount - 1 {
            start = ProcessInfo.processInfo.systemUptime
            restored = await restarted.refresh(interval: interval)
            maximumRefreshMilliseconds = max(
                maximumRefreshMilliseconds,
                (ProcessInfo.processInfo.systemUptime - start) * 1_000
            )
            refreshCount += 1
            XCTAssertLessThan(refreshCount, 10)
        }
        let residentAfter = currentResidentBytes()
        let residentDelta = residentAfter >= residentBefore
            ? residentAfter - residentBefore
            : 0

        print(
            [
                "PERSISTED_FACT_RESTORE",
                "records=\(restored.facts.count)",
                "refreshes=\(refreshCount)",
                String(
                    format: "max_refresh_ms=%.3f",
                    maximumRefreshMilliseconds
                ),
                "resident_delta_bytes=\(residentDelta)"
            ].joined(separator: " ")
        )
        XCTAssertLessThanOrEqual(restored.bytesRead, 4_096)
        XCTAssertEqual(
            restored.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta).count,
            recordCount - 1
        )
        XCTAssertEqual(
            restored.facts.filter { $0.key == .token }
                .compactMap(\.contextUsage).count,
            recordCount
        )
        XCTAssertFalse(
            restored.facts.contains {
                $0.key == .context && $0.availability == .available
            }
        )
        XCTAssertGreaterThan(refreshCount, 1)
        let pendingAfterRestore = await restarted.hasPendingImport()
        XCTAssertFalse(pendingAfterRestore)
        XCTAssertLessThan(maximumRefreshMilliseconds, 3_000)
        XCTAssertLessThan(residentDelta, 256 * 1_024 * 1_024)
    }

    func testRepresentativeFixtureMetrics() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("representative.jsonl")

        let recordCount = 20_000
        var fixture =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-benchmark","cli_version":"0.145.0","history_mode":"paginated"}}"#
            + "\n"
        fixture.reserveCapacity(recordCount * 180)
        for ordinal in 1...recordCount {
            fixture +=
                #"{"timestamp":"2026-07-27T10:00:01.000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(ordinal * 100)}}}}"#
                + "\n"
        }
        let fixtureByteCount = fixture.utf8.count
        try Data(fixture.utf8).write(to: fileURL)
        fixture.removeAll(keepingCapacity: false)

        let source = IncrementalRolloutTailSource()
        let residentBeforeInitialRead = currentResidentBytes()
        let initialStart = ProcessInfo.processInfo.systemUptime
        let initial = try source.read(
            fileURL: fileURL,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )
        let initialMilliseconds =
            (ProcessInfo.processInfo.systemUptime - initialStart) * 1_000
        let residentAfterInitialRead = currentResidentBytes()
        let initialResidentDelta = residentAfterInitialRead >= residentBeforeInitialRead
            ? residentAfterInitialRead - residentBeforeInitialRead
            : 0

        let idleRefreshCount = 1_000
        let residentBeforeIdleRefreshes = currentResidentBytes()
        let idleCPUStart = clock()
        let idleWallStart = ProcessInfo.processInfo.systemUptime
        var idleBytesRead: UInt64 = 0
        var idleRecords = 0
        for _ in 0..<idleRefreshCount {
            let idle = try source.read(
                fileURL: fileURL,
                cursor: initial.cursor,
                observedAt: Date(timeIntervalSince1970: 200)
            )
            idleBytesRead += idle.bytesRead
            idleRecords += idle.records.count
        }
        let idleWallMilliseconds =
            (ProcessInfo.processInfo.systemUptime - idleWallStart) * 1_000
        let idleCPUMilliseconds =
            Double(clock() - idleCPUStart) / Double(CLOCKS_PER_SEC) * 1_000
        let residentAfterIdleRefreshes = currentResidentBytes()
        let idleResidentDelta = residentAfterIdleRefreshes >= residentBeforeIdleRefreshes
            ? residentAfterIdleRefreshes - residentBeforeIdleRefreshes
            : 0

        let appended =
            #"{"timestamp":"2026-07-27T10:00:02.000Z","ordinal":20001,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":2000100}}}}"#
            + "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        let appendedStart = ProcessInfo.processInfo.systemUptime
        let incremental = try source.read(
            fileURL: fileURL,
            cursor: initial.cursor,
            observedAt: Date(timeIntervalSince1970: 300)
        )
        let appendedMilliseconds =
            (ProcessInfo.processInfo.systemUptime - appendedStart) * 1_000
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)

        print(
            [
                "LOCAL_ACTIVITY_METRICS",
                "fixture_bytes=\(fixtureByteCount)",
                "fixture_records=\(initial.records.count)",
                String(format: "initial_ms=%.3f", initialMilliseconds),
                "initial_resident_delta_bytes=\(initialResidentDelta)",
                "idle_refreshes=\(idleRefreshCount)",
                String(format: "idle_wall_ms=%.3f", idleWallMilliseconds),
                String(format: "idle_cpu_ms=%.3f", idleCPUMilliseconds),
                "idle_resident_delta_bytes=\(idleResidentDelta)",
                "idle_bytes=\(idleBytesRead)",
                "idle_records=\(idleRecords)",
                "incremental_bytes=\(incremental.bytesRead)",
                "incremental_records=\(incremental.records.count)",
                String(format: "incremental_ms=%.3f", appendedMilliseconds),
                "max_rss_bytes=\(usage.ru_maxrss)"
            ].joined(separator: " ")
        )

        XCTAssertEqual(initial.records.count, recordCount + 1)
        XCTAssertEqual(idleBytesRead, 0)
        XCTAssertEqual(idleRecords, 0)
        XCTAssertEqual(
            incremental.bytesRead,
            UInt64(appended.utf8.count)
                + (initial.cursor.checkpoint?.byteLength ?? 0)
        )
        XCTAssertEqual(incremental.records.count, 1)
    }

    private func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}
