import Foundation
import XCTest
@testable import CodexLimits

final class LocalActivityNormalizerTests: XCTestCase {
    func testIncrementalNormalizationKeepsTaskAndTurnContext() {
        let normalizer = LocalActivityNormalizer()
        let first = normalizer.normalize(
            records: [
                record(
                    id: "session",
                    type: "session_meta",
                    threadID: "task-root",
                    agent: LocalAgentIdentity(
                        nickname: "Luna",
                        role: "default"
                    )
                ),
                record(
                    id: "context",
                    type: "turn_context",
                    threadID: "task-root",
                    turnID: "turn-1",
                    model: "gpt-5.6",
                    reasoning: "high"
                ),
                record(
                    id: "tokens-1",
                    type: "event_msg",
                    threadID: "task-root",
                    tokens: 100
                )
            ],
            sourceGeneration: 0,
            observedAt: Date(timeIntervalSince1970: 1_100)
        )
        let second = normalizer.normalize(
            records: [
                record(
                    id: "tokens-2",
                    type: "event_msg",
                    threadID: "task-root",
                    tokens: 150
                )
            ],
            sourceGeneration: 0,
            observedAt: Date(timeIntervalSince1970: 1_200),
            previousState: first.state
        )

        XCTAssertEqual(second.facts(.token).last?.numericDelta, 50)
        XCTAssertEqual(
            second.facts(.token).last?.context,
            LocalActivityContext(
                taskID: "task-root",
                turnID: "turn-1",
                agent: LocalAgentIdentity(
                    nickname: "Luna",
                    role: "default"
                ),
                effectiveModel: "gpt-5.6",
                reasoning: "high"
            )
        )
    }

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
            result.facts(.token).last?.context,
            LocalActivityContext(
                taskID: "task-root",
                turnID: "turn-1",
                agent: LocalAgentIdentity(
                    nickname: "Luna",
                    role: "default"
                ),
                effectiveModel: "gpt-5.6",
                reasoning: "high"
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

    func testRequestedSettingDoesNotReplaceTheEffectiveTurnContext() throws {
        let fixtureURL = Bundle.module.url(
            forResource: "local-activity-historical",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        )!
        let fixtureText = try String(
            contentsOf: fixtureURL,
            encoding: .utf8
        )
        XCTAssertTrue(
            fixtureText.contains(
                #""thread_settings":{"model":"gpt-5.5","reasoning_effort":"medium"}"#
            )
        )
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

        XCTAssertEqual(
            result.facts(.token).last?.context?.effectiveModel,
            "gpt-5.6"
        )
        XCTAssertEqual(
            result.facts(.token).last?.context?.reasoning,
            "high"
        )
    }

    private func record(
        id: String,
        type: String,
        threadID: String,
        turnID: String? = nil,
        agent: LocalAgentIdentity? = nil,
        model: String? = nil,
        reasoning: String? = nil,
        tokens: Int64? = nil
    ) -> RolloutRecord {
        RolloutRecord(
            eventID: id,
            ordinal: nil,
            timestamp: "2026-07-20T10:00:00.000Z",
            type: type,
            eventType: nil,
            threadID: threadID,
            parentThreadID: nil,
            cliVersion: "0.145.0",
            historyMode: "paginated",
            agentRole: agent?.role,
            agentNickname: agent?.nickname,
            turnID: turnID,
            model: model,
            reasoning: reasoning,
            tokenUsage: tokens.map {
                LocalTokenUsage(
                    inputTokens: $0,
                    cachedInputTokens: 0,
                    cacheWriteInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0,
                    totalTokens: $0
                )
            },
            startedAt: nil,
            completedAt: nil,
            durationMilliseconds: nil,
            timeToFirstTokenMilliseconds: nil,
            toolClass: nil
        )
    }
}
