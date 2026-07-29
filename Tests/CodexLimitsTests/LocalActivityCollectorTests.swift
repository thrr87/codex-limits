import XCTest
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
        let restarted = LocalActivityCollector(
            rootDirectory: fixture.root,
            stateDirectory: stateDirectory
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
        XCTAssertEqual(migrated["version"] as? Int, 6)
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
        _ = await collector.refresh(interval: interval)
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
        _ = await collector.refresh(interval: interval)
        let after = try Data(contentsOf: factsFile)

        XCTAssertTrue(after.starts(with: before))
        XCTAssertGreaterThan(after.count, before.count)
        XCTAssertLessThan(after.count - before.count, before.count)
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
