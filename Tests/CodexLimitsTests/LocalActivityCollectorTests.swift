import XCTest
import SQLite3
@testable import CodexLimits

final class LocalActivityCollectorTests: XCTestCase {
    func testFirstReadBuildsThenOrdinaryRefreshTailsOnlyNewBytes() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()

        let first = await collector.refresh(interval: interval)
        try fixture.append(
            fixture.tokens(total: 800, ordinal: 3, minute: 3),
            to: file
        )
        let second = await collector.refresh(interval: interval)
        let third = await collector.refresh(interval: interval)

        XCTAssertEqual(
            first.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500]
        )
        XCTAssertEqual(
            second.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500, 200]
        )
        XCTAssertGreaterThan(first.bytesRead, second.bytesRead)
        XCTAssertGreaterThan(second.bytesRead, 0)
        XCTAssertEqual(third.bytesRead, 0)
        XCTAssertEqual(third.facts.count, second.facts.count)
        XCTAssertEqual(second.observation.coverage, .high)
    }

    func testReleasedFactsRestoreFromThePersistedCache() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent(
                "collector-state",
                isDirectory: true
            )
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        let first = await collector.refresh(interval: interval)

        await collector.releaseCachedFacts()
        let restored = await collector.refresh(interval: interval)

        XCTAssertEqual(restored.facts, first.facts)
    }

    func testReleasedFactsStayReleasedWhenARefreshWasSuspended() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let versionDelay = SecondInstalledVersionDelay()
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent(
                "collector-state",
                isDirectory: true
            ),
            installedCLIVersion: {
                await versionDelay.response()
            }
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        let first = await collector.refresh(interval: interval)
        try fixture.append(
            fixture.tokens(total: 800, ordinal: 3, minute: 3),
            to: file
        )
        let suspended = Task {
            await collector.refresh(interval: interval)
        }
        await versionDelay.waitUntilSecondRequest()

        await collector.releaseCachedFacts()
        await versionDelay.releaseSecondRequest()
        _ = await suspended.value
        let restored = await collector.refresh(
            interval: interval,
            refreshMetadata: false
        )

        XCTAssertEqual(
            first.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500]
        )
        XCTAssertEqual(
            restored.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta),
            [500, 200]
        )
    }

    func testMissingTrackedFileKeepsFactsAndNamesTheSourceGap() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        _ = await collector.refresh(interval: interval)

        try FileManager.default.removeItem(at: file)
        let result = await collector.refresh(interval: interval)

        XCTAssertEqual(
            result.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500]
        )
        XCTAssertEqual(result.observation.coverage, .low)
        XCTAssertEqual(result.observation.reason, "Local task records are missing")
    }

    func testRewrittenRolloutLowersCoverageForThatObservation() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        let observedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-28T12:00:00Z")
        )
        _ = await collector.refresh(
            interval: interval,
            observedAt: observedAt
        )
        try Data(
            (
                fixture.session(threadID: "task-1", ordinal: 0)
                    + "\n"
                    + fixture.tokens(total: 700, ordinal: 3, minute: 3)
                    + "\n"
            ).utf8
        ).write(to: file, options: .atomic)

        let result = await collector.refresh(
            interval: interval,
            observedAt: observedAt
        )
        let unchanged = await collector.refresh(
            interval: interval,
            observedAt: observedAt
        )
        let failedProjectionSource = ReadOnlyThreadProjectionSource { _ in
            throw CocoaError(.fileReadUnknown)
        }
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory,
            projectionSource: failedProjectionSource
        )
        await restarted.selectPartition("stable-account")
        let afterRestart = await restarted.refresh(
            interval: interval,
            observedAt: observedAt
        )

        XCTAssertEqual(result.observation.coverage, .low)
        XCTAssertEqual(
            result.observation.reason,
            "Local task record continuity changed"
        )
        XCTAssertEqual(unchanged.observation.coverage, .low)
        XCTAssertEqual(
            unchanged.observation.reason,
            "Local task record continuity changed"
        )
        XCTAssertEqual(afterRestart.observation.coverage, .low)
        XCTAssertEqual(
            afterRestart.observation.reason,
            "Local task record continuity changed"
        )
    }

    func testRewrittenRolloutKeepsFactsFromUnchangedActiveFiles() async throws {
        let fixture = try CollectorFixture()
        let rewritten = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-2",
            lines: [
                fixture.session(threadID: "task-2", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 3),
                fixture.tokens(total: 1_000, ordinal: 2, minute: 4)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        _ = await collector.refresh(interval: interval)
        try Data(
            (
                [
                    fixture.session(threadID: "task-1", ordinal: 0),
                    fixture.tokens(total: 100, ordinal: 1, minute: 1),
                    fixture.tokens(total: 800, ordinal: 2, minute: 2)
                ].joined(separator: "\n") + "\n"
            ).utf8
        ).write(to: rewritten, options: .atomic)

        let result = await collector.refresh(interval: interval)

        XCTAssertEqual(
            result.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta).sorted(),
            [700, 900]
        )
    }

    func testNewestRolloutDiscontinuityReplacesAnOlderBoundary() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        let formatter = ISO8601DateFormatter()
        _ = await collector.refresh(
            interval: interval,
            observedAt: try XCTUnwrap(
                formatter.date(from: "2026-07-27T23:58:00Z")
            )
        )
        try Data(
            (
                fixture.session(threadID: "task-1", ordinal: 0)
                    + "\n"
                    + fixture.tokens(total: 700, ordinal: 3, minute: 3)
                    + "\n"
            ).utf8
        ).write(to: file, options: .atomic)
        _ = await collector.refresh(
            interval: interval,
            observedAt: try XCTUnwrap(
                formatter.date(from: "2026-07-27T23:59:00Z")
            )
        )
        try Data(
            (
                fixture.session(threadID: "task-1", ordinal: 0)
                    + "\n"
                    + fixture.tokens(total: 900, ordinal: 4, minute: 4)
                    + "\n"
            ).utf8
        ).write(to: file, options: .atomic)
        _ = await collector.refresh(
            interval: interval,
            observedAt: try XCTUnwrap(
                formatter.date(from: "2026-07-28T10:05:00Z")
            )
        )
        let unchanged = await collector.refresh(
            interval: interval,
            observedAt: try XCTUnwrap(
                formatter.date(from: "2026-07-28T10:06:00Z")
            )
        )
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let afterRestart = await restarted.refresh(
            interval: interval,
            observedAt: try XCTUnwrap(
                formatter.date(from: "2026-07-28T10:07:00Z")
            )
        )

        XCTAssertEqual(unchanged.observation.coverage, .low)
        XCTAssertEqual(
            unchanged.observation.reason,
            "Local task record continuity changed"
        )
        XCTAssertEqual(afterRestart.observation.coverage, .low)
        XCTAssertEqual(
            afterRestart.observation.reason,
            "Local task record continuity changed"
        )
    }

    func testDiscoversTaskMetadataThroughReadOnlyThreadList() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let requests = CollectorProjectionRequests()
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let source = ReadOnlyThreadProjectionSource { request in
            await requests.record(request)
            return Data(#"""
            {"result":{"data":[{
              "id":"task-1",
              "parentThreadId":null,
              "cliVersion":"0.145.0",
              "cwd":"/synthetic/projects/atlas",
              "path":"\#(file.path)",
              "createdAt":1785232800,
              "updatedAt":1785232920
            }],"nextCursor":null}}
            """#.utf8)
        }
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory,
            projectionSource: source
        )
        await collector.selectPartition("stable-account")

        let observedAt = Date(timeIntervalSince1970: 1_785_232_920)
        let result = await collector.refresh(
            interval: try fixture.interval(),
            observedAt: observedAt
        )
        _ = await collector.refresh(
            interval: try fixture.interval(),
            observedAt: observedAt.addingTimeInterval(60)
        )
        let recordedRequests = await requests.values
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let restored = await restarted.refresh(
            interval: try fixture.interval(),
            observedAt: observedAt.addingTimeInterval(120)
        )

        XCTAssertEqual(result.projections.map(\.taskID), ["task-1"])
        XCTAssertEqual(result.projections.map(\.projectLabel), ["atlas"])
        XCTAssertEqual(result.projections.map(\.rolloutFileURL), [nil])
        XCTAssertEqual(
            recordedRequests,
            [
                .list(
                    cursor: nil,
                    limit: 100,
                    useStateDBOnly: true,
                    sortKey: "updated_at"
                ),
                .list(
                    cursor: nil,
                    limit: 100,
                    useStateDBOnly: true,
                    sortKey: "updated_at"
                )
            ]
        )
        XCTAssertEqual(result.observation.coverage, .high)
        XCTAssertEqual(restored.projections.map(\.projectLabel), ["atlas"])
    }

    func testRestoresDurableCursorForTheSameAccountPartition() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let firstCollector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await firstCollector.selectPartition("stable-account")
        let first = await firstCollector.refresh(
            interval: try fixture.interval()
        )

        let restartedCollector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restartedCollector.selectPartition("stable-account")
        let restored = await restartedCollector.refresh(
            interval: try fixture.interval()
        )

        XCTAssertGreaterThan(first.bytesRead, 0)
        XCTAssertEqual(restored.bytesRead, 0)
        XCTAssertEqual(
            restored.facts.compactMap(\.eventID),
            first.facts.compactMap(\.eventID)
        )
        XCTAssertEqual(
            restored.facts.compactMap(\.numericDelta),
            first.facts.compactMap(\.numericDelta)
        )
    }

    func testRestoreCompactsLegacyContextFactsIntoTheirTokenFacts() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                #"{"timestamp":"2026-07-28T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","model_context_window":272000,"info":{"total_token_usage":{"total_tokens":100},"last_token_usage":{"total_tokens":80}}}}"#,
                #"{"timestamp":"2026-07-28T10:02:00.000Z","ordinal":2,"type":"event_msg","payload":{"type":"token_count","model_context_window":272000,"info":{"total_token_usage":{"total_tokens":600},"last_token_usage":{"total_tokens":90}}}}"#
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let first = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await first.selectPartition("stable-account")
        _ = await first.refresh(interval: try fixture.interval())
        let partitionDirectory = stateDirectory.appendingPathComponent(
            "stable-account",
            isDirectory: true
        )
        let factsFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: partitionDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasSuffix(".facts.jsonl") }
        )
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let persisted = try String(contentsOf: factsFile, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(LocalActivityFact.self, from: Data($0.utf8)) }
        var legacy: [LocalActivityFact] = []
        for fact in persisted {
            guard fact.key == .token,
                  let contextUsage = fact.contextUsage else {
                legacy.append(fact)
                continue
            }
            legacy.append(
                LocalActivityFact(
                    key: fact.key,
                    availability: fact.availability,
                    value: fact.value,
                    numericDelta: fact.numericDelta,
                    tokenSegment: fact.tokenSegment,
                    reason: fact.reason,
                    eventID: fact.eventID,
                    eventTimestamp: fact.eventTimestamp,
                    source: fact.source,
                    context: fact.context,
                    tokenDelta: fact.tokenDelta
                )
            )
            legacy.append(
                LocalActivityFact(
                    key: .context,
                    availability: .available,
                    value: .tokens(contextUsage),
                    numericDelta: nil,
                    tokenSegment: nil,
                    reason: nil,
                    eventID: fact.eventID,
                    eventTimestamp: fact.eventTimestamp,
                    source: contextUsage.totalTokens == 90
                        ? LocalActivitySourceMetadata(
                            source: fact.source.source,
                            sourceVersion: fact.source.sourceVersion,
                            schemaVersion: fact.source.schemaVersion,
                            sourceGeneration:
                                fact.source.sourceGeneration + 1,
                            historyMode: fact.source.historyMode,
                            observedAt: fact.source.observedAt
                        )
                        : fact.source,
                    context: fact.context
                )
            )
        }
        var encoded = Data()
        for fact in legacy {
            encoded.append(try encoder.encode(fact))
            encoded.append(0x0A)
        }
        try encoded.write(to: factsFile)

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let restored = await restarted.refresh(interval: try fixture.interval())

        XCTAssertEqual(
            restored.facts.filter { $0.key == .token }
                .compactMap(\.contextUsage).map(\.totalTokens),
            [80]
        )
        XCTAssertEqual(
            restored.facts.filter {
                $0.key == .context && $0.availability == .available
            }.compactMap { fact -> Int64? in
                guard case let .tokens(usage) = fact.value else {
                    return nil
                }
                return usage.totalTokens
            },
            [90]
        )
    }

    func testRestartedCollectorKeepsCursorAfterRolloutRename() async throws {
        let fixture = try CollectorFixture()
        let rollout = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let interval = try fixture.interval()
        let firstCollector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await firstCollector.selectPartition("stable-account")
        _ = await firstCollector.refresh(interval: interval)

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let renamed = rollout.deletingLastPathComponent()
            .appendingPathComponent("rollout-renamed-task-1.jsonl")
        try FileManager.default.moveItem(at: rollout, to: renamed)

        let restored = await restarted.refresh(interval: interval)

        XCTAssertEqual(restored.bytesRead, 0)
        XCTAssertEqual(
            restored.facts.filter {
                $0.key == .token
            }.compactMap(\.numericDelta),
            [500]
        )
        try fixture.append(
            fixture.tokens(total: 800, ordinal: 3, minute: 3),
            to: renamed
        )
        let updated = await restarted.refresh(interval: interval)
        XCTAssertGreaterThan(updated.bytesRead, 0)
        XCTAssertEqual(
            updated.facts.filter {
                $0.key == .token
            }.compactMap(\.numericDelta),
            [500, 200]
        )

        let restartedAgain = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restartedAgain.selectPartition("stable-account")

        let restoredAgain = await restartedAgain.refresh(interval: interval)

        XCTAssertEqual(restoredAgain.bytesRead, 0)
        XCTAssertEqual(
            restoredAgain.facts.filter {
                $0.key == .token
            }.compactMap(\.numericDelta),
            [500, 200]
        )
    }

    func testThreadListFindsAResumedTaskFromAnOlderRolloutFolder() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/20",
            threadID: "task-old",
            lines: [
                fixture.session(threadID: "task-old", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let source = ReadOnlyThreadProjectionSource { request in
            switch request {
            case .list:
                return Data(#"""
                {"result":{"data":[{
                  "id":"task-old",
                  "parentThreadId":null,
                  "cliVersion":"0.145.0",
                  "cwd":"/synthetic/projects/atlas",
                  "path":"\#(file.path)",
                  "createdAt":1784541600,
                  "updatedAt":1785232920
                }],"nextCursor":null}}
                """#.utf8)
            case .read:
                XCTFail("The listed task should not need a fallback read")
                return Data()
            }
        }
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: nil,
            projectionSource: source
        )

        let result = await collector.refresh(
            interval: try fixture.interval()
        )

        XCTAssertEqual(
            result.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500]
        )
        XCTAssertEqual(result.projections.map(\.taskID), ["task-old"])
        XCTAssertEqual(result.observation.coverage, .high)
    }

    func testDeletedFileFromAnOlderIntervalDoesNotLowerCurrentCoverage() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: nil
        )
        _ = await collector.refresh(interval: try fixture.interval())
        try FileManager.default.removeItem(at: file)

        let later = await collector.refresh(
            interval: try fixture.interval(
                start: "2026-08-04T00:00:00Z",
                end: "2026-08-05T00:00:00Z"
            )
        )

        XCTAssertEqual(
            later.observation.coverage,
            .high,
            "\(later.observation)"
        )
        XCTAssertTrue(later.facts.isEmpty)
    }

    func testUncheckedCLIVersionLowersCoverageAndNamesTheReason() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(
                    threadID: "task-1",
                    ordinal: 0,
                    cliVersion: "0.146.0"
                ),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: nil
        )

        let result = await collector.refresh(
            interval: try fixture.interval()
        )

        XCTAssertEqual(result.observation.coverage, .low)
        XCTAssertEqual(
            result.observation.reason,
            "This Codex CLI version has not been checked"
        )
    }

    func testInstalledUncheckedCLIVersionLowersCoverage() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: nil,
            installedCLIVersion: { "0.146.0" }
        )

        let result = await collector.refresh(
            interval: try fixture.interval()
        )

        XCTAssertEqual(result.observation.coverage, .low)
        XCTAssertEqual(
            result.observation.reason,
            "This Codex CLI version has not been checked"
        )
    }

    func testUnavailableInstalledCLIVersionLowersCoverage() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: nil,
            installedCLIVersion: { nil }
        )

        let result = await collector.refresh(
            interval: try fixture.interval()
        )

        XCTAssertEqual(result.observation.coverage, .low)
        XCTAssertEqual(
            result.observation.reason,
            "Installed Codex CLI version is unavailable"
        )
    }

    func testThreadListFollowsBoundedPagination() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let requests = CollectorProjectionRequests()
        let source = ReadOnlyThreadProjectionSource { request in
            await requests.record(request)
            switch request {
            case .list(cursor: nil, _, _, _):
                return Data(
                    #"{"result":{"data":[],"nextCursor":"page-2"}}"#.utf8
                )
            case .list(cursor: "page-2", _, _, _):
                return Data(#"""
                {"result":{"data":[{
                  "id":"task-1",
                  "parentThreadId":null,
                  "cliVersion":"0.145.0",
                  "cwd":"/synthetic/projects/atlas",
                  "path":"\#(file.path)",
                  "createdAt":1785232800,
                  "updatedAt":1785232920
                }],"nextCursor":null}}
                """#.utf8)
            case .list:
                XCTFail("Unexpected cursor")
                return Data()
            case .read:
                XCTFail("The paged task should not need a fallback read")
                return Data()
            }
        }
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: nil,
            projectionSource: source
        )

        let interval = try fixture.interval()
        let result = await collector.refresh(interval: interval)
        _ = await collector.refresh(interval: interval)
        let recordedRequests = await requests.values

        XCTAssertEqual(result.projections.map(\.taskID), ["task-1"])
        XCTAssertEqual(
            recordedRequests,
            [
                .list(
                    cursor: nil,
                    limit: 100,
                    useStateDBOnly: true,
                    sortKey: "updated_at"
                ),
                .list(
                    cursor: "page-2",
                    limit: 100,
                    useStateDBOnly: true,
                    sortKey: "updated_at"
                ),
                .list(
                    cursor: nil,
                    limit: 100,
                    useStateDBOnly: true,
                    sortKey: "updated_at"
                )
            ]
        )
        XCTAssertEqual(result.observation.coverage, .high)
    }

    func testFailedTaskDiscoveryLowersCoverage() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let source = ReadOnlyThreadProjectionSource { _ in
            throw CocoaError(.fileReadCorruptFile)
        }
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: nil,
            projectionSource: source
        )

        let result = await collector.refresh(interval: try fixture.interval())

        XCTAssertEqual(result.observation.coverage, .low)
        XCTAssertEqual(
            result.observation.reason,
            "Local task discovery is incomplete"
        )
    }

    func testResumedChildIncludesItsOlderRootProjection() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "child",
            lines: [
                fixture.session(threadID: "child", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let requests = CollectorProjectionRequests()
        let source = ReadOnlyThreadProjectionSource { request in
            await requests.record(request)
            switch request {
            case .list(cursor: nil, _, _, _):
                return Data(#"""
                {"result":{"data":[{
                  "id":"child",
                  "parentThreadId":"older-root",
                  "cliVersion":"0.145.0",
                  "cwd":"/synthetic/projects/atlas",
                  "path":"\#(file.path)",
                  "createdAt":1785232800,
                  "updatedAt":1785232920
                }],"nextCursor":null}}
                """#.utf8)
            case .read(threadID: "older-root", includeTurns: false):
                return Data(#"""
                {"result":{"thread":{
                  "id":"older-root",
                  "parentThreadId":null,
                  "cliVersion":"0.145.0",
                  "cwd":"/synthetic/projects/atlas",
                  "path":null,
                  "createdAt":1784628000,
                  "updatedAt":1784628000
                }}}
                """#.utf8)
            default:
                XCTFail("Unexpected projection request: \(request)")
                return Data()
            }
        }
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: nil,
            projectionSource: source
        )

        let result = await collector.refresh(interval: try fixture.interval())
        let recordedRequests = await requests.values

        XCTAssertEqual(
            result.projections.map(\.taskID),
            ["child", "older-root"]
        )
        XCTAssertTrue(
            recordedRequests.contains(
                .read(threadID: "older-root", includeTurns: false)
            )
        )
    }

    func testCollectorPublishesObservedDescendantWithoutTokenActivity() async throws {
        let fixture = try CollectorFixture()
        let rootFile = try fixture.rollout(
            day: "2026/07/28",
            threadID: "root",
            lines: [
                fixture.session(threadID: "root", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let source = ReadOnlyThreadProjectionSource { request in
            switch request {
            case .list(cursor: nil, _, _, _):
                return Data(#"""
                {"result":{"data":[{
                  "id":"root",
                  "parentThreadId":null,
                  "cliVersion":"0.145.0",
                  "cwd":"/synthetic/projects/atlas",
                  "path":"\#(rootFile.path)",
                  "createdAt":1785232800,
                  "updatedAt":1785232920
                },{
                  "id":"quiet-child",
                  "parentThreadId":"root",
                  "cliVersion":"0.145.0",
                  "cwd":"/synthetic/projects/atlas",
                  "path":null,
                  "createdAt":1785232860,
                  "updatedAt":1785232920
                }],"nextCursor":null}}
                """#.utf8)
            default:
                XCTFail("Unexpected projection request: \(request)")
                return Data()
            }
        }
        let interval = try fixture.interval()
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: nil,
            projectionSource: source
        )

        let result = await collector.refresh(interval: interval)
        let receipt = UsageReceiptAggregator.evaluate(
            facts: result.facts,
            projections: result.projections,
            interval: interval,
            observation: result.observation
        ).slice(in: interval, filters: .all).receipts.first

        XCTAssertEqual(
            result.projections.map(\.taskID),
            ["quiet-child", "root"]
        )
        XCTAssertEqual(receipt?.taskTree.children.map(\.taskID), [
            "quiet-child"
        ])
        XCTAssertEqual(receipt?.taskTree.children.first?.directTokens, 0)
    }

    func testVersionFourStateRebuildsContextFromTheRollout() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let first = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await first.selectPartition("stable-account")
        let interval = try fixture.interval()
        _ = await first.refresh(interval: interval)
        let partitionDirectory = stateDirectory.appendingPathComponent(
            "stable-account",
            isDirectory: true
        )
        let stateFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: partitionDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
        let factsFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: partitionDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasSuffix(".facts.jsonl") }
        )
        var state = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateFile)
            ) as? [String: Any]
        )
        state["version"] = 4
        state.removeValue(forKey: "projection")
        if var normalization = state["normalization"] as? [String: Any] {
            normalization.removeValue(forKey: "context")
            state["normalization"] = normalization
        }
        try JSONSerialization.data(withJSONObject: state).write(
            to: stateFile,
            options: .atomic
        )
        let versionFourFacts = try String(
            contentsOf: factsFile,
            encoding: .utf8
        ).split(separator: "\n").map { line -> String in
            var fact = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                ) as? [String: Any]
            )
            fact.removeValue(forKey: "context")
            let data = try JSONSerialization.data(withJSONObject: fact)
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }.joined(separator: "\n") + "\n"
        try versionFourFacts.write(
            to: factsFile,
            atomically: true,
            encoding: .utf8
        )

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let restored = await restarted.refresh(interval: interval)
        let migrated = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateFile)
            ) as? [String: Any]
        )
        let receiptSlice = UsageReceiptAggregator.evaluate(
            facts: restored.facts,
            projections: restored.projections,
            interval: interval,
            observation: restored.observation
        ).slice(in: interval, filters: .all)

        XCTAssertGreaterThan(restored.bytesRead, 0)
        XCTAssertEqual(
            restored.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500]
        )
        XCTAssertEqual(receiptSlice.receipts.first?.rootTaskID, "task-1")
        XCTAssertEqual(receiptSlice.receipts.first?.tokens, 500)
        XCTAssertEqual(migrated["version"] as? Int, 7)
        XCTAssertNil(migrated["path"])
        XCTAssertNotNil(migrated["pathFingerprint"])
    }

    func testAncestorFoundByLaterListSurvivesRestart() async throws {
        let fixture = try CollectorFixture()
        let rollout = try fixture.rollout(
            day: "2026/07/28",
            threadID: "child",
            lines: [
                fixture.session(threadID: "child", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let responses = ParentProjectionResponses()
        let source = ReadOnlyThreadProjectionSource { request in
            try await responses.response(
                to: request,
                rolloutPath: rollout.path
            )
        }
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory,
            projectionSource: source
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()

        let incomplete = await collector.refresh(interval: interval)
        let completed = await collector.refresh(interval: interval)
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let restored = await restarted.refresh(interval: interval)

        XCTAssertEqual(incomplete.projections.map(\.taskID), ["child"])
        XCTAssertEqual(
            completed.projections.map(\.taskID),
            ["child", "older-root"]
        )
        XCTAssertEqual(
            restored.projections.map(\.taskID),
            ["child", "older-root"]
        )
        XCTAssertEqual(restored.bytesRead, 0)
    }

    func testMalformedRecordLowersCoverageAndKeepsValidFacts() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                #"{"timestamp":"2026-07-28T10:00:30.000Z","type":"event_msg""#,
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()

        let first = await collector.refresh(
            interval: interval,
            observedAt: interval.end
        )
        let second = await collector.refresh(
            interval: interval,
            observedAt: interval.end
        )

        XCTAssertTrue(first.facts.contains { $0.key == .token })
        XCTAssertEqual(
            first.observation,
            .gap(
                sourceVersion: "0.145.0",
                observedAt: interval.end,
                reason: "Some local diagnostic records could not be read"
            )
        )
        if case let .gap(_, _, reason) = second.observation {
            XCTAssertEqual(
                reason,
                "Some local diagnostic records could not be read"
            )
        } else {
            XCTFail("Expected persisted malformed-record Coverage gap")
        }
    }

    func testMalformedOnlyAppendKeepsCoverageGapAcrossRefreshAndRestart() async throws {
        let fixture = try CollectorFixture()
        let rollout = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let interval = try fixture.interval()
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        _ = await collector.refresh(
            interval: interval,
            observedAt: interval.end
        )
        try fixture.append(
            #"{"timestamp":"2026-07-28T10:03:00.000Z","type":"event_msg""#,
            to: rollout
        )

        let malformed = await collector.refresh(
            interval: interval,
            observedAt: interval.end
        )
        let idle = await collector.refresh(
            interval: interval,
            observedAt: interval.end
        )
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let restored = await restarted.refresh(
            interval: interval,
            observedAt: interval.end
        )

        for collection in [malformed, idle, restored] {
            guard case let .gap(_, _, reason) = collection.observation else {
                XCTFail("Expected a durable malformed-record Coverage gap")
                continue
            }
            XCTAssertEqual(
                reason,
                "Some local diagnostic records could not be read"
            )
        }
    }

    func testPersistedStateStoresOnlyARolloutPathFingerprint() async throws {
        let fixture = try CollectorFixture()
        let rollout = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2),
                #"{"timestamp":"2026-07-28T10:03:00.000Z","ordinal":3,"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"CommandExecution","command":"PRIVATE_COMMAND","output":"PRIVATE_OUTPUT","status":"completed"}}}"#
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")

        _ = await collector.refresh(interval: try fixture.interval())

        let partitionDirectory = stateDirectory.appendingPathComponent(
            "stable-account",
            isDirectory: true
        )
        let stateFiles = try FileManager.default.contentsOfDirectory(
            at: partitionDirectory,
            includingPropertiesForKeys: nil
        )
        let persistedText = try stateFiles.map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined()
        XCTAssertFalse(persistedText.contains(fixture.root.path))
        XCTAssertFalse(
            persistedText.contains(rollout.lastPathComponent)
        )
        XCTAssertFalse(persistedText.contains("\"path\":"))
        XCTAssertTrue(persistedText.contains("\"pathFingerprint\":"))
        XCTAssertFalse(persistedText.contains("PRIVATE_COMMAND"))
        XCTAssertFalse(persistedText.contains("PRIVATE_OUTPUT"))
    }

    func testIncrementalRefreshAppendsFactsWithoutRewritingHistory() async throws {
        let fixture = try CollectorFixture()
        let rollout = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        let first = await collector.refresh(interval: interval)
        let partitionDirectory = stateDirectory.appendingPathComponent(
            "stable-account",
            isDirectory: true
        )
        let factsFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: partitionDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasSuffix(".facts.jsonl") }
        )
        let before = try Data(contentsOf: factsFile)

        try fixture.append(
            fixture.tokens(total: 800, ordinal: 3, minute: 3),
            to: rollout
        )
        let appended = await collector.refresh(interval: interval)
        let after = try Data(contentsOf: factsFile)

        XCTAssertTrue(after.starts(with: before))
        XCTAssertGreaterThan(after.count, before.count)
        XCTAssertLessThan(after.count - before.count, before.count)
        XCTAssertNotEqual(appended.contentRevision, first.contentRevision)
        XCTAssertEqual(
            appended.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta),
            [500, 200]
        )
    }

    func testIdleRefreshDoesNotRewriteDurableState() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        _ = await collector.refresh(interval: interval)
        let partitionDirectory = stateDirectory.appendingPathComponent(
            "stable-account",
            isDirectory: true
        )
        let stateFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: partitionDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
        let before = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: stateFile.path
            )[.modificationDate] as? Date
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        let idle = await collector.refresh(interval: interval)
        let after = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: stateFile.path
            )[.modificationDate] as? Date
        )

        XCTAssertEqual(idle.bytesRead, 0)
        XCTAssertEqual(after, before)
    }

    func testIdleRefreshKeepsContentRevision() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()

        let first = await collector.refresh(
            interval: interval,
            observedAt: Date(timeIntervalSince1970: 100)
        )
        let idle = await collector.refresh(
            interval: interval,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(idle.contentRevision, first.contentRevision)
        XCTAssertEqual(idle.facts, first.facts)
    }

    func testProjectionObservationTimeDoesNotChangeContentRevision() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let source = ReadOnlyThreadProjectionSource { request in
            guard case .list(cursor: nil, _, _, _) = request else {
                throw CocoaError(.fileReadUnknown)
            }
            return Data(#"""
            {"result":{"data":[{
              "id":"task-1",
              "parentThreadId":null,
              "cliVersion":"0.145.0",
              "cwd":"/synthetic/projects/atlas",
              "path":"\#(file.path)",
              "createdAt":1785232800,
              "updatedAt":1785232920
            }],"nextCursor":null}}
            """#.utf8)
        }
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state"),
            projectionSource: source
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        let first = await collector.refresh(interval: interval)
        try await Task.sleep(nanoseconds: 1_000_000)

        let idle = await collector.refresh(interval: interval)

        XCTAssertNotEqual(
            first.projections.first?.source.observedAt,
            idle.projections.first?.source.observedAt
        )
        XCTAssertEqual(idle.contentRevision, first.contentRevision)
    }

    func testMissingRootKeepsLastPublishedFacts() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        let first = await collector.refresh(interval: interval)

        try FileManager.default.removeItem(at: fixture.root)
        let unavailable = await collector.refresh(interval: interval)

        XCTAssertEqual(unavailable.facts, first.facts)
        XCTAssertEqual(unavailable.contentRevision, 0)
        XCTAssertEqual(unavailable.observation.coverage, .unavailable)
    }

    func testIdleRefreshWithLaterIntervalEndReusesPublishedFacts() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")
        let firstInterval = try fixture.interval(
            end: "2026-07-28T12:00:00Z"
        )
        let laterInterval = try fixture.interval(
            end: "2026-07-28T13:00:00Z"
        )

        let first = await collector.refresh(interval: firstInterval)
        let idle = await collector.refresh(interval: laterInterval)

        XCTAssertEqual(idle.bytesRead, 0)
        XCTAssertEqual(idle.contentRevision, first.contentRevision)
        XCTAssertEqual(idle.facts, first.facts)
    }

    func testChangingIntervalStartDoesNotReusePriorIntervalFacts() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")

        _ = await collector.refresh(interval: try fixture.interval())
        let later = await collector.refresh(
            interval: try fixture.interval(
                start: "2026-07-28T11:00:00Z"
            )
        )

        XCTAssertTrue(
            later.facts.filter {
                $0.key == .token && $0.availability == .available
            }.isEmpty
        )
        XCTAssertEqual(later.bytesRead, 0)
    }

    func testRestartDoesNotLoadPersistedFactsOutsideTheCurrentInterval() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "past-task",
            lines: [
                fixture.session(threadID: "past-task", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let past = try fixture.interval()
        let first = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await first.selectPartition("stable-account")
        _ = await first.refresh(interval: past)

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let current = try fixture.interval(
            start: "2026-08-04T00:00:00Z",
            end: "2026-08-05T00:00:00Z"
        )
        let collection = await restarted.refresh(interval: current)

        XCTAssertEqual(collection.bytesRead, 0)
        XCTAssertTrue(collection.facts.isEmpty)
        XCTAssertEqual(collection.observation.coverage, .high)
    }

    func testOversizedMetadataIsIgnoredAndRolloutIsRebuilt() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let first = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await first.selectPartition("stable-account")
        let interval = try fixture.interval()
        _ = await first.refresh(interval: interval)
        let partitionDirectory = stateDirectory.appendingPathComponent(
            "stable-account",
            isDirectory: true
        )
        let metadata = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: partitionDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
        try Data(repeating: 0, count: 1_048_577).write(
            to: metadata,
            options: .atomic
        )

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let rebuilt = await restarted.refresh(interval: interval)

        XCTAssertGreaterThan(rebuilt.bytesRead, 0)
        XCTAssertEqual(
            rebuilt.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta),
            [500]
        )
        XCTAssertEqual(
            rebuilt.observation.reason,
            "Saved local activity could not be read"
        )
    }

    func testChangingIntervalsReloadsPersistedFactsWithoutRescanningRollout() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "past-task",
            lines: [
                fixture.session(threadID: "past-task", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")
        let past = try fixture.interval()
        let first = await collector.refresh(interval: past)
        let current = try fixture.interval(
            start: "2026-08-04T00:00:00Z",
            end: "2026-08-05T00:00:00Z"
        )

        let empty = await collector.refresh(interval: current)
        let restored = await collector.refresh(interval: past)

        XCTAssertTrue(empty.facts.isEmpty)
        XCTAssertEqual(restored.facts, first.facts)
        XCTAssertEqual(restored.bytesRead, 0)
        XCTAssertNotEqual(empty.contentRevision, first.contentRevision)
        XCTAssertNotEqual(restored.contentRevision, empty.contentRevision)
    }

    func testCorruptPersistedFactsRebuildFromTheRollout() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let first = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await first.selectPartition("stable-account")
        let interval = try fixture.interval()
        _ = await first.refresh(interval: interval)
        let partitionDirectory = stateDirectory.appendingPathComponent(
            "stable-account",
            isDirectory: true
        )
        let factsFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: partitionDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasSuffix(".facts.jsonl") }
        )
        try fixture.append("{not-json}", to: factsFile)

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let rebuilt = await restarted.refresh(interval: interval)

        XCTAssertGreaterThan(rebuilt.bytesRead, 0)
        XCTAssertEqual(
            rebuilt.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500]
        )
        XCTAssertEqual(rebuilt.observation.coverage, .high)
    }

    func testOversizedPersistedFactRebuildsFromTheRollout() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let first = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await first.selectPartition("stable-account")
        let interval = try fixture.interval()
        _ = await first.refresh(interval: interval)
        let partition = stateDirectory.appendingPathComponent("stable-account")
        let factsFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: partition,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasSuffix(".facts.jsonl") }
        )
        let firstLine = try XCTUnwrap(
            String(contentsOf: factsFile, encoding: .utf8)
                .split(separator: "\n").first
        )
        let padding = String(
            repeating: "x",
            count: BoundedJSONLReader.maximumRecordBytes
        )
        let oversized = firstLine.replacingOccurrences(
            of: "{",
            with: #"{"padding":"\#(padding)","#,
            options: [.anchored]
        ) + "\n"
        try Data(oversized.utf8).write(to: factsFile)

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let restored = await restarted.refresh(interval: interval)

        XCTAssertEqual(
            restored.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta),
            [500]
        )
        XCTAssertGreaterThan(restored.bytesRead, 0)
    }

    func testDeletedHistoryDoesNotReturnOnTheNextRefreshOrRestart() async throws {
        let fixture = try CollectorFixture()
        let rollout = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        let before = await collector.refresh(interval: interval)
        let cutoff = try XCTUnwrap(
            ISO8601DateFormatter().date(
                from: "2026-07-28T10:01:30Z"
            )
        )

        try await collector.deleteHistory(at: cutoff)
        let afterDelete = await collector.refresh(interval: interval)
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let afterRestart = await restarted.refresh(interval: interval)
        try fixture.append(
            fixture.tokens(total: 800, ordinal: 3, minute: 3),
            to: rollout
        )
        let newActivity = await restarted.refresh(interval: interval)
        try await restarted.rebuildHistory()
        let rebuilt = await restarted.refresh(interval: interval)

        XCTAssertEqual(
            before.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500]
        )
        XCTAssertTrue(
            afterDelete.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta).isEmpty
        )
        XCTAssertTrue(
            afterRestart.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta).isEmpty
        )
        XCTAssertEqual(
            newActivity.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta),
            [200]
        )
        XCTAssertEqual(
            rebuilt.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta),
            [500, 200]
        )
    }

    func testDeleteRequiresADurableMarkerBeforeClearingMemory() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let blockedParent = fixture.root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParent)
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: blockedParent.appendingPathComponent("state")
        )
        let interval = try fixture.interval()
        let before = await collector.refresh(interval: interval)
        XCTAssertEqual(
            before.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500]
        )

        do {
            try await collector.deleteHistory(
                at: Date(timeIntervalSince1970: 1_900_000)
            )
            XCTFail("Deletion should fail when its marker cannot be saved")
        } catch {
            let pending = await collector.hasPendingHistoryDeletion()
            XCTAssertTrue(pending)
        }
        let whilePending = await collector.refresh(interval: interval)
        XCTAssertTrue(whilePending.facts.isEmpty)
        XCTAssertEqual(
            whilePending.observation.reason,
            "Analytics history deletion is pending"
        )
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(
            at: blockedParent,
            withIntermediateDirectories: true
        )

        try await collector.retryHistoryDeletion()

        let pendingAfterRetry = await collector.hasPendingHistoryDeletion()
        XCTAssertFalse(pendingAfterRetry)
    }

    func testCutoffFiltersStaleFactsIfCleanupWasInterrupted() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let partitionDirectory = stateDirectory.appendingPathComponent(
            "stable-account",
            isDirectory: true
        )
        let backup = fixture.root.appendingPathComponent(
            "stale-cache",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        _ = await collector.refresh(interval: interval)
        try FileManager.default.copyItem(at: partitionDirectory, to: backup)
        let cutoff = try XCTUnwrap(
            ISO8601DateFormatter().date(
                from: "2026-07-28T10:02:30Z"
            )
        )
        try await collector.deleteHistory(at: cutoff)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: backup, to: partitionDirectory)

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let result = await restarted.refresh(interval: interval)

        XCTAssertTrue(
            result.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta).isEmpty
        )
    }

    func testCorruptDeletionMarkerFailsClosedAfterRestart() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        _ = await collector.refresh(interval: interval)
        try await collector.deleteHistory(
            at: Date(timeIntervalSince1970: 1_785_232_950)
        )
        let marker = fixture.root.appendingPathComponent(
            ".collector-state-deletion.json"
        )
        try Data("{bad-json}".utf8).write(to: marker, options: .atomic)

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let result = await restarted.refresh(interval: interval)

        XCTAssertTrue(
            result.facts.filter { $0.key == .token }
                .compactMap(\.numericDelta).isEmpty
        )
        XCTAssertEqual(result.observation.coverage, .unavailable)
        XCTAssertEqual(
            result.observation.reason,
            "Saved deletion state could not be read"
        )
        let pending = await restarted.hasPendingHistoryDeletion()
        XCTAssertTrue(pending)
    }

    func testAccountSwitchDiscardsAnOlderSuspendedRefresh() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent(
            "collector-state",
            isDirectory: true
        )
        let delay = ProjectionDelay()
        let source = ReadOnlyThreadProjectionSource { _ in
            await delay.response()
        }
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory,
            projectionSource: source
        )
        await collector.selectPartition("first-account")
        let refresh = Task {
            await collector.refresh(interval: try fixture.interval())
        }
        await delay.waitUntilStarted()

        await collector.selectPartition("second-account")
        await delay.release(
            Data(#"{"result":{"data":[],"nextCursor":null}}"#.utf8)
        )
        let stale = try await refresh.value

        XCTAssertEqual(stale.observation.coverage, .unavailable)
        XCTAssertTrue(stale.facts.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: stateDirectory.appendingPathComponent(
                    "second-account",
                    isDirectory: true
                ).path
            )
        )
    }

    func testCancelledProjectionReadDoesNotScanOrSaveRollouts() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let delay = CancellableProjectionDelay()
        let source = ReadOnlyThreadProjectionSource { _ in
            try await delay.response()
        }
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory,
            projectionSource: source
        )
        await collector.selectPartition("stable-account")
        let refresh = Task {
            await collector.refresh(interval: try fixture.interval())
        }
        await delay.waitUntilStarted()

        refresh.cancel()
        let result = try await refresh.value

        XCTAssertEqual(result.observation.coverage, .unavailable)
        XCTAssertTrue(result.facts.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateDirectory.path)
        )
    }

    func testDurableWriteFailureLowersCoverage() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let blockedStatePath = fixture.root.appendingPathComponent(
            "not-a-directory"
        )
        try Data("blocked".utf8).write(to: blockedStatePath)
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: blockedStatePath
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refresh(interval: try fixture.interval())

        XCTAssertEqual(result.observation.coverage, .low)
        XCTAssertEqual(
            result.observation.reason,
            "Local activity could not be saved"
        )
        XCTAssertEqual(
            result.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500]
        )
    }

    func testResumableRestoreKeepsFactsFromEveryCandidateFile() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "older-task",
            lines: [
                fixture.session(threadID: "older-task", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        var newerLines = [
            fixture.session(threadID: "newer-task", ordinal: 0)
        ]
        newerLines.reserveCapacity(10_101)
        for ordinal in 1 ... 10_100 {
            newerLines.append(
                fixture.tokens(total: ordinal * 100, ordinal: ordinal, minute: 1)
            )
        }
        _ = try fixture.rollout(
            day: "2026/07/29",
            threadID: "newer-task",
            lines: newerLines
        )
        let interval = try fixture.interval(
            end: "2026-07-30T00:00:00Z"
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let first = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await first.selectPartition("stable-account")
        for _ in 0 ..< 10 {
            _ = await first.refresh(interval: interval)
            if await first.hasPendingImport() == false { break }
        }
        let firstPending = await first.hasPendingImport()
        XCTAssertFalse(firstPending)

        let failedProjectionSource = ReadOnlyThreadProjectionSource { _ in
            throw CocoaError(.fileReadUnknown)
        }
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory,
            projectionSource: failedProjectionSource
        )
        await restarted.selectPartition("stable-account")
        let narrowInterval = try fixture.interval(
            start: "2026-07-28T11:00:00Z",
            end: "2026-07-30T00:00:00Z"
        )
        var restored = await restarted.refresh(interval: narrowInterval)
        let firstRestoreRevision = restored.contentRevision
        let pendingAfterFirstRestore = await restarted.hasPendingImport()
        XCTAssertTrue(pendingAfterFirstRestore)
        for _ in 0 ..< 10 {
            guard await restarted.hasPendingImport() else { break }
            restored = await restarted.refresh(
                interval: interval,
                refreshMetadata: false
            )
        }

        let pendingAfterRestore = await restarted.hasPendingImport()
        XCTAssertFalse(pendingAfterRestore)
        XCTAssertNotEqual(restored.contentRevision, firstRestoreRevision)
        XCTAssertEqual(
            restored.observation.reason,
            "Local task discovery is incomplete"
        )
        XCTAssertEqual(
            restored.facts
                .filter { $0.key == .token }
                .compactMap(\.numericDelta)
                .reduce(0, +),
            1_010_400
        )
    }

    func testNewerRefreshSupersedesASuspendedRefresh() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let delay = SupersededProjectionDelay()
        let source = ReadOnlyThreadProjectionSource { request in
            await delay.response(to: request)
        }
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state"),
            projectionSource: source
        )
        let interval = try fixture.interval()
        let stale = Task {
            await collector.refresh(interval: interval)
        }
        await delay.waitUntilListStarted()

        let latest = await collector.refresh(
            interval: interval,
            refreshMetadata: false
        )
        await delay.releaseList()
        let superseded = await stale.value
        let idle = await collector.refresh(
            interval: interval,
            refreshMetadata: false
        )

        XCTAssertEqual(latest.facts, idle.facts)
        XCTAssertEqual(
            latest.facts.filter { $0.key == .token }.compactMap(\.numericDelta),
            [500]
        )
        XCTAssertEqual(superseded.observation.coverage, .unavailable)
        let pending = await collector.hasPendingImport()
        XCTAssertFalse(pending)
    }

    func testLowerCoverageDoesNotChangeTheFactCacheRevision() {
        let collection = LocalActivityCollection(
            facts: [],
            projections: [],
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: Date(timeIntervalSince1970: 100)
            ),
            bytesRead: 0,
            contentRevision: 7
        )

        XCTAssertEqual(
            collection.loweringCoverage("Identity unavailable").contentRevision,
            7
        )
    }

    func testStoredTokenActivityStreamsLargeLegacyFactsAcrossRestartAndCutoff()
        async throws
    {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let interval = try fixture.interval()
        let seed = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await seed.selectPartition("stable-account")
        _ = await seed.refresh(
            interval: interval,
            observedAt: interval.start.addingTimeInterval(60)
        )
        let partition = stateDirectory.appendingPathComponent("stable-account")
        let factsFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: partition,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasSuffix(".facts.jsonl") }
        )
        let template = try XCTUnwrap(
            String(contentsOf: factsFile, encoding: .utf8)
                .split(separator: "\n")
                .compactMap {
                    try? JSONDecoder().decode(
                        LocalActivityFact.self,
                        from: Data($0.utf8)
                    )
                }
                .first { $0.key == .token }
        )
        let formatter = ISO8601DateFormatter()
        let cutoff = try XCTUnwrap(
            formatter.date(from: "2026-07-28T10:01:30Z")
        )
        let firstRetained = try XCTUnwrap(
            formatter.date(from: "2026-07-28T10:02:00Z")
        )
        let generation = template.source.sourceGeneration
        let tokenLine: (String, Date, Int64, String) -> String = {
            eventID, date, delta, unusedPayload in
            """
            {"key":"token","availability":"available","numericDelta":\(delta),"reason":null,"eventID":"\(eventID)","eventTimestamp":"\(formatter.string(from: date))","source":{"sourceGeneration":\(generation)},"value":{"unusedPayload":"\(unusedPayload)"}}
            """
        }
        var legacy = Data()
        legacy.append(
            Data(
                tokenLine(
                    "before-cutoff",
                    cutoff.addingTimeInterval(-30),
                    99,
                    ""
                ).utf8
            )
        )
        legacy.append(0x0A)
        legacy.append(
            Data(
                tokenLine(
                    "first-retained",
                    firstRetained,
                    500,
                    String(repeating: "x", count: 800_000)
                ).utf8
            )
        )
        legacy.append(0x0A)
        for index in 1 ... 9_999 {
            legacy.append(
                Data(
                    tokenLine(
                        "stored-\(index)",
                        firstRetained.addingTimeInterval(
                            TimeInterval(index)
                        ),
                        1,
                        ""
                    ).utf8
                )
            )
            legacy.append(0x0A)
        }
        try legacy.write(to: factsFile)
        struct TestDeletionMarker: Encodable {
            let version: Int
            let cutoff: Date
            let cleanupPending: Bool
        }
        let marker = stateDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(stateDirectory.lastPathComponent)-deletion.json"
            )
        try JSONEncoder().encode(
            TestDeletionMarker(
                version: 1,
                cutoff: cutoff,
                cleanupPending: false
            )
        ).write(to: marker)

        let first = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await first.selectPartition("stable-account")
        let partial = await first.refreshStoredTokenActivity(
            interval: interval
        )

        XCTAssertTrue(partial.importPending)
        XCTAssertNil(partial.snapshot.tokens)
        await first.selectPartition("other-account")

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        var completed = await restarted.refreshStoredTokenActivity(
            interval: interval
        )
        for _ in 0 ..< 5 where completed.importPending {
            completed = await restarted.refreshStoredTokenActivity(
                interval: interval
            )
        }

        XCTAssertFalse(completed.importPending)
        XCTAssertEqual(completed.snapshot.tokens, 9_999)
        XCTAssertEqual(completed.snapshot.points.last?.tokens, 9_999)
        XCTAssertLessThanOrEqual(completed.snapshot.points.count, 1_000)
    }

    func testStoredTokenActivityRebuildsAnOlderDerivedSchema() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let interval = try fixture.interval()
        let seed = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await seed.selectPartition("stable-account")
        _ = await seed.refresh(
            interval: interval,
            observedAt: interval.start.addingTimeInterval(60)
        )
        let database = stateDirectory
            .appendingPathComponent("stable-account")
            .appendingPathComponent("local-activity-v1.sqlite3")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                connection,
                "PRAGMA user_version = 1",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close_v2(connection)

        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        var result = await collector.refreshStoredTokenActivity(
            interval: interval
        )
        while result.importPending {
            result = await collector.refreshStoredTokenActivity(
                interval: interval
            )
        }

        XCTAssertEqual(result.snapshot.tokens, 500)
    }

    func testStoredTokenActivitySkipsSavedSourcesOutsideTheRange() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let interval = try fixture.interval()
        let seed = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await seed.selectPartition("stable-account")
        _ = await seed.refresh(interval: interval)
        let partition = stateDirectory.appendingPathComponent("stable-account")
        let entries = try FileManager.default.contentsOfDirectory(
            at: partition,
            includingPropertiesForKeys: nil
        )
        let metadata = try XCTUnwrap(
            entries.first {
                $0.pathExtension == "json"
                    && !$0.lastPathComponent.hasSuffix(".facts.jsonl")
            }
        )
        let facts = partition.appendingPathComponent(
            metadata.deletingPathExtension().lastPathComponent
                + ".facts.jsonl"
        )
        let oldMetadata = partition.appendingPathComponent("old.json")
        let oldFacts = partition.appendingPathComponent("old.facts.jsonl")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadata))
                as? [String: Any]
        )
        object["activityStart"] = 0.0
        object["activityEnd"] = 1.0
        try JSONSerialization.data(withJSONObject: object)
            .write(to: oldMetadata)
        try FileManager.default.copyItem(at: facts, to: oldFacts)

        let collector = LocalActivityCollector(
            rootDirectory: fixture.root.appendingPathComponent("empty"),
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        var result = await collector.refreshStoredTokenActivity(
            interval: interval
        )
        while result.importPending {
            result = await collector.refreshStoredTokenActivity(
                interval: interval
            )
        }

        let database = partition.appendingPathComponent(
            "local-activity-v1.sqlite3"
        )
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        defer { sqlite3_close_v2(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                connection,
                "SELECT COUNT(*) FROM source WHERE is_active = 1",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testStoredTokenActivityKeepsPersistedMalformedCoverage() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                #"{"timestamp":"2026-07-28T10:01:30Z","type":"event_msg""#,
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let interval = try fixture.interval()
        let seed = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await seed.selectPartition("stable-account")
        let seeded = await seed.refresh(interval: interval)
        XCTAssertEqual(
            seeded.observation.reason,
            "Some local diagnostic records could not be read"
        )
        let emptyRoot = fixture.root.appendingPathComponent(
            "empty-rollouts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: emptyRoot,
            withIntermediateDirectories: true
        )
        let restarted = LocalActivityCollector(
            rootDirectory: emptyRoot,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")

        var stored = await restarted.refreshStoredTokenActivity(
            interval: interval
        )
        for _ in 0 ..< 10 where stored.importPending {
            stored = await restarted.refreshStoredTokenActivity(
                interval: interval
            )
        }

        XCTAssertEqual(stored.snapshot.tokens, 500)
        XCTAssertEqual(stored.snapshot.coverage, .low)
        XCTAssertEqual(
            stored.snapshot.reason,
            "Some local diagnostic records could not be read"
        )
    }

    func testStoredTokenActivityKeepsPersistedContinuityGap() async throws {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let interval = try fixture.interval()
        let seed = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await seed.selectPartition("stable-account")
        _ = await seed.refresh(
            interval: interval,
            observedAt: interval.start.addingTimeInterval(60)
        )
        var replacement =
            fixture.session(threadID: "task-1", ordinal: 0) + "\n"
        for ordinal in 1 ... 5_000 {
            replacement +=
                #"{"timestamp":"2026-07-28T10:01:00.000Z","ordinal":\#(ordinal),"type":"compacted","payload":{}}"#
                + "\n"
        }
        replacement += fixture.tokens(
            total: 900,
            ordinal: 5_001,
            minute: 3
        ) + "\n"
        try Data(replacement.utf8).write(to: file, options: .atomic)
        let changed = await seed.refresh(
            interval: interval,
            observedAt: interval.start.addingTimeInterval(180)
        )
        XCTAssertEqual(
            changed.observation.reason,
            "Local task record continuity changed"
        )
        let emptyRoot = fixture.root.appendingPathComponent(
            "empty-rollouts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: emptyRoot,
            withIntermediateDirectories: true
        )
        let restarted = LocalActivityCollector(
            rootDirectory: emptyRoot,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")

        var stored = await restarted.refreshStoredTokenActivity(
            interval: interval
        )
        for _ in 0 ..< 10 where stored.importPending {
            stored = await restarted.refreshStoredTokenActivity(
                interval: interval
            )
        }

        XCTAssertEqual(stored.snapshot.coverage, .low)
        XCTAssertEqual(
            stored.snapshot.reason,
            "Local task record continuity changed"
        )
    }

    func testStoredTokenActivityRetriesEveryFactAfterASQLiteWriteFailure()
        async throws
    {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        let first = await collector.refreshStoredTokenActivity(
            interval: interval
        )
        XCTAssertEqual(first.snapshot.tokens, 500)
        let partition = stateDirectory.appendingPathComponent(
            "stable-account",
            isDirectory: true
        )
        let database = partition.appendingPathComponent(
            "local-activity-v1.sqlite3"
        )
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &lock), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil),
            SQLITE_OK
        )
        defer {
            sqlite3_exec(lock, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(lock)
        }
        try fixture.append(
            fixture.tokens(total: 800, ordinal: 3, minute: 3),
            to: file
        )
        let failed = await collector.refreshStoredTokenActivity(
            interval: interval
        )
        XCTAssertEqual(failed.snapshot.coverage, .unavailable)
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close_v2(lock), SQLITE_OK)
        lock = nil
        try fixture.append(
            fixture.tokens(total: 1_000, ordinal: 4, minute: 4),
            to: file
        )

        let recovered = await collector.refreshStoredTokenActivity(
            interval: interval
        )
        let unchanged = await collector.refreshStoredTokenActivity(
            interval: interval
        )

        XCTAssertEqual(recovered.snapshot.tokens, 900)
        XCTAssertEqual(unchanged.snapshot.tokens, 900)
    }

    func testCancelledStoredTokenRefreshStopsInsteadOfReportingAReadFailure()
        async throws
    {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let seed = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await seed.selectPartition("stable-account")
        _ = await seed.refresh(interval: try fixture.interval())
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        let refresh = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await collector.refreshStoredTokenActivity(
                interval: interval
            )
        }
        refresh.cancel()

        let result = await refresh.value

        XCTAssertEqual(result.snapshot.coverage, .unavailable)
        XCTAssertEqual(
            result.snapshot.reason,
            "Local activity read was cancelled"
        )
    }

    func testStoredTokenActivityTailsOnlyNewRolloutBytesAfterRestart()
        async throws
    {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let interval = try fixture.interval()
        do {
            let seed = LocalActivityCollector(
                rootDirectory: fixture.root,
                stateDirectory: stateDirectory
            )
            await seed.selectPartition("stable-account")
            _ = await seed.refresh(interval: interval)
            let importing = await seed.refreshStoredTokenActivity(
                interval: interval
            )
            XCTAssertTrue(importing.importPending)
            let migrated = await seed.refreshStoredTokenActivity(
                interval: interval
            )
            XCTAssertEqual(migrated.snapshot.tokens, 500)
        }
        try fixture.append(
            fixture.tokens(total: 800, ordinal: 3, minute: 3),
            to: file
        )
        let projectionRequests = CollectorProjectionRequests()
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory,
            projectionSource: ReadOnlyThreadProjectionSource { request in
                await projectionRequests.record(request)
                throw CocoaError(.fileReadUnknown)
            }
        )
        await restarted.selectPartition("stable-account")

        let updated = await restarted.refreshStoredTokenActivity(
            interval: interval
        )
        let unchanged = await restarted.refreshStoredTokenActivity(
            interval: interval
        )
        let requests = await projectionRequests.values

        XCTAssertEqual(updated.snapshot.tokens, 700)
        XCTAssertGreaterThan(updated.bytesRead, 0)
        XCTAssertEqual(unchanged.snapshot.tokens, 700)
        XCTAssertEqual(unchanged.bytesRead, 0)
        XCTAssertEqual(requests, [])
    }

    func testStoredTokenActivityBootstrapsFromRolloutWithoutFullRefresh()
        async throws
    {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let projectionRequests = CollectorProjectionRequests()
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state"),
            projectionSource: ReadOnlyThreadProjectionSource { request in
                await projectionRequests.record(request)
                throw CocoaError(.fileReadUnknown)
            }
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refreshStoredTokenActivity(
            interval: try fixture.interval()
        )
        let requests = await projectionRequests.values

        XCTAssertEqual(result.snapshot.tokens, 500)
        XCTAssertGreaterThan(result.bytesRead, 0)
        XCTAssertEqual(requests, [])
    }

    func testStoredTokenActivityImportsRawRolloutDirectlyAcrossRestart()
        async throws
    {
        let fixture = try CollectorFixture()
        var lines = [
            fixture.session(threadID: "task-1", ordinal: 0),
            fixture.tokens(total: 100, ordinal: 1, minute: 1)
        ]
        lines.append(
            contentsOf: (2 ..< 10_000).map {
                #"{"timestamp":"2026-07-28T10:01:30.000Z","ordinal":\#($0),"type":"compacted","payload":{}}"#
            }
        )
        lines.append(
            fixture.tokens(total: 600, ordinal: 10_000, minute: 2)
        )
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: lines
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let partition = stateDirectory.appendingPathComponent(
            "stable-account"
        )
        let interval = try fixture.interval()

        do {
            let collector = LocalActivityCollector(
                rootDirectory: fixture.root,
                stateDirectory: stateDirectory
            )
            await collector.selectPartition("stable-account")
            let first = await collector.refreshStoredTokenActivity(
                interval: interval
            )

            XCTAssertTrue(first.importPending)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: partition.appendingPathComponent(
                        "local-activity-v1.sqlite3"
                    ).path
                )
            )
            XCTAssertEqual(try storedFactSidecars(in: partition), [])
        }

        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        var completed = await restarted.refreshStoredTokenActivity(
            interval: interval
        )
        for _ in 0 ..< 3 where completed.importPending {
            completed = await restarted.refreshStoredTokenActivity(
                interval: interval
            )
        }

        XCTAssertFalse(completed.importPending)
        XCTAssertEqual(completed.snapshot.tokens, 500)
        XCTAssertEqual(try storedFactSidecars(in: partition), [])
    }

    func testStoredTokenActivityCountsOnlyAChildTasksOwnCopiedHistory()
        async throws
    {
        let fixture = try CollectorFixture()
        let child = "019fb303-6225-7592-96dd-15504bb96fbd"
        let parent = "019fa3d9-328e-7ca0-8d40-e61dec66d483"
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: child,
            lines: [
                #"{"timestamp":"2026-07-28T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"\#(child)","parent_thread_id":"\#(parent)","cli_version":"0.145.0"}}"#,
                #"{"timestamp":"2026-07-28T10:00:00.100Z","ordinal":1,"type":"session_meta","payload":{"id":"\#(parent)","cli_version":"0.145.0"}}"#,
                #"{"timestamp":"2026-07-28T10:00:00.200Z","ordinal":2,"type":"event_msg","payload":{"type":"task_started","turn_id":"019fa3da-0000-7000-8000-000000000000"}}"#,
                #"{"timestamp":"2026-07-28T10:00:00.300Z","ordinal":3,"type":"event_msg","payload":{"type":"task_started","turn_id":"e30f1c44-bcc4-4b16-ab4a-576ed6b5aa46"}}"#,
                fixture.tokens(total: 100, ordinal: 4, minute: 1),
                fixture.tokens(total: 600, ordinal: 5, minute: 2),
                #"{"timestamp":"2026-07-28T10:03:00.000Z","ordinal":6,"type":"event_msg","payload":{"type":"task_started","turn_id":"019fb304-0000-7000-8000-000000000000"}}"#,
                #"{"timestamp":"2026-07-28T10:04:00.000Z","ordinal":7,"type":"turn_context","payload":{"turn_id":"019fb304-0000-7000-8000-000000000000","model":"gpt-5.6","effort":"high"}}"#,
                #"{"timestamp":"2026-07-28T10:05:00.000Z","ordinal":8,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":700},"last_token_usage":{"total_tokens":100}}}}"#,
                #"{"timestamp":"2026-07-28T10:06:00.000Z","ordinal":9,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":900},"last_token_usage":{"total_tokens":200}}}}"#
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refreshStoredTokenActivity(
            interval: try fixture.interval()
        )

        XCTAssertEqual(result.snapshot.tokens, 300)
        XCTAssertEqual(result.filterOptions.models, ["gpt-5.6"])
        XCTAssertEqual(result.filterOptions.reasoningLevels, ["high"])
    }

    func testStoredTokenActivityDeduplicatesAResumedTaskCopy()
        async throws
    {
        let fixture = try CollectorFixture()
        let task = "019fb303-6225-7592-96dd-15504bb96fbd"
        let turn = "019fb304-0000-7000-8000-000000000000"
        let lines = [
            #"{"timestamp":"2026-07-28T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(task)","cli_version":"0.145.0"}}"#,
            #"{"timestamp":"2026-07-28T10:00:30.000Z","type":"turn_context","payload":{"turn_id":"\#(turn)","model":"gpt-5.6","effort":"high"}}"#,
            #"{"timestamp":"2026-07-28T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#,
            #"{"timestamp":"2026-07-28T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":600}}}}"#
        ]
        _ = try fixture.rollout(
            day: "2026/07/27",
            threadID: task,
            lines: lines
        )
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: task,
            lines: lines
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refreshStoredTokenActivity(
            interval: try fixture.interval()
        )

        XCTAssertEqual(result.snapshot.tokens, 500)
    }

    func testStoredTokenActivityBuildsProjectFiltersFromRolloutMetadata()
        async throws
    {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                """
                {"timestamp":"2026-07-28T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-1","cli_version":"0.145.0","cwd":"/work/client-project"}}
                """,
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refreshStoredTokenActivity(
            interval: try fixture.interval()
        )

        XCTAssertEqual(result.filterOptions.projects, ["client-project"])
        XCTAssertEqual(result.filterOptions.taskTrees, ["task-1"])
    }

    func testStoredTokenActivityAdvancesPastOneAcceptedLargeRecord()
        async throws
    {
        let fixture = try CollectorFixture()
        let padding = String(repeating: "x", count: 5 * 1_024 * 1_024)
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                #"{"timestamp":"2026-07-28T10:00:30.000Z","ordinal":1,"type":"compacted","payload":{"padding":"\#(padding)"}}"#,
                fixture.tokens(total: 100, ordinal: 2, minute: 1),
                fixture.tokens(total: 600, ordinal: 3, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refreshStoredTokenActivity(
            interval: try fixture.interval()
        )

        XCTAssertFalse(result.importPending)
        XCTAssertEqual(result.snapshot.tokens, 500)
    }

    func testStoredTokenActivityFindsAContinuingRolloutFromPreviousDay()
        async throws
    {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/27",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refreshStoredTokenActivity(
            interval: try fixture.interval()
        )

        XCTAssertEqual(result.snapshot.tokens, 500)
    }

    func testStoredTokenActivityFindsARecentlyUpdatedOlderRollout()
        async throws
    {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/20",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refreshStoredTokenActivity(
            interval: try fixture.interval()
        )

        XCTAssertEqual(result.snapshot.tokens, 500)
    }

    func testStoredTokenActivityDiscoversTheWholeSelectedRange() async throws {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/06/15",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refreshStoredTokenActivity(
            interval: try fixture.interval(
                start: "2026-06-01T00:00:00Z",
                end: "2026-07-29T00:00:00Z"
            )
        )

        XCTAssertEqual(result.snapshot.tokens, 500)
    }

    func testStoredTokenActivityKeepsLastActiveFactsAfterContinuityChange()
        async throws
    {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let interval = try fixture.interval()
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        let first = await collector.refreshStoredTokenActivity(
            interval: interval
        )
        try Data(
            (
                fixture.session(threadID: "task-1", ordinal: 0)
                    + "\n"
                    + fixture.tokens(total: 900, ordinal: 3, minute: 3)
                    + "\n"
            ).utf8
        ).write(to: file, options: .atomic)

        let changed = await collector.refreshStoredTokenActivity(
            interval: interval
        )
        let unchanged = await collector.refreshStoredTokenActivity(
            interval: interval
        )
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")
        let afterRestart = await restarted.refreshStoredTokenActivity(
            interval: interval
        )

        XCTAssertEqual(first.snapshot.tokens, 500)
        XCTAssertEqual(changed.snapshot.tokens, 500)
        XCTAssertEqual(changed.snapshot.coverage, .low)
        XCTAssertEqual(
            changed.snapshot.reason,
            "Local task record continuity changed"
        )
        XCTAssertFalse(unchanged.importPending)
        XCTAssertEqual(unchanged.bytesRead, 0)
        XCTAssertFalse(afterRestart.importPending)
        XCTAssertEqual(afterRestart.bytesRead, 0)
        XCTAssertEqual(afterRestart.snapshot.tokens, 500)
    }

    func testStoredTokenActivityRebuildsSQLiteFromLegacyAfterLiveAppend()
        async throws
    {
        let fixture = try CollectorFixture()
        let file = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let stateDirectory = fixture.root.appendingPathComponent("state")
        let interval = try fixture.interval()
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await collector.selectPartition("stable-account")
        _ = await collector.refreshStoredTokenActivity(interval: interval)
        try fixture.append(
            fixture.tokens(total: 800, ordinal: 3, minute: 3),
            to: file
        )
        let updated = await collector.refreshStoredTokenActivity(
            interval: interval
        )
        await collector.selectPartition("other-account")
        let partition = stateDirectory.appendingPathComponent("stable-account")
        for name in [
            "local-activity-v1.sqlite3",
            "local-activity-v1.sqlite3-wal",
            "local-activity-v1.sqlite3-shm",
            "local-activity-v1.sqlite3-journal"
        ] {
            let file = partition.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
        )
        await restarted.selectPartition("stable-account")

        var rebuilt = await restarted.refreshStoredTokenActivity(
            interval: interval
        )
        while rebuilt.importPending {
            rebuilt = await restarted.refreshStoredTokenActivity(
                interval: interval
            )
        }

        XCTAssertEqual(updated.snapshot.tokens, 700)
        XCTAssertEqual(rebuilt.snapshot.tokens, 700)
    }

    func testStoredTokenActivityNoChangeRefreshesReadNoRolloutBytes()
        async throws
    {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(threadID: "task-1", ordinal: 0),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")
        let interval = try fixture.interval()
        _ = await collector.refreshStoredTokenActivity(interval: interval)

        for _ in 0 ..< 10 {
            let unchanged = await collector.refreshStoredTokenActivity(
                interval: interval
            )
            XCTAssertEqual(unchanged.snapshot.tokens, 500)
            XCTAssertEqual(unchanged.bytesRead, 0)
        }
    }

    func testStoredTokenActivityWithoutSavedOrRolloutDataIsUnavailable()
        async throws
    {
        let fixture = try CollectorFixture()
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refreshStoredTokenActivity(
            interval: try fixture.interval()
        )

        XCTAssertEqual(result.snapshot.coverage, .unavailable)
        XCTAssertEqual(
            result.snapshot.reason,
            "No saved local activity is available"
        )
    }

    func testStoredTokenActivityLowersCoverageForUncheckedCLIVersion()
        async throws
    {
        let fixture = try CollectorFixture()
        _ = try fixture.rollout(
            day: "2026/07/28",
            threadID: "task-1",
            lines: [
                fixture.session(
                    threadID: "task-1",
                    ordinal: 0,
                    cliVersion: "0.146.0"
                ),
                fixture.tokens(total: 100, ordinal: 1, minute: 1),
                fixture.tokens(total: 600, ordinal: 2, minute: 2)
            ]
        )
        let collector = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: fixture.root.appendingPathComponent("state")
        )
        await collector.selectPartition("stable-account")

        let result = await collector.refreshStoredTokenActivity(
            interval: try fixture.interval()
        )

        XCTAssertEqual(result.snapshot.tokens, 500)
        XCTAssertEqual(result.snapshot.coverage, .low)
        XCTAssertEqual(
            result.snapshot.reason,
            "This Codex CLI version has not been checked"
        )
    }
}

private func storedFactSidecars(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasSuffix(".facts.jsonl") }
    .map(\.lastPathComponent)
    .sorted()
}

private actor CollectorProjectionRequests {
    private(set) var values: [ThreadProjectionReadRequest] = []

    func record(_ request: ThreadProjectionReadRequest) {
        values.append(request)
    }
}

private actor ParentProjectionResponses {
    private var listReads = 0

    func response(
        to request: ThreadProjectionReadRequest,
        rolloutPath: String
    ) throws -> Data {
        switch request {
        case .list(cursor: nil, _, _, _):
            listReads += 1
            if listReads > 1 {
                return Data(#"""
                {"result":{"data":[{
                  "id":"child",
                  "parentThreadId":"older-root",
                  "cliVersion":"0.145.0",
                  "cwd":"/synthetic/projects/atlas",
                  "path":"\#(rolloutPath)",
                  "createdAt":1785232800,
                  "updatedAt":1785232920
                },{
                  "id":"older-root",
                  "parentThreadId":null,
                  "cliVersion":"0.145.0",
                  "cwd":"/synthetic/projects/atlas",
                  "path":null,
                  "createdAt":1784628000,
                  "updatedAt":1784628000
                }],"nextCursor":null}}
                """#.utf8)
            }
            return Data(#"""
            {"result":{"data":[{
              "id":"child",
              "parentThreadId":"older-root",
              "cliVersion":"0.145.0",
              "cwd":"/synthetic/projects/atlas",
              "path":"\#(rolloutPath)",
              "createdAt":1785232800,
              "updatedAt":1785232920
            }],"nextCursor":null}}
            """#.utf8)
        case .read(threadID: "older-root", includeTurns: false):
            throw CocoaError(.fileReadCorruptFile)
        default:
            throw CocoaError(.fileReadUnknown)
        }
    }
}

private actor ProjectionDelay {
    private var started = false
    private var continuation: CheckedContinuation<Data, Never>?

    func response() async -> Data {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private actor CancellableProjectionDelay {
    private var started = false

    func response() async throws -> Data {
        started = true
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return Data()
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}

private actor SecondInstalledVersionDelay {
    private var requestCount = 0
    private var secondRequestStarted = false
    private var secondRequestContinuation: CheckedContinuation<String?, Never>?

    func response() async -> String? {
        requestCount += 1
        guard requestCount == 2 else { return "0.145.0" }
        secondRequestStarted = true
        return await withCheckedContinuation { continuation in
            secondRequestContinuation = continuation
        }
    }

    func waitUntilSecondRequest() async {
        while !secondRequestStarted {
            await Task.yield()
        }
    }

    func releaseSecondRequest() {
        secondRequestContinuation?.resume(returning: "0.145.0")
        secondRequestContinuation = nil
    }
}

private actor SupersededProjectionDelay {
    private var listStarted = false
    private var listContinuation: CheckedContinuation<Data, Never>?

    func response(to request: ThreadProjectionReadRequest) async -> Data {
        switch request {
        case .list:
            listStarted = true
            return await withCheckedContinuation { continuation in
                listContinuation = continuation
            }
        case let .read(threadID, _):
            return Data(#"""
            {"result":{"thread":{
              "id":"\#(threadID)",
              "parentThreadId":null,
              "cliVersion":"0.145.0",
              "cwd":"/synthetic/project",
              "createdAt":1785232800,
              "updatedAt":1785232920
            }}}
            """#.utf8)
        }
    }

    func waitUntilListStarted() async {
        while !listStarted {
            await Task.yield()
        }
    }

    func releaseList() {
        listContinuation?.resume(
            returning: Data(#"{"result":{"data":[],"nextCursor":null}}"#.utf8)
        )
        listContinuation = nil
    }
}

private final class CollectorFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func interval(
        start: String = "2026-07-28T00:00:00Z",
        end: String = "2026-07-29T00:00:00Z"
    ) throws -> DateInterval {
        let formatter = ISO8601DateFormatter()
        return DateInterval(
            start: try XCTUnwrap(formatter.date(from: start)),
            end: try XCTUnwrap(formatter.date(from: end))
        )
    }

    func rollout(
        day: String,
        threadID: String,
        lines: [String]
    ) throws -> URL {
        let directory = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent(
            "rollout-2026-07-28T10-00-00-\(threadID).jsonl"
        )
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }

    func append(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func session(
        threadID: String,
        ordinal: Int,
        cliVersion: String = "0.145.0"
    ) -> String {
        #"{"timestamp":"2026-07-28T10:00:00.000Z","ordinal":\#(ordinal),"type":"session_meta","payload":{"id":"\#(threadID)","cli_version":"\#(cliVersion)"}}"#
    }

    func tokens(total: Int, ordinal: Int, minute: Int) -> String {
        #"{"timestamp":"2026-07-28T10:\#(String(format: "%02d", minute)):00.000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)}}}}"#
    }
}
