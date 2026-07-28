import Foundation
import XCTest
@testable import CodexLimits

final class LocalActivityNormalizerTests: XCTestCase {
    func testTokenComponentsUseIncrementalDeltasAndContextSample() {
        let normalizer = LocalActivityNormalizer()
        let first = normalizer.normalize(
            records: [
                record(
                    id: "baseline",
                    type: "event_msg",
                    threadID: "task-root",
                    turnID: "turn-1",
                    tokenUsage: LocalTokenUsage(
                        inputTokens: 1_000,
                        cachedInputTokens: 400,
                        cacheWriteInputTokens: 20,
                        outputTokens: 200,
                        reasoningOutputTokens: 80,
                        totalTokens: 1_200
                    ),
                    contextTokenUsage: LocalTokenUsage(
                        inputTokens: 600,
                        cachedInputTokens: 250,
                        cacheWriteInputTokens: 10,
                        outputTokens: 100,
                        reasoningOutputTokens: 40,
                        totalTokens: 700
                    ),
                    modelContextWindow: 272_000
                )
            ],
            sourceGeneration: 0,
            observedAt: Date(timeIntervalSince1970: 1_100)
        )
        let second = normalizer.normalize(
            records: [
                record(
                    id: "delta",
                    type: "event_msg",
                    threadID: "task-root",
                    tokenUsage: LocalTokenUsage(
                        inputTokens: 1_300,
                        cachedInputTokens: 500,
                        cacheWriteInputTokens: 30,
                        outputTokens: 260,
                        reasoningOutputTokens: 100,
                        totalTokens: 1_560
                    ),
                    contextTokenUsage: LocalTokenUsage(
                        inputTokens: 800,
                        cachedInputTokens: 300,
                        cacheWriteInputTokens: 15,
                        outputTokens: 140,
                        reasoningOutputTokens: 60,
                        totalTokens: 940
                    )
                )
            ],
            sourceGeneration: 0,
            observedAt: Date(timeIntervalSince1970: 1_200),
            previousState: first.state
        )

        XCTAssertEqual(
            second.facts(.token).last?.tokenDelta,
            LocalTokenUsage(
                inputTokens: 300,
                cachedInputTokens: 100,
                cacheWriteInputTokens: 10,
                outputTokens: 60,
                reasoningOutputTokens: 20,
                totalTokens: 360
            )
        )
        XCTAssertEqual(
            second.facts(.context).last?.value,
            .tokens(
                LocalTokenUsage(
                    inputTokens: 800,
                    cachedInputTokens: 300,
                    cacheWriteInputTokens: 15,
                    outputTokens: 140,
                    reasoningOutputTokens: 60,
                    totalTokens: 940
                )
            )
        )
        XCTAssertEqual(
            second.facts(.context).last?.context?.modelContextWindow,
            272_000
        )
    }

    func testCompactionKeepsTurnContext() {
        let result = LocalActivityNormalizer().normalize(
            records: [
                record(
                    id: "context",
                    type: "turn_context",
                    threadID: "task-root",
                    turnID: "turn-1"
                ),
                record(
                    id: "compaction",
                    type: "compacted",
                    threadID: "task-root"
                )
            ],
            sourceGeneration: 0,
            observedAt: Date(timeIntervalSince1970: 1_100)
        )

        XCTAssertEqual(
            result.facts(.compaction).last?.context?.turnID,
            "turn-1"
        )
    }

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
        XCTAssertEqual(
            result.fact(.time)?.context,
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

    func testCompletionAndDurationDoNotReplaceAnUnobservedTurnStart() {
        let result = LocalActivityNormalizer().normalize(
            records: [
                record(
                    id: "complete-without-start",
                    type: "event_msg",
                    threadID: "task-root",
                    turnID: "turn-1",
                    completedAt: 1_100,
                    durationMilliseconds: 5_000
                )
            ],
            sourceGeneration: 0,
            observedAt: Date(timeIntervalSince1970: 1_200)
        )

        XCTAssertEqual(result.fact(.time)?.availability, .partial)
        XCTAssertEqual(result.fact(.time)?.reason, "turn-start-not-observed")
    }

    private func record(
        id: String,
        type: String,
        threadID: String,
        turnID: String? = nil,
        agent: LocalAgentIdentity? = nil,
        model: String? = nil,
        reasoning: String? = nil,
        tokens: Int64? = nil,
        tokenUsage: LocalTokenUsage? = nil,
        contextTokenUsage: LocalTokenUsage? = nil,
        modelContextWindow: Int64? = nil,
        startedAt: Int64? = nil,
        completedAt: Int64? = nil,
        durationMilliseconds: Int64? = nil
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
            tokenUsage: tokenUsage ?? tokens.map {
                LocalTokenUsage(
                    inputTokens: $0,
                    cachedInputTokens: 0,
                    cacheWriteInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0,
                    totalTokens: $0
                )
            },
            contextTokenUsage: contextTokenUsage,
            modelContextWindow: modelContextWindow,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMilliseconds: durationMilliseconds,
            timeToFirstTokenMilliseconds: nil,
            toolClass: nil
        )
    }
}
