import XCTest
@testable import CodexLimits

final class LocalTokenActivityTests: XCTestCase {
    func testSumsUniqueTokenDeltasInsideTheSelectedInterval() throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let activity = LocalTokenActivityAggregator.evaluate(
            facts: [
                tokenFact(id: "before", timestamp: 900, delta: 50),
                tokenFact(id: "first", timestamp: 1_100, delta: 100),
                tokenFact(id: "first", timestamp: 1_100, delta: 100),
                tokenFact(id: "second", timestamp: 1_500, delta: 250),
                tokenFact(id: "after", timestamp: 2_100, delta: 500)
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: Date(timeIntervalSince1970: 2_000)
            )
        )

        XCTAssertEqual(activity.tokens, 350)
        XCTAssertEqual(activity.interval, interval)
        XCTAssertEqual(activity.coverage, .high)
        XCTAssertEqual(activity.sourceVersion, "0.145.0")
        XCTAssertEqual(activity.observedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(activity.points.map(\.tokens), [100, 350])
        XCTAssertNil(activity.accountComparison.numericPercent)
        XCTAssertFalse(activity.accountComparison.comparable)
    }

    func testReadsFractionalSecondTimestampsFromRealRollouts() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let activity = LocalTokenActivityAggregator.evaluate(
            facts: [
                tokenFact(
                    id: "fractional",
                    timestamp: 1_100,
                    delta: 250,
                    fractionalSeconds: true
                )
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        XCTAssertEqual(activity.tokens, 250)
    }

    func testSourceGapKeepsFactsButLowersCoverageAndNamesTheReason() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let activity = LocalTokenActivityAggregator.evaluate(
            facts: [tokenFact(id: "first", timestamp: 1_100, delta: 100)],
            interval: interval,
            observation: .gap(
                sourceVersion: "0.145.0",
                observedAt: Date(timeIntervalSince1970: 2_000),
                reason: "Local task records are missing"
            )
        )

        XCTAssertEqual(activity.tokens, 100)
        XCTAssertEqual(activity.coverage, .low)
        XCTAssertEqual(activity.reason, "Local task records are missing")
    }

    func testNoLocalActivityInAContinuouslyObservedIntervalIsNotApplicable() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let activity = LocalTokenActivityAggregator.evaluate(
            facts: [],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: Date(timeIntervalSince1970: 2_000)
            )
        )

        XCTAssertEqual(activity.tokens, 0)
        XCTAssertEqual(activity.coverage, .notApplicable)
        XCTAssertEqual(activity.reason, "No local token activity was observed")
    }

    func testUnboundedCounterBaselineLowersCoverageAndNamesTheGap() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let activity = LocalTokenActivityAggregator.evaluate(
            facts: [
                tokenFact(
                    id: "baseline",
                    timestamp: 1_100,
                    delta: nil,
                    reason: "segment-baseline"
                ),
                tokenFact(id: "delta", timestamp: 1_200, delta: 500)
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        XCTAssertEqual(activity.tokens, 500)
        XCTAssertEqual(activity.coverage, .low)
        XCTAssertEqual(
            activity.reason,
            "Local token activity starts from an unbounded counter"
        )
    }

    func testUnavailableSourceWithholdsTheLocalTotal() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let activity = LocalTokenActivityAggregator.evaluate(
            facts: [tokenFact(id: "first", timestamp: 1_100, delta: 100)],
            interval: interval,
            observation: .unavailable("Codex local records are unavailable")
        )

        XCTAssertNil(activity.tokens)
        XCTAssertEqual(activity.coverage, .unavailable)
        XCTAssertEqual(activity.reason, "Codex local records are unavailable")
    }

    func testSelectedRangeReportsOnlyLocalActivityInsideTheRange() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let activity = LocalTokenActivityAggregator.evaluate(
            facts: [
                tokenFact(id: "first", timestamp: 1_100, delta: 100),
                tokenFact(id: "second", timestamp: 1_500, delta: 250),
                tokenFact(id: "third", timestamp: 1_900, delta: 400)
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = activity.slice(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 1_200),
                end: Date(timeIntervalSince1970: 1_600)
            )
        )

        XCTAssertEqual(slice.tokens, 250)
        XCTAssertEqual(slice.points.map(\.tokens), [250])
        XCTAssertEqual(
            slice.points.map(\.date),
            [Date(timeIntervalSince1970: 1_500)]
        )
        XCTAssertEqual(slice.coverage, .high)
    }

    func testSelectedRangeWithoutEventsIsNotApplicable() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let activity = LocalTokenActivityAggregator.evaluate(
            facts: [tokenFact(id: "outside", timestamp: 1_100, delta: 100)],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = activity.slice(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 1_500),
                end: Date(timeIntervalSince1970: 1_600)
            )
        )

        XCTAssertEqual(slice.tokens, 0)
        XCTAssertEqual(slice.coverage, .notApplicable)
        XCTAssertEqual(slice.reason, "No local token activity was observed")
    }

    func testEventsAtTheSameTimestampProduceOneStableChartPoint() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let activity = LocalTokenActivityAggregator.evaluate(
            facts: [
                tokenFact(id: "first", timestamp: 1_100, delta: 100),
                tokenFact(id: "second", timestamp: 1_100, delta: 250)
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        XCTAssertEqual(activity.tokens, 350)
        XCTAssertEqual(activity.points.count, 1)
        XCTAssertEqual(activity.points.first?.tokens, 350)
    }

    func testReaderKeepsAccountAndLargerLocalTotalsSeparateForOneInterval() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = accountSnapshot(
            fetchedAt: now,
            lifetimeTokens: 1_600
        )
        let boundary = UsageSample(
            observedAt: account.mainLimit!.window.startsAt.addingTimeInterval(60),
            remainingPercent: 100,
            resetsAt: account.mainLimit!.window.resetsAt,
            lifetimeTokens: 1_000
        )
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [boundary],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                localActivityFacts: [
                    tokenFact(
                        id: "local",
                        timestamp: boundary.observedAt.timeIntervalSince1970 + 60,
                        delta: 1_200
                    )
                ],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                )
            )
        )

        XCTAssertEqual(reader.accountTokenActivity.tokens, 600)
        XCTAssertEqual(reader.localTokenActivity.tokens, 1_200)
        XCTAssertEqual(
            reader.localTokenActivity.interval,
            reader.accountTokenActivity.interval
        )
        XCTAssertFalse(reader.localTokenActivity.accountComparison.comparable)
        XCTAssertNil(reader.localTokenActivity.accountComparison.numericPercent)
    }

    func testOffDeviceActivityDoesNotTurnTheAccountLocalGapIntoCoverage() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = accountSnapshot(
            fetchedAt: now,
            lifetimeTokens: 2_000
        )
        let boundary = UsageSample(
            observedAt: account.mainLimit!.window.startsAt,
            remainingPercent: 100,
            resetsAt: account.mainLimit!.window.resetsAt,
            lifetimeTokens: 1_000
        )
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [boundary],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                localActivityFacts: [
                    tokenFact(
                        id: "local",
                        timestamp: boundary.observedAt.timeIntervalSince1970 + 60,
                        delta: 100
                    )
                ],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                )
            )
        )

        XCTAssertEqual(reader.accountTokenActivity.tokens, 1_000)
        XCTAssertEqual(reader.localTokenActivity.tokens, 100)
        XCTAssertNil(reader.localTokenActivity.accountComparison.numericPercent)
        XCTAssertFalse(reader.localTokenActivity.accountComparison.comparable)
    }

    func testZeroAccountAndLocalActivityRemainFactual() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = accountSnapshot(
            fetchedAt: now,
            lifetimeTokens: 1_000
        )
        let boundary = UsageSample(
            observedAt: account.mainLimit!.window.startsAt,
            remainingPercent: 100,
            resetsAt: account.mainLimit!.window.resetsAt,
            lifetimeTokens: 1_000
        )
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [boundary],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                )
            )
        )

        XCTAssertEqual(reader.accountTokenActivity.tokens, 0)
        XCTAssertEqual(reader.localTokenActivity.tokens, 0)
        XCTAssertEqual(reader.localTokenActivity.coverage, .notApplicable)
    }

    func testLocalFactsRemainVisibleWhenTheAccountSourceFails() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = accountSnapshot(
            fetchedAt: now,
            lifetimeTokens: nil
        )
        let localDate = account.mainLimit!.window.startsAt
            .addingTimeInterval(60)
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .failed("Account source failed"),
                now: now,
                previousStatus: nil,
                localActivityFacts: [
                    tokenFact(
                        id: "local",
                        timestamp: localDate.timeIntervalSince1970,
                        delta: 400
                    )
                ],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                )
            )
        )

        XCTAssertEqual(reader.localTokenActivity.tokens, 400)
        XCTAssertEqual(reader.localTokenActivity.coverage, .high)
        XCTAssertEqual(reader.accountTokenActivity.state, .unavailable)
    }

    func testWeeklyResetBoundaryIncludesTheStartAndExcludesTheReset() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let activity = LocalTokenActivityAggregator.evaluate(
            facts: [
                tokenFact(id: "start", timestamp: 1_000, delta: 100),
                tokenFact(id: "reset", timestamp: 2_000, delta: 500)
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        XCTAssertEqual(activity.tokens, 100)
    }

    func testAccountEpochBoundsLocalActivityAfterAnAccountChange() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let epoch = now.addingTimeInterval(-3_600)
        let account = accountSnapshot(
            fetchedAt: now,
            lifetimeTokens: nil
        )
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountEpochStartedAt: epoch,
                localActivityFacts: [
                    tokenFact(
                        id: "before-account",
                        timestamp: epoch.timeIntervalSince1970 - 60,
                        delta: 900
                    ),
                    tokenFact(
                        id: "current-account",
                        timestamp: epoch.timeIntervalSince1970 + 60,
                        delta: 100
                    )
                ],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                )
            )
        )

        XCTAssertEqual(reader.localTokenActivity.interval.start, epoch)
        XCTAssertEqual(reader.localTokenActivity.tokens, 100)
    }

    private func tokenFact(
        id: String,
        timestamp: TimeInterval,
        delta: Int64?,
        fractionalSeconds: Bool = false,
        reason: String? = nil
    ) -> LocalActivityFact {
        let formatter = ISO8601DateFormatter()
        if fractionalSeconds {
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds
            ]
        }
        let eventTimestamp = formatter.string(
            from: Date(timeIntervalSince1970: timestamp)
        )
        return LocalActivityFact(
            key: .token,
            availability: .available,
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
            eventTimestamp: eventTimestamp,
            source: LocalActivitySourceMetadata(
                source: .rolloutJSONL,
                sourceVersion: "0.145.0",
                schemaVersion: "rollout-v1",
                sourceGeneration: 0,
                historyMode: nil,
                observedAt: Date(timeIntervalSince1970: timestamp)
            )
        )
    }

    private func accountSnapshot(
        fetchedAt: Date,
        lifetimeTokens: Int64?
    ) -> UsageSnapshot {
        UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "codex",
                name: "Codex",
                window: UsageWindow(
                    remainingPercent: 80,
                    resetsAt: fetchedAt.addingTimeInterval(2 * 86_400),
                    durationMinutes: 10_080
                )
            ),
            otherLimits: [],
            tokenHistory: [],
            emergencyResetCount: 0,
            fetchedAt: fetchedAt,
            accountFacts: AccountFacts(
                lifetimeTokens: lifetimeTokens,
                peakDailyTokens: nil,
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil,
                credits: nil,
                spendControl: nil,
                lifetimeTokensObservedAt: lifetimeTokens.map { _ in fetchedAt }
            )
        )
    }
}
