import Foundation
import XCTest
@testable import CodexLimits

final class RolloutTailSourceTests: XCTestCase {
    func testTokenRecordKeepsContextAndTokenComponentsWithoutSourceContent() throws {
        let fixture = try TemporaryRollout()
        try fixture.append(
            #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","model_context_window":272000,"info":{"model_context_window":272000,"total_token_usage":{"input_tokens":1200,"cached_input_tokens":400,"cache_write_input_tokens":50,"output_tokens":300,"reasoning_output_tokens":100,"total_tokens":1500},"last_token_usage":{"input_tokens":700,"cached_input_tokens":250,"cache_write_input_tokens":25,"output_tokens":200,"reasoning_output_tokens":80,"total_tokens":900}},"message":"must not be retained","command":"must not be retained"}}"#
                + "\n"
        )

        let batch = try IncrementalRolloutTailSource().read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )
        let record = try XCTUnwrap(batch.records.first)

        XCTAssertEqual(record.modelContextWindow, 272_000)
        XCTAssertEqual(
            record.tokenUsage,
            LocalTokenUsage(
                inputTokens: 1_200,
                cachedInputTokens: 400,
                cacheWriteInputTokens: 50,
                outputTokens: 300,
                reasoningOutputTokens: 100,
                totalTokens: 1_500
            )
        )
        XCTAssertEqual(
            record.contextTokenUsage,
            LocalTokenUsage(
                inputTokens: 700,
                cachedInputTokens: 250,
                cacheWriteInputTokens: 25,
                outputTokens: 200,
                reasoningOutputTokens: 80,
                totalTokens: 900
            )
        )
        let mirrorLabels = Set(
            Mirror(reflecting: record).children.compactMap(\.label)
        )
        XCTAssertFalse(mirrorLabels.contains("message"))
        XCTAssertFalse(mirrorLabels.contains("command"))
    }

    func testMissingTokenComponentsStayUnobservedInsteadOfBecomingZeroFacts() throws {
        let fixture = try TemporaryRollout()
        try fixture.append(
            #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1500},"last_token_usage":{"total_tokens":500}}}}"#
                + "\n"
        )

        let record = try XCTUnwrap(
            IncrementalRolloutTailSource().read(
                fileURL: fixture.url,
                cursor: nil,
                observedAt: Date(timeIntervalSince1970: 100)
            ).records.first
        )

        XCTAssertEqual(record.tokenUsage?.observedComponents, [.total])
        XCTAssertEqual(
            record.contextTokenUsage?.observedComponents,
            [.total]
        )
    }

    func testLegacyPersistedTokenUsageDoesNotInventComponentPresence() throws {
        let data = Data(
            #"{"inputTokens":0,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":500}"#.utf8
        )

        let usage = try JSONDecoder().decode(
            LocalTokenUsage.self,
            from: data
        )

        XCTAssertEqual(usage.totalTokens, 500)
        XCTAssertEqual(usage.observedComponents, [.total])
    }

    func testTailKeepsCursorBeforePartialFinalLine() throws {
        let fixture = try TemporaryRollout()
        let completeLine =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
            + "\n"
        let partialLine =
            #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg""#
        try fixture.append(
            completeLine + partialLine
        )

        let batch = try IncrementalRolloutTailSource().read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(batch.records.map(\.ordinal), [0])
        XCTAssertEqual(batch.cursor.byteOffset, UInt64(completeLine.utf8.count))
        XCTAssertEqual(
            batch.cursor.fileSize,
            UInt64((completeLine + partialLine).utf8.count)
        )
    }

    func testTailStartsNewGenerationWhenFileIdentityChanges() throws {
        let firstFixture = try TemporaryRollout()
        try firstFixture.append(
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":4,"type":"event_msg","payload":{"type":"turn_started","turn_id":"turn-old"}}"#
                + "\n"
        )
        let source = IncrementalRolloutTailSource()
        let firstBatch = try source.read(
            fileURL: firstFixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        let replacementFixture = try TemporaryRollout()
        try replacementFixture.append(
            #"{"timestamp":"2026-07-27T10:02:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-new","cli_version":"0.145.0"}}"#
                + "\n"
        )
        let replacementBatch = try source.read(
            fileURL: replacementFixture.url,
            cursor: firstBatch.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(replacementBatch.records.map(\.ordinal), [0])
        XCTAssertEqual(replacementBatch.cursor.sourceGeneration, 1)
        XCTAssertEqual(replacementBatch.cursor.lastOrdinal, 0)
        XCTAssertTrue(replacementBatch.requiresRebuild)
    }

    func testTailDoesNotEmitReplayedOrdinalsFromReplacementCopy() throws {
        let history =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
            + "\n"
            + #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#
            + "\n"
        let original = try TemporaryRollout()
        try original.append(history)
        let source = IncrementalRolloutTailSource()
        let firstBatch = try source.read(
            fileURL: original.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        let replacement = try TemporaryRollout()
        try replacement.append(history)
        let replayBatch = try source.read(
            fileURL: replacement.url,
            cursor: firstBatch.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(replayBatch.records.isEmpty)
        XCTAssertEqual(replayBatch.cursor.sourceGeneration, 1)
        XCTAssertEqual(replayBatch.cursor.lastOrdinal, 1)
    }

    func testVerifiedContinuationSkipsAppendedOlderOrdinal() throws {
        let fixture = try TemporaryRollout()
        let initial =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
            + "\n"
            + #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":2,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":200}}}}"#
            + "\n"
        try fixture.append(initial)
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        try fixture.append(
            #"{"timestamp":"2026-07-27T10:00:30.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#
                + "\n"
        )
        let replay = try source.read(
            fileURL: fixture.url,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(replay.records.isEmpty)
        XCTAssertEqual(replay.cursor.lastOrdinal, 2)
        XCTAssertFalse(replay.requiresRebuild)
    }

    func testReplacementDeduplicatesLargeOrdinalHistory() throws {
        var history =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0","history_mode":"paginated"}}"#
            + "\n"
        for ordinal in 1...300 {
            history +=
                #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(ordinal * 100)}}}}"#
                + "\n"
        }
        let original = try TemporaryRollout()
        try original.append(history)
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: original.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        let replacement = try TemporaryRollout()
        try replacement.append(history)
        let replay = try source.read(
            fileURL: replacement.url,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(replay.records.isEmpty)
        XCTAssertEqual(replay.cursor.lastOrdinal, 300)
    }

    func testChangedReplacementReturnsCompleteGenerationForRebuild() throws {
        let originalHistory =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
            + "\n"
            + #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#
            + "\n"
        let original = try TemporaryRollout()
        try original.append(originalHistory)
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: original.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        let changedHistory =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
            + "\n"
            + #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":200}}}}"#
            + "\n"
        let replacement = try TemporaryRollout()
        try replacement.append(changedHistory)
        let rebuilt = try source.read(
            fileURL: replacement.url,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(rebuilt.requiresRebuild)
        XCTAssertEqual(rebuilt.records.map(\.ordinal), [0, 1])
        XCTAssertEqual(rebuilt.records.last?.totalTokens, 200)
    }

    func testChangedReplacementDoesNotReusePreviousTaskIdentity() throws {
        let original = try TemporaryRollout()
        try original.append(
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
                + "\n"
        )
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: original.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        let replacement = try TemporaryRollout()
        try replacement.append(
            #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":200}}}}"#
                + "\n"
        )
        let rebuilt = try source.read(
            fileURL: replacement.url,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(rebuilt.requiresRebuild)
        XCTAssertNil(rebuilt.records.first?.threadID)
        XCTAssertNil(rebuilt.cursor.threadID)
        XCTAssertEqual(rebuilt.cursor.lastOrdinal, 1)
    }

    func testPartialChangedReplacementClearsPreviousSourceState() throws {
        let original = try TemporaryRollout()
        try original.append(
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":4,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
                + "\n"
        )
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: original.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        let replacement = try TemporaryRollout()
        try replacement.append(
            #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":0,"type":"event_msg""#
        )
        let partial = try source.read(
            fileURL: replacement.url,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(partial.requiresRebuild)
        XCTAssertNil(partial.cursor.threadID)
        XCTAssertNil(partial.cursor.lastOrdinal)
        XCTAssertNil(partial.cursor.processedPrefixFingerprint)
    }

    func testSameInodeTruncateAndRegrowRequiresRebuild() throws {
        let fixture = try TemporaryRollout()
        let original =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
            + "\n"
            + #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#
            + "\n"
        try fixture.append(original)
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        let changed = original.replacingOccurrences(
            of: #""total_tokens":100"#,
            with: #""total_tokens":200"#
        )
        try fixture.replace(with: changed)
        let rebuilt = try source.read(
            fileURL: fixture.url,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(rebuilt.cursor.fileIdentity, first.cursor.fileIdentity)
        XCTAssertTrue(rebuilt.requiresRebuild)
        XCTAssertEqual(rebuilt.records.last?.totalTokens, 200)
    }

    func testUnsupportedTrailingRecordCannotHideChangedAcceptedActivity() throws {
        let fixture = try TemporaryRollout()
        let original =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
            + "\n"
            + #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#
            + "\n"
            + #"{"timestamp":"2026-07-27T10:02:00.000Z","ordinal":2,"type":"response_item","payload":{"type":"message","text":""}}"#
            + "\n"
        try fixture.append(original)
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        let changed = original.replacingOccurrences(
            of: #""total_tokens":100"#,
            with: #""total_tokens":200"#
        )
        try fixture.replace(with: changed)
        let rebuilt = try source.read(
            fileURL: fixture.url,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(rebuilt.requiresRebuild)
        XCTAssertEqual(rebuilt.records.last?.totalTokens, 200)
    }

    func testOversizedAcceptedRecordClearsOlderCheckpoint() throws {
        let fixture = try TemporaryRollout()
        let padding = String(repeating: "x", count: 5_000)
        let session =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
            + "\n"
        let originalContext =
            #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5.6","effort":"high","padding":"\#(padding)"}}"#
            + "\n"
        try fixture.append(session + originalContext)
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(first.cursor.checkpoint)
        let changedContext = originalContext.replacingOccurrences(
            of: #""model":"gpt-5.6""#,
            with: #""model":"gpt-5.5""#
        )
        try fixture.replace(with: session + changedContext)
        let rebuilt = try source.read(
            fileURL: fixture.url,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(rebuilt.requiresRebuild)
        XCTAssertEqual(rebuilt.records.last?.model, "gpt-5.5")
    }

    func testReplacementContinuesAfterLargePreOrdinalPrefixWithoutReplay() throws {
        var history =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0","history_mode":"inline"}}"#
            + "\n"
        for total in 1...300 {
            history +=
                #"{"timestamp":"2026-07-27T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total * 100)}}}}"#
                + "\n"
        }
        let original = try TemporaryRollout()
        try original.append(history)
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: original.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        let appended =
            #"{"timestamp":"2026-07-27T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":30100}}}}"#
            + "\n"
        let replacement = try TemporaryRollout()
        try replacement.append(history + appended)
        let continued = try source.read(
            fileURL: replacement.url,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(continued.records.count, 1)
        XCTAssertEqual(continued.records.first?.totalTokens, 30_100)
        XCTAssertEqual(
            continued.bytesRead,
            UInt64((history + appended).utf8.count)
        )
        XCTAssertEqual(continued.cursor.sourceGeneration, 1)
        XCTAssertFalse(continued.requiresRebuild)
    }

    func testDistinctPreOrdinalEventsAtSameTimestampAreNotCollapsed() throws {
        let fixture = try TemporaryRollout()
        let event =
            #"{"timestamp":"2026-07-27T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#
            + "\n"
        try fixture.append(event + event)

        let batch = try IncrementalRolloutTailSource().read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(batch.records.count, 2)
        XCTAssertEqual(Set(batch.records.map(\.eventID)).count, 2)
    }

    func testStableTaskTimingEventsAreSupported() throws {
        let fixture = try TemporaryRollout()
        try fixture.append(
            #"{"timestamp":"2026-07-27T10:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","started_at":1784541602}}"#
                + "\n"
                + #"{"timestamp":"2026-07-27T10:00:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","started_at":1784541602,"completed_at":1784541607,"duration_ms":5000,"time_to_first_token_ms":400}}"#
                + "\n"
        )

        let batch = try IncrementalRolloutTailSource().read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(batch.records.map(\.eventType), ["task_started", "task_complete"])
        XCTAssertEqual(batch.records.last?.durationMilliseconds, 5_000)
        XCTAssertEqual(batch.records.last?.timeToFirstTokenMilliseconds, 400)
    }

    func testLiveGrowthReadsBoundedCheckpointAndAppendedBytes() throws {
        let fixture = try TemporaryRollout()
        let initial =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0","history_mode":"paginated"}}"#
            + "\n"
            + #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1000}}}}"#
            + "\n"
        try fixture.append(initial)
        let source = IncrementalRolloutTailSource()
        let observedAt = Date(timeIntervalSince1970: 100)
        let firstTail = try source.read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: observedAt
        )
        let firstNormalized = LocalActivityNormalizer().normalize(
            records: firstTail.records,
            sourceGeneration: firstTail.cursor.sourceGeneration,
            observedAt: observedAt
        )

        let appended =
            #"{"timestamp":"2026-07-27T10:02:00.000Z","ordinal":2,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1500}}}}"#
            + "\n"
        try fixture.append(appended)
        let secondTail = try source.read(
            fileURL: fixture.url,
            cursor: firstTail.cursor,
            observedAt: observedAt.addingTimeInterval(60)
        )
        let secondNormalized = LocalActivityNormalizer().normalize(
            records: secondTail.records,
            sourceGeneration: secondTail.cursor.sourceGeneration,
            observedAt: observedAt.addingTimeInterval(60),
            previousState: firstNormalized.state
        )

        XCTAssertEqual(
            secondTail.bytesRead,
            UInt64(appended.utf8.count)
                + (firstTail.cursor.checkpoint?.byteLength ?? 0)
        )
        XCTAssertEqual(
            secondNormalized.facts(.token).compactMap(\.numericDelta),
            [500]
        )
        XCTAssertEqual(secondNormalized.source.sourceVersion, "0.145.0")
    }

    func testUnknownContentRecordIsSkippedWithoutLeakingItsFields() throws {
        let fixture = try TemporaryRollout()
        try fixture.append(
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"response_item","payload":{"prompt":"","output":"","path":""}}"#
                + "\n"
        )

        let batch = try IncrementalRolloutTailSource().read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(batch.records.isEmpty)
        XCTAssertEqual(batch.unsupportedRecordCount, 1)
        XCTAssertGreaterThan(batch.cursor.byteOffset, 0)
    }

    func testCompleteMalformedLineIsSkippedWithoutLosingValidRecords() throws {
        let fixture = try TemporaryRollout()
        try fixture.append(
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
                + "\n"
                + "{not-json}\n"
                + #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#
                + "\n"
        )

        let batch = try IncrementalRolloutTailSource().read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(batch.records.map(\.ordinal), [0, 1])
        XCTAssertEqual(batch.unsupportedRecordCount, 1)
        XCTAssertEqual(batch.records.last?.totalTokens, 100)
        XCTAssertEqual(batch.cursor.lastOrdinal, 1)
    }

    func testPartialLineIsEmittedOnceAfterItBecomesComplete() throws {
        let fixture = try TemporaryRollout()
        let firstLine =
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
            + "\n"
        let partial =
            #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":"#
        try fixture.append(firstLine + partial)
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        try fixture.append("100}}}}\n")
        let second = try source.read(
            fileURL: fixture.url,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )
        let third = try source.read(
            fileURL: fixture.url,
            cursor: second.cursor,
            observedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(second.records.map(\.ordinal), [1])
        XCTAssertEqual(second.records.first?.totalTokens, 100)
        XCTAssertTrue(third.records.isEmpty)
        XCTAssertEqual(third.bytesRead, 0)
    }

    func testRenameKeepsGenerationAndDoesNotRescan() throws {
        let fixture = try TemporaryRollout()
        try fixture.append(
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
                + "\n"
        )
        let source = IncrementalRolloutTailSource()
        let first = try source.read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        )
        let renamedURL = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("archived-rollout.jsonl")
        try FileManager.default.moveItem(at: fixture.url, to: renamedURL)

        let renamed = try source.read(
            fileURL: renamedURL,
            cursor: first.cursor,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(renamed.cursor.sourceGeneration, 0)
        XCTAssertEqual(renamed.cursor.fileIdentity, first.cursor.fileIdentity)
        XCTAssertTrue(renamed.records.isEmpty)
        XCTAssertEqual(renamed.bytesRead, 0)
    }

    func testCursorRoundTripsAsDurableState() throws {
        let fixture = try TemporaryRollout()
        try fixture.append(
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
                + "\n"
        )
        let cursor = try IncrementalRolloutTailSource().read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: Date(timeIntervalSince1970: 100)
        ).cursor

        let encoded = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(RolloutCursor.self, from: encoded)

        XCTAssertEqual(decoded, cursor)
    }

    func testCumulativeDecreaseStartsANewTokenSegmentWithoutNegativeDelta() throws {
        let fixture = try TemporaryRollout()
        try fixture.append(
            #"{"timestamp":"2026-07-27T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"task-root","cli_version":"0.145.0"}}"#
                + "\n"
                + #"{"timestamp":"2026-07-27T10:01:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1000}}}}"#
                + "\n"
                + #"{"timestamp":"2026-07-27T10:02:00.000Z","ordinal":2,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":900}}}}"#
                + "\n"
        )
        let observedAt = Date(timeIntervalSince1970: 100)
        let tail = try IncrementalRolloutTailSource().read(
            fileURL: fixture.url,
            cursor: nil,
            observedAt: observedAt
        )

        let normalized = LocalActivityNormalizer().normalize(
            records: tail.records,
            sourceGeneration: tail.cursor.sourceGeneration,
            observedAt: observedAt
        )
        let tokenFacts = normalized.facts(.token).filter {
            $0.availability != .unavailable
        }

        XCTAssertTrue(tokenFacts.compactMap(\.numericDelta).isEmpty)
        XCTAssertEqual(
            tokenFacts.map(\.reason),
            ["segment-baseline", "cumulative-counter-decreased"]
        )
        XCTAssertEqual(tokenFacts.map(\.tokenSegment), [0, 1])
    }
}

private final class TemporaryRollout {
    let url: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("rollout.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func replace(with text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(1)],
            ofItemAtPath: url.path
        )
    }
}
