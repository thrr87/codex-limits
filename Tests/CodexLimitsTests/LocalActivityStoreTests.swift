import XCTest
import SQLite3
@testable import CodexLimits

final class LocalActivityStoreTests: XCTestCase {
    func testSchemaStoresACompactTokenIndexWithoutFactPayloads() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        store.close()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close_v2(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                connection,
                "SELECT name FROM pragma_table_info('token_fact') ORDER BY cid",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.append(String(cString: sqlite3_column_text(statement, 0)))
        }

        XCTAssertTrue(
            Set([
                "source_id",
                "event_id",
                "occurred_at",
                "numeric_delta",
                "task_id",
                "effective_model",
                "reasoning"
            ]).isSubset(of: Set(columns))
        )
        XCTAssertFalse(columns.contains("payload"))
        XCTAssertFalse(columns.contains("fact_json"))

        sqlite3_finalize(statement)
        statement = nil
        XCTAssertEqual(
            sqlite3_prepare_v2(
                connection,
                """
                SELECT EXISTS(
                    SELECT 1
                    FROM sqlite_master
                    WHERE type = 'table' AND name = 'token_event'
                )
                """,
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
    }

    func testAppendedTokenActivitySurvivesReopen() throws {
        let database = temporaryDatabase()
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        var store: LocalActivityStore? = try LocalActivityStore(fileURL: database)
        try store?.append(
            [tokenFact(id: "one", timestamp: 1_100, delta: 125)],
            to: source(key: "rollout")
        )
        store?.close()
        store = try LocalActivityStore(fileURL: database)

        let snapshot = try store?.tokenActivity(
            in: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        XCTAssertEqual(snapshot?.tokens, 125)
        XCTAssertEqual(snapshot?.points.map(\.tokens), [125])
        XCTAssertEqual(snapshot?.coverage, .high)
        store?.close()
    }

    func testTokenQueryUsesHalfOpenBoundsAndDeduplicatesEventsGlobally() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        try store.append(
            [
                tokenFact(id: "shared", timestamp: 1_100, delta: 900),
                tokenFact(id: "same-time", timestamp: 1_100, delta: 250),
                tokenFact(id: "at-end", timestamp: 2_000, delta: 500)
            ],
            to: source(key: "second")
        )
        try store.append(
            [
                tokenFact(id: "before", timestamp: 999, delta: 50),
                tokenFact(id: "at-start", timestamp: 1_000, delta: 100),
                tokenFact(id: "shared", timestamp: 1_100, delta: 200)
            ],
            to: source(key: "first")
        )
        try store.append(
            [tokenFact(id: "at-start", timestamp: 1_000, delta: 100)],
            to: source(key: "first")
        )

        let snapshot = try store.tokenActivity(
            in: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        XCTAssertEqual(snapshot.tokens, 550)
        XCTAssertEqual(snapshot.points.map(\.tokens), [100, 550])
        XCTAssertEqual(
            snapshot.points.map(\.date),
            [
                Date(timeIntervalSince1970: 1_000),
                Date(timeIntervalSince1970: 1_100)
            ]
        )
    }

    func testLaterFactForAnotherKeyOfTheSameEventIsNotDropped() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        let storedSource = source(key: "rollout")
        try store.append(
            [contextFact(id: "shared", timestamp: 1_100)],
            to: storedSource
        )
        try store.append(
            [tokenFact(id: "shared", timestamp: 1_100, delta: 100)],
            to: storedSource
        )
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(try tokens(in: store, interval: interval), 100)
    }

    func testUnavailableTokenFactDoesNotContributeToActivity() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        try store.append(
            [
                tokenFact(
                    id: "unavailable",
                    timestamp: 1_100,
                    delta: 900,
                    availability: .unavailable
                ),
                tokenFact(id: "available", timestamp: 1_200, delta: 100)
            ],
            to: source(key: "rollout")
        )
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(try tokens(in: store, interval: interval), 100)
    }

    func testReplacementStaysHiddenUntilActivationAndCanBeRolledBack() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        let storedSource = source(key: "rollout", generation: 7)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        try store.append(
            [tokenFact(id: "old", timestamp: 1_100, delta: 100, generation: 7)],
            to: storedSource
        )
        let replacement = try store.beginReplacement(for: storedSource)
        try store.appendReplacement(
            [tokenFact(id: "new", timestamp: 1_100, delta: 400, generation: 7)],
            to: storedSource,
            storeGeneration: replacement
        )

        XCTAssertEqual(
            try tokens(in: store, interval: interval),
            100
        )

        try store.activateReplacement(
            sourceKey: storedSource.key,
            storeGeneration: replacement
        )
        XCTAssertEqual(
            try tokens(in: store, interval: interval),
            400
        )

        let abandoned = try store.beginReplacement(for: storedSource)
        try store.appendReplacement(
            [tokenFact(id: "abandoned", timestamp: 1_100, delta: 900, generation: 7)],
            to: storedSource,
            storeGeneration: abandoned
        )
        try store.rollbackReplacement(
            sourceKey: storedSource.key,
            storeGeneration: abandoned
        )
        XCTAssertEqual(
            try tokens(in: store, interval: interval),
            400
        )
    }

    func testReplacementFallsBackToDuplicateFromAnotherActiveSource() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let preferred = source(key: "a")
        try store.append(
            [tokenFact(id: "shared", timestamp: 1_100, delta: 100)],
            to: preferred
        )
        try store.append(
            [tokenFact(id: "shared", timestamp: 1_100, delta: 200)],
            to: source(key: "b")
        )
        let replacement = try store.beginReplacement(for: preferred)
        try store.appendReplacement(
            [tokenFact(id: "new", timestamp: 1_200, delta: 50)],
            to: preferred,
            storeGeneration: replacement
        )

        try store.activateReplacement(
            sourceKey: preferred.key,
            storeGeneration: replacement
        )

        XCTAssertEqual(try tokens(in: store, interval: interval), 250)
    }

    func testIncompleteLegacyReplacementCannotBecomeActive() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        let active = source(key: "rollout", generation: 7)
        try store.append(
            [tokenFact(id: "old", timestamp: 1_100, delta: 100, generation: 7)],
            to: active
        )
        var importing = active
        importing.legacyDevice = 4
        importing.legacyInode = 8
        importing.legacySize = 1_024
        importing.legacyModificationDate = Date(timeIntervalSince1970: 900)
        importing.legacyOffset = 128
        importing.pendingFactJSON = Data("pending".utf8)
        let replacement = try store.beginReplacement(for: importing)
        try store.appendReplacement(
            [tokenFact(id: "new", timestamp: 1_100, delta: 400, generation: 7)],
            to: importing,
            storeGeneration: replacement
        )

        XCTAssertThrowsError(
            try store.activateReplacement(
                sourceKey: importing.key,
                storeGeneration: replacement
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalActivityStore.StoreError,
                .invalidSource
            )
        }

        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(try tokens(in: store, interval: interval), 100)

        importing.legacyOffset = importing.legacySize
        importing.pendingFactJSON = nil
        try store.appendReplacement(
            [],
            to: importing,
            storeGeneration: replacement
        )
        try store.activateReplacement(
            sourceKey: importing.key,
            storeGeneration: replacement
        )
        XCTAssertEqual(try tokens(in: store, interval: interval), 400)
    }

    func testTokenQueryKeepsExactTotalWithAtMostOneThousandPoints() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 3_000)
        )
        try store.append(
            (0..<1_501).map { index in
                tokenFact(
                    id: "event-\(index)",
                    timestamp: 1_001 + TimeInterval(index),
                    delta: 1
                )
            },
            to: source(key: "rollout")
        )

        let snapshot = try store.tokenActivity(
            in: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        XCTAssertEqual(snapshot.tokens, 1_501)
        XCTAssertLessThanOrEqual(snapshot.points.count, 1_000)
        XCTAssertEqual(snapshot.points.last?.tokens, 1_501)
    }

    func testUnboundedCounterLowersCoverageWithoutLosingKnownTokens() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        try store.append(
            [
                tokenFact(
                    id: "baseline",
                    timestamp: 1_100,
                    delta: nil,
                    reason: "segment-baseline"
                ),
                tokenFact(id: "known", timestamp: 1_200, delta: 500)
            ],
            to: source(key: "rollout")
        )

        let snapshot = try store.tokenActivity(
            in: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        XCTAssertEqual(snapshot.tokens, 500)
        XCTAssertEqual(snapshot.coverage, .low)
        XCTAssertEqual(
            snapshot.reason,
            "Local token activity starts from an unbounded counter"
        )
    }

    func testSQLiteTokenSnapshotMatchesTheInMemoryAggregator() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let preferred = [
            tokenFact(
                id: "baseline",
                timestamp: 1_100,
                delta: nil,
                reason: "segment-baseline"
            ),
            tokenFact(id: "shared", timestamp: 1_200, delta: 200),
            tokenFact(id: "known", timestamp: 1_300, delta: 300),
            tokenFact(id: "at-end", timestamp: 2_000, delta: 900)
        ]
        try store.append(preferred, to: source(key: "a"))
        try store.append(
            [tokenFact(id: "shared", timestamp: 1_200, delta: 800)],
            to: source(key: "b")
        )
        let observation = LocalActivityObservation.continuous(
            sourceVersion: "0.145.0",
            observedAt: interval.end
        )

        let memory = LocalTokenActivityAggregator.evaluate(
            facts: preferred,
            interval: interval,
            observation: observation
        )
        let sqlite = try store.tokenActivity(
            in: interval,
            observation: observation
        )

        XCTAssertEqual(sqlite.tokens, memory.tokens)
        XCTAssertEqual(sqlite.coverage, memory.coverage)
        XCTAssertEqual(sqlite.reason, memory.reason)
        XCTAssertEqual(sqlite.points, memory.points)
    }

    func testFilteredTokenActivityAndOptionsUseStoredTaskMetadata() throws {
        let store = try LocalActivityStore(fileURL: temporaryDatabase())
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let root = projection(
            taskID: "root",
            parentTaskID: nil,
            project: "Codex Limits"
        )
        let child = projection(
            taskID: "child",
            parentTaskID: "root",
            project: nil
        )
        try store.append(
            [
                tokenFact(
                    id: "selected",
                    timestamp: 1_100,
                    delta: 200,
                    context: LocalActivityContext(
                        taskID: "child",
                        turnID: "turn-a",
                        agent: LocalAgentIdentity(
                            nickname: "Scout",
                            role: "explorer"
                        ),
                        effectiveModel: "gpt-5.6",
                        reasoning: "high"
                    )
                ),
                tokenFact(
                    id: "other",
                    timestamp: 1_200,
                    delta: 300,
                    context: LocalActivityContext(
                        taskID: nil,
                        turnID: nil,
                        agent: nil,
                        effectiveModel: "gpt-5.5",
                        reasoning: "medium"
                    )
                )
            ],
            to: source(key: "rollout"),
            projections: [child, root]
        )
        let observation = LocalActivityObservation.continuous(
            sourceVersion: "0.145.0",
            observedAt: interval.end
        )

        let filtered = try store.tokenActivity(
            in: interval,
            filters: WorkspaceFilters(
                projectID: "Codex Limits",
                taskTreeID: "root",
                model: "gpt-5.6",
                reasoning: "high"
            ),
            observation: observation
        )
        let options = try store.filterOptions(in: interval)

        XCTAssertEqual(filtered.tokens, 200)
        XCTAssertEqual(filtered.points.map(\.tokens), [200])
        XCTAssertEqual(options.projects, ["Codex Limits"])
        XCTAssertEqual(options.taskTrees, ["root"])
        XCTAssertEqual(options.models, ["gpt-5.5", "gpt-5.6"])
        XCTAssertEqual(options.reasoningLevels, ["high", "medium"])
    }

    func testTokenTotalOverflowFailsInsteadOfWrapping() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        try store.append(
            [
                tokenFact(
                    id: "maximum",
                    timestamp: 1_100,
                    delta: .max
                ),
                tokenFact(id: "overflow", timestamp: 1_200, delta: 1)
            ],
            to: source(key: "rollout")
        )

        XCTAssertThrowsError(
            try store.tokenActivity(
                in: interval,
                observation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: interval.end
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalActivityStore.StoreError,
                .tokenTotalOverflow
            )
        }
    }

    func testInvalidTokenQueryIsRejected() throws {
        let store = try LocalActivityStore(fileURL: temporaryDatabase())
        let instant = Date(timeIntervalSince1970: 1_000)

        XCTAssertThrowsError(
            try store.tokenActivity(
                in: DateInterval(start: instant, end: instant),
                observation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: instant
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalActivityStore.StoreError,
                .invalidQuery
            )
        }
    }

    func testImportingReplacementResumesAfterReopenWithItsCursorState() throws {
        let database = temporaryDatabase()
        var source = source(key: "rollout", generation: 9)
        source.legacyDevice = 4
        source.legacyInode = 8
        source.legacyOffset = 1_024
        source.legacySize = 1_024
        source.legacyModificationDate = Date(timeIntervalSince1970: 900)
        source.legacyOffset = 128
        source.pendingFactJSON = Data("pending".utf8)
        var store: LocalActivityStore? = try LocalActivityStore(fileURL: database)
        let storeGeneration = try XCTUnwrap(
            store?.beginReplacement(for: source)
        )
        try store?.appendReplacement(
            [tokenFact(id: "first", timestamp: 1_100, delta: 100, generation: 9)],
            to: source,
            storeGeneration: storeGeneration
        )
        store?.close()

        store = try LocalActivityStore(fileURL: database)
        let resumed = try XCTUnwrap(
            store?.resumableReplacement(matching: source)
        )

        XCTAssertEqual(resumed.storeGeneration, storeGeneration)
        XCTAssertEqual(resumed.source.legacyOffset, 128)
        XCTAssertEqual(resumed.source.pendingFactJSON, Data("pending".utf8))

        var secondChunk = resumed.source
        secondChunk.legacyOffset = 1_024
        secondChunk.pendingFactJSON = nil
        try store?.appendReplacement(
            [tokenFact(id: "second", timestamp: 1_200, delta: 200, generation: 9)],
            to: secondChunk,
            storeGeneration: resumed.storeGeneration
        )
        try store?.activateReplacement(
            sourceKey: source.key,
            storeGeneration: resumed.storeGeneration
        )
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(try store.map { try tokens(in: $0, interval: interval) }, 300)
    }

    func testHistoryCutoffMismatchFailsClosed() throws {
        let database = temporaryDatabase()
        let originalCutoff = Date(timeIntervalSince1970: 1_000)
        let store = try LocalActivityStore(
            fileURL: database,
            historyCutoff: originalCutoff
        )
        try store.append(
            [tokenFact(id: "stored", timestamp: 1_100, delta: 100)],
            to: source(key: "rollout")
        )
        store.close()

        XCTAssertThrowsError(
            try LocalActivityStore(
                fileURL: database,
                historyCutoff: Date(timeIntervalSince1970: 1_200)
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalActivityStore.StoreError,
                .historyCutoffMismatch
            )
        }

        XCTAssertNoThrow(
            try LocalActivityStore(
                fileURL: database,
                historyCutoff: originalCutoff
            ).close()
        )
    }

    func testUnknownSchemaFailsClosed() throws {
        let database = temporaryDatabase()
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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

        XCTAssertThrowsError(try LocalActivityStore(fileURL: database)) {
            XCTAssertEqual(
                $0 as? LocalActivityStore.StoreError,
                .schemaMismatch
            )
        }
    }

    func testActiveSourceMatchUsesTheLegacyFileSignature() throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        var source = source(key: "rollout", generation: 3)
        source.legacyDevice = 4
        source.legacyInode = 8
        source.legacySize = 1_024
        source.legacyModificationDate = Date(timeIntervalSince1970: 900)
        source.legacyOffset = 128
        try store.append([], to: source)

        XCTAssertFalse(try store.hasActiveSource(matching: source))

        source.legacyOffset = 1_024
        try store.append([], to: source)
        XCTAssertTrue(try store.hasActiveSource(matching: source))
        XCTAssertTrue(try store.hasActiveSource(key: source.key))
        XCTAssertFalse(try store.hasActiveSource(key: "other"))

        source.legacyInode = 9
        XCTAssertFalse(try store.hasActiveSource(matching: source))
    }

    func testCancellationDuringAppendRollsBackProcessedFacts() async throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        let storedSource = source(key: "rollout")
        let facts = (0..<1_024).map { index in
            tokenFact(
                id: "event-\(index)",
                timestamp: 1_100 + TimeInterval(index),
                delta: 1
            )
        }
        let enteredLoop = expectation(description: "append entered fact loop")
        let continueAppend = DispatchSemaphore(value: 0)
        store.testFactProgress = { index in
            guard index == 256 else { return }
            enteredLoop.fulfill()
            continueAppend.wait()
        }
        let append = Task {
            try store.append(facts, to: storedSource)
        }
        await fulfillment(of: [enteredLoop], timeout: 5)
        append.cancel()
        continueAppend.signal()

        do {
            try await append.value
            XCTFail("Cancelled append should fail")
        } catch is CancellationError {
            // Expected.
        }

        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertEqual(try tokens(in: store, interval: interval), 0)
        store.testFactProgress = nil
    }

    func testCancelledTokenQueryFailsWithCancellationError() async throws {
        let database = temporaryDatabase()
        let store = try LocalActivityStore(fileURL: database)
        try store.append(
            [tokenFact(id: "stored", timestamp: 1_100, delta: 100)],
            to: source(key: "rollout")
        )
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let query = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try store.tokenActivity(
                in: interval,
                observation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: interval.end
                )
            )
        }
        query.cancel()

        do {
            _ = try await query.value
            XCTFail("Cancelled query should fail")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancelledFilterQueryFailsWithCancellationError() async throws {
        let store = try LocalActivityStore(fileURL: temporaryDatabase())
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let query = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try store.filterOptions(in: interval)
        }
        query.cancel()

        do {
            _ = try await query.value
            XCTFail("Cancelled query should fail")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("local-activity-v1.sqlite3")
    }

    private func source(
        key: String,
        generation: UInt64 = 1
    ) -> LocalActivityStore.Source {
        LocalActivityStore.Source(
            key: key,
            sourceGeneration: generation
        )
    }

    private func tokenFact(
        id: String,
        timestamp: TimeInterval,
        delta: Int64?,
        reason: String? = nil,
        generation: UInt64 = 1,
        availability: LocalActivityAvailability = .available,
        context: LocalActivityContext? = nil
    ) -> LocalActivityFact {
        LocalActivityFact(
            key: .token,
            availability: availability,
            value: .tokens(
                LocalTokenUsage(
                    inputTokens: 0,
                    cachedInputTokens: 0,
                    cacheWriteInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0,
                    totalTokens: delta ?? 0
                )
            ),
            numericDelta: delta,
            tokenSegment: 0,
            reason: reason,
            eventID: id,
            eventTimestamp: ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: timestamp)
            ),
            source: LocalActivitySourceMetadata(
                source: .rolloutJSONL,
                sourceVersion: "0.145.0",
                schemaVersion: "rollout-v1",
                sourceGeneration: generation,
                historyMode: nil,
                observedAt: Date(timeIntervalSince1970: timestamp)
            ),
            context: context
        )
    }

    private func projection(
        taskID: String,
        parentTaskID: String?,
        project: String?
    ) -> ThreadProjection {
        ThreadProjection(
            taskID: taskID,
            parentTaskID: parentTaskID,
            projectLabel: project,
            rolloutFileURL: nil,
            createdAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_500),
            source: LocalActivitySourceMetadata(
                source: .appServerThreadList,
                sourceVersion: "0.145.0",
                schemaVersion: "app-server-v1",
                sourceGeneration: 0,
                historyMode: nil,
                observedAt: Date(timeIntervalSince1970: 1_500)
            )
        )
    }

    private func contextFact(
        id: String,
        timestamp: TimeInterval
    ) -> LocalActivityFact {
        LocalActivityFact(
            key: .context,
            availability: .available,
            value: nil,
            numericDelta: nil,
            tokenSegment: nil,
            reason: nil,
            eventID: id,
            eventTimestamp: ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: timestamp)
            ),
            source: LocalActivitySourceMetadata(
                source: .rolloutJSONL,
                sourceVersion: "0.145.0",
                schemaVersion: "rollout-v1",
                sourceGeneration: 1,
                historyMode: nil,
                observedAt: Date(timeIntervalSince1970: timestamp)
            )
        )
    }

    private func tokens(
        in store: LocalActivityStore,
        interval: DateInterval
    ) throws -> Int64? {
        try store.tokenActivity(
            in: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        ).tokens
    }
}
