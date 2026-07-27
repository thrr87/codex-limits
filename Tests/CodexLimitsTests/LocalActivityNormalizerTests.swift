import Foundation
import XCTest
@testable import CodexLimits

final class LocalActivityNormalizerTests: XCTestCase {
    func testHistoricalFixtureNormalizesSupportedAndUnavailableFacts() throws {
        let fixtureURL = Bundle.module.url(
            forResource: "local-activity-historical",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        )!
        let observedAt = Date(timeIntervalSince1970: 1_785_000_000)
        let tail = try IncrementalRolloutTailSource().read(
            fileURL: fixtureURL,
            cursor: nil,
            observedAt: observedAt
        )

        let result = LocalActivityNormalizer().normalize(
            records: tail.records,
            sourceGeneration: tail.cursor.sourceGeneration,
            observedAt: observedAt
        )

        XCTAssertEqual(result.source.source, .rolloutJSONL)
        XCTAssertEqual(result.source.sourceVersion, "0.145.0")
        XCTAssertEqual(result.source.schemaVersion, "rollout-v1")
        XCTAssertEqual(result.source.sourceGeneration, 0)
        XCTAssertEqual(result.source.historyMode, "paginated")
        XCTAssertEqual(result.fact(.task)?.value, .identifier("task-root"))
        XCTAssertEqual(result.fact(.root)?.value, .identifier("task-root"))
        XCTAssertEqual(result.fact(.parent)?.availability, .unavailable)
        XCTAssertEqual(result.fact(.turn)?.value, .identifier("turn-1"))
        XCTAssertEqual(
            result.fact(.agent)?.value,
            .agent(LocalAgentIdentity(nickname: "Luna", role: "default"))
        )
        XCTAssertEqual(result.fact(.effectiveModel)?.value, .text("gpt-5.6"))
        XCTAssertEqual(result.fact(.reasoning)?.value, .text("high"))
        XCTAssertEqual(result.facts(.token).compactMap(\.numericDelta), [500])
        XCTAssertEqual(
            result.facts(.token).last?.value,
            .tokens(
                LocalTokenUsage(
                    inputTokens: 1_150,
                    cachedInputTokens: 150,
                    cacheWriteInputTokens: 0,
                    outputTokens: 350,
                    reasoningOutputTokens: 75,
                    totalTokens: 1_500
                )
            )
        )
        XCTAssertEqual(
            result.fact(.time)?.value,
            .turnTiming(
                LocalTurnTiming(
                    startedAt: Date(timeIntervalSince1970: 1_784_541_602),
                    completedAt: Date(timeIntervalSince1970: 1_784_541_607),
                    durationMilliseconds: 5_000,
                    timeToFirstTokenMilliseconds: 400
                )
            )
        )
        XCTAssertEqual(result.fact(.tool)?.availability, .partial)
        XCTAssertEqual(result.fact(.tool)?.value, .text("command_execution"))
        XCTAssertEqual(result.fact(.wait)?.availability, .unavailable)
        XCTAssertEqual(result.fact(.compaction)?.value, .count(1))
        XCTAssertTrue(result.facts.allSatisfy { $0.source == result.source })
        XCTAssertTrue(
            result.facts
                .filter { $0.availability != .unavailable }
                .allSatisfy {
                    $0.eventID != nil && $0.eventTimestamp != nil
                }
        )
    }
}
