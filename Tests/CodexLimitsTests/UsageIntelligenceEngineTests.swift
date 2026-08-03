import XCTest
@testable import CodexLimits

final class UsageIntelligenceEngineTests: XCTestCase {
    func testFreshAccountReadingProducesReaderFacts() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let account = makeSnapshot(remaining: 37, fetchedAt: now)

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.account, account)
        XCTAssertEqual(reader.menuBarText, "37%")
        XCTAssertEqual(reader.sourceState, .available)
        XCTAssertEqual(reader.accountSource, .account)
        XCTAssertEqual(reader.fetchedAt, now)
        XCTAssertEqual(reader.weeklyUsageRemaining, account.mainLimit)
        XCTAssertEqual(reader.accountFacts, account.accountFacts)
        XCTAssertEqual(reader.otherLimits, account.otherLimits)
        XCTAssertEqual(reader.chart.observedSource, .account)
        XCTAssertEqual(reader.guidance, nil)
        XCTAssertEqual(reader.interval?.limitID, "codex")
        XCTAssertEqual(reader.interval?.durationMinutes, 10_080)
        XCTAssertEqual(
            reader.interval?.startsAt,
            account.mainLimit!.window.startsAt
        )
        XCTAssertEqual(
            reader.interval?.resetsAt,
            account.mainLimit!.window.resetsAt
        )
        XCTAssertTrue(reader.interval?.text.hasPrefix("Weekly window · ") == true)
    }

    func testTightlyBoundedLifetimeReadingsProduceExactAccountTokenActivity() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            accountFacts: AccountFacts(
                lifetimeTokens: 1_600,
                peakDailyTokens: nil,
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil,
                credits: nil,
                spendControl: nil
            )
        )
        let boundary = UsageSample(
            observedAt: account.mainLimit!.window.startsAt.addingTimeInterval(5 * 60),
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
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.accountTokenActivity.state, .partial)
        XCTAssertEqual(reader.accountTokenActivity.tokens, 600)
        XCTAssertEqual(reader.accountTokenActivity.method, .lifetimeDelta)
        XCTAssertEqual(
            reader.accountTokenActivity.interval,
            DateInterval(start: boundary.observedAt, end: now)
        )
        XCTAssertNil(reader.accountTokenActivity.reason)
    }

    func testRollingDayUsesContainedLifetimeIntervals() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let readings = [
            UsageSample(
                observedAt: now.addingTimeInterval(-6 * 3_600),
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: now.addingTimeInterval(-4 * 3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_200
            ),
            UsageSample(
                observedAt: now,
                remainingPercent: 80,
                resetsAt: reset,
                lifetimeTokens: 1_500
            )
        ]
        var exploration = AnalyticsExplorationState.initial
        exploration.timeRange = .oneDay

        let activity = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: readings,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a",
                analyticsExploration: exploration
            )
        ).accountTokenActivity

        XCTAssertEqual(
            activity.range,
            DateInterval(
                start: now.addingTimeInterval(-86_400),
                end: now
            )
        )
        XCTAssertEqual(activity.tokens, 500)
        XCTAssertEqual(activity.method, .lifetimeDelta)
        XCTAssertEqual(activity.intervals.map(\.tokenDelta), [200, 300])
        XCTAssertEqual(
            activity.interval,
            DateInterval(
                start: readings[0].observedAt,
                end: readings[2].observedAt
            )
        )
        XCTAssertNil(activity.reason)
    }

    func testRollingDayStaysAtNowWhenLatestReadingIsStale() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let observedAt = now.addingTimeInterval(-6 * 3_600)
        let account = makeSnapshot(remaining: 80, fetchedAt: observedAt)
        let reset = account.mainLimit!.window.resetsAt
        let readings = [
            UsageSample(
                observedAt: observedAt.addingTimeInterval(-4 * 3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: observedAt,
                remainingPercent: 80,
                resetsAt: reset,
                lifetimeTokens: 1_300
            )
        ]
        var exploration = AnalyticsExplorationState.initial
        exploration.timeRange = .oneDay

        let activity = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: readings,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                analyticsExploration: exploration
            )
        ).accountTokenActivity

        XCTAssertEqual(activity.range?.end, now)
        XCTAssertEqual(activity.range?.duration, 86_400)
        XCTAssertEqual(activity.tokens, 300)
        XCTAssertEqual(activity.intervals.last?.end, observedAt)
    }

    func testRollingDayExcludesCrossingIntervalsAndIncludesExactBoundaries() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let start = now.addingTimeInterval(-86_400)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let readings = [
            UsageSample(
                observedAt: start.addingTimeInterval(-60),
                remainingPercent: 95,
                resetsAt: reset,
                lifetimeTokens: 900
            ),
            UsageSample(
                observedAt: start,
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: start.addingTimeInterval(3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_200
            ),
            UsageSample(
                observedAt: now,
                remainingPercent: 80,
                resetsAt: reset,
                lifetimeTokens: 1_500
            )
        ]
        var exploration = AnalyticsExplorationState.initial
        exploration.timeRange = .oneDay

        let activity = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: readings,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                analyticsExploration: exploration
            )
        ).accountTokenActivity

        XCTAssertEqual(activity.tokens, 500)
        XCTAssertEqual(activity.intervals.count, 2)
        XCTAssertEqual(activity.intervals.first?.start, start)
        XCTAssertEqual(activity.intervals.last?.end, now)
    }

    func testRollingDayKeepsLongAndZeroIntervalsFactual() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let readings = [
            UsageSample(
                observedAt: now.addingTimeInterval(-23 * 3_600),
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: now.addingTimeInterval(-3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_000
            )
        ]
        var exploration = AnalyticsExplorationState.initial
        exploration.timeRange = .oneDay

        let activity = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: readings,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                analyticsExploration: exploration
            )
        ).accountTokenActivity

        XCTAssertEqual(activity.tokens, 0)
        XCTAssertEqual(activity.intervals.count, 1)
        XCTAssertEqual(activity.intervals.first?.tokenDelta, 0)
        XCTAssertEqual(activity.intervals.first?.duration, 22 * 3_600)
    }

    func testRollingDayNamesMissingCompleteIntervals() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let onlyReading = UsageSample(
            observedAt: now.addingTimeInterval(-3_600),
            remainingPercent: 80,
            resetsAt: reset,
            lifetimeTokens: 1_000
        )
        var exploration = AnalyticsExplorationState.initial
        exploration.timeRange = .oneDay

        let beforeRange = [
            UsageSample(
                observedAt: now.addingTimeInterval(-30 * 3_600),
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 800
            ),
            UsageSample(
                observedAt: now.addingTimeInterval(-25 * 3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 900
            )
        ]
        let crossingEnd = [
            onlyReading,
            UsageSample(
                observedAt: now.addingTimeInterval(60),
                remainingPercent: 75,
                resetsAt: reset,
                lifetimeTokens: 1_100
            )
        ]

        for samples in [[onlyReading], beforeRange, crossingEnd] {
            let activity = UsageIntelligenceEngine.evaluate(
                UsageIntelligenceInput(
                    account: account,
                    samples: samples,
                    safetyBuffer: 3,
                    sourceState: .available,
                    now: now,
                    previousStatus: nil,
                    analyticsExploration: exploration
                )
            ).accountTokenActivity

            XCTAssertNil(activity.tokens)
            XCTAssertTrue(activity.intervals.isEmpty)
            XCTAssertEqual(
                activity.reason,
                "No account readings in this range"
            )
        }
    }

    func testRollingDayMergesInterleavedReadingsWithoutDoubleCounting() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let start = now.addingTimeInterval(-6 * 3_600)
        let first = UsageSample(
            observedAt: start,
            remainingPercent: 90,
            resetsAt: reset,
            lifetimeTokens: 1_000
        )
        let middle = UsageSample(
            observedAt: start.addingTimeInterval(2 * 3_600),
            remainingPercent: 85,
            resetsAt: reset,
            lifetimeTokens: 1_200
        )
        let sameCounter = UsageSample(
            observedAt: start.addingTimeInterval(4 * 3_600),
            remainingPercent: 83,
            resetsAt: reset,
            lifetimeTokens: 1_200
        )
        let last = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: reset,
            lifetimeTokens: 1_600
        )
        let singleMac = rollingDayActivity(
            account: account,
            samples: [first, last],
            now: now
        )
        let merged = rollingDayActivity(
            account: account,
            samples: [first, middle, middle, sameCounter, last],
            now: now
        )
        let reversed = rollingDayActivity(
            account: account,
            samples: [first, middle, middle, sameCounter, last].reversed(),
            now: now
        )

        XCTAssertEqual(singleMac.tokens, 600)
        XCTAssertEqual(singleMac.intervals.map(\.tokenDelta), [600])
        XCTAssertEqual(merged.tokens, singleMac.tokens)
        XCTAssertEqual(merged.intervals.map(\.tokenDelta), [200, 0, 400])
        XCTAssertEqual(merged, reversed)
    }

    func testRollingDayOrdersEqualTimestampsDeterministically() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let readings = [
            UsageSample(
                observedAt: now.addingTimeInterval(-3 * 3_600),
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: now.addingTimeInterval(-2 * 3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_100
            ),
            UsageSample(
                observedAt: now.addingTimeInterval(-2 * 3_600),
                remainingPercent: 84,
                resetsAt: reset,
                lifetimeTokens: 1_150
            ),
            UsageSample(
                observedAt: now,
                remainingPercent: 80,
                resetsAt: reset,
                lifetimeTokens: 1_300
            )
        ]

        let ordered = rollingDayActivity(
            account: account,
            samples: readings,
            now: now
        )
        XCTAssertEqual(
            ordered,
            rollingDayActivity(
                account: account,
                samples: readings.reversed(),
                now: now
            )
        )
        XCTAssertEqual(
            ordered.breaks.map(\.reason),
            [.conflictingObservation]
        )
        XCTAssertTrue(ordered.intervals.isEmpty)
    }

    func testRollingDayDoesNotJoinAcrossAllowanceResetsOrAccounts() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let start = now.addingTimeInterval(-4 * 3_600)
        let readings = [
            UsageSample(
                observedAt: start,
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: start.addingTimeInterval(3_600),
                remainingPercent: 88,
                resetsAt: reset.addingTimeInterval(7 * 86_400),
                lifetimeTokens: 1_100
            ),
            UsageSample(
                observedAt: start.addingTimeInterval(2 * 3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_200
            ),
            UsageSample(
                observedAt: now,
                remainingPercent: 80,
                resetsAt: reset,
                lifetimeTokens: 1_300
            )
        ]
        let firstAccount = rollingDayActivity(
            account: account,
            samples: readings,
            now: now,
            accountPartitionID: "account-a"
        )
        let secondAccount = rollingDayActivity(
            account: account,
            samples: readings,
            now: now,
            accountPartitionID: "account-b"
        )

        XCTAssertEqual(firstAccount.tokens, 100)
        XCTAssertEqual(firstAccount.intervals.count, 1)
        XCTAssertEqual(firstAccount.intervals.first?.start, readings[2].observedAt)
        XCTAssertEqual(
            firstAccount.breaks.map(\.reason),
            [.allowanceWindowChange, .allowanceWindowChange]
        )
        XCTAssertEqual(
            firstAccount.intervals.map(\.accountPartitionID),
            ["account-a"]
        )
        XCTAssertEqual(
            secondAccount.intervals.map(\.accountPartitionID),
            ["account-b"]
        )
    }

    func testRollingDayPreservesIntervalsOnBothSidesOfCounterDecrease() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let start = now.addingTimeInterval(-4 * 3_600)
        let readings = [
            UsageSample(
                observedAt: start,
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: start.addingTimeInterval(3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_500
            ),
            UsageSample(
                observedAt: start.addingTimeInterval(2 * 3_600),
                remainingPercent: 83,
                resetsAt: reset,
                lifetimeTokens: 1_200
            ),
            UsageSample(
                observedAt: now,
                remainingPercent: 80,
                resetsAt: reset,
                lifetimeTokens: 1_400
            )
        ]

        let activity = rollingDayActivity(
            account: account,
            samples: readings,
            now: now
        )

        XCTAssertEqual(activity.tokens, 700)
        XCTAssertEqual(activity.intervals.map(\.tokenDelta), [500, 200])
        XCTAssertEqual(
            activity.breaks,
            [AccountTokenActivityBreak(
                timestamp: readings[2].observedAt,
                reason: .counterDecrease
            )]
        )
        XCTAssertTrue(activity.intervals.allSatisfy { $0.tokenDelta >= 0 })
        XCTAssertFalse(activity.intervals.contains {
            $0.start < readings[2].observedAt
                && $0.end >= readings[2].observedAt
        })
    }

    func testRollingDayBreaksAtInvalidAndCorrectionReadings() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let start = now.addingTimeInterval(-5 * 3_600)
        let readings = [
            UsageSample(
                observedAt: start,
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: start.addingTimeInterval(3_600),
                remainingPercent: 88,
                resetsAt: reset,
                lifetimeTokens: nil
            ),
            UsageSample(
                observedAt: start.addingTimeInterval(2 * 3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_200
            ),
            UsageSample(
                observedAt: start.addingTimeInterval(3 * 3_600),
                remainingPercent: 83,
                resetsAt: reset,
                lifetimeTokens: 1_300,
                comparisonBreak: true
            ),
            UsageSample(
                observedAt: now.addingTimeInterval(-3_600),
                remainingPercent: 81,
                resetsAt: reset,
                lifetimeTokens: 1_400
            ),
            UsageSample(
                observedAt: now,
                remainingPercent: 80,
                resetsAt: reset,
                lifetimeTokens: 1_500
            )
        ]

        let activity = rollingDayActivity(
            account: account,
            samples: readings,
            now: now
        )

        XCTAssertEqual(activity.tokens, 200)
        XCTAssertEqual(activity.intervals.map(\.tokenDelta), [100, 100])
        XCTAssertEqual(
            activity.breaks.map(\.reason),
            [.invalidCounter, .correction]
        )
    }

    func testRollingDayBreaksAtAccountObservationEpoch() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let epoch = now.addingTimeInterval(-2 * 3_600)
        let readings = [
            UsageSample(
                observedAt: epoch.addingTimeInterval(-3_600),
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: epoch.addingTimeInterval(3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_200
            ),
            UsageSample(
                observedAt: now,
                remainingPercent: 80,
                resetsAt: reset,
                lifetimeTokens: 1_300
            )
        ]

        let activity = rollingDayActivity(
            account: account,
            samples: readings,
            now: now,
            accountEpochStartedAt: epoch
        )

        XCTAssertEqual(activity.tokens, 100)
        XCTAssertEqual(activity.breaks.map(\.reason), [.accountChange])
        XCTAssertEqual(activity.breaks.first?.timestamp, epoch)
    }

    func testRollingDayLifetimeIntervalsTakePrecedenceOverDailyBuckets() throws {
        let now = try date("2026-08-03T00:00:00Z")
        let bucketStart = try date("2026-08-02T00:00:00Z")
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            tokenHistory: [TokenDay(
                date: bucketStart,
                tokens: 900,
                completeness: .complete
            )]
        )
        let reset = account.mainLimit!.window.resetsAt
        let readings = [
            UsageSample(
                observedAt: bucketStart.addingTimeInterval(6 * 3_600),
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: bucketStart.addingTimeInterval(12 * 3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_300
            )
        ]

        let activity = rollingDayActivity(
            account: account,
            samples: readings,
            now: now
        )

        XCTAssertEqual(activity.method, .lifetimeDelta)
        XCTAssertEqual(activity.tokens, 300)
        XCTAssertEqual(activity.intervals.count, 1)
        XCTAssertEqual(activity.intervals.first?.method, .lifetimeDelta)
    }

    func testRollingDayFallsBackToACompleteUTCDailyBucket() throws {
        let now = try date("2026-08-03T00:00:00Z")
        let bucketStart = try date("2026-08-02T00:00:00Z")
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            tokenHistory: [TokenDay(
                date: bucketStart,
                tokens: 900,
                completeness: .complete
            )]
        )

        let activity = rollingDayActivity(
            account: account,
            samples: [],
            now: now
        )

        XCTAssertEqual(activity.method, .dailyBuckets)
        XCTAssertEqual(activity.tokens, 900)
        XCTAssertEqual(activity.sourceDescription, "Codex UTC daily token totals")
        XCTAssertEqual(
            activity.interval,
            DateInterval(start: bucketStart, end: now)
        )
        XCTAssertEqual(activity.intervals.map(\.method), [.dailyBuckets])
    }

    func testCompleteContiguousUTCDaysExactlyCoverAThreeDayRange() throws {
        let now = try date("2026-08-04T00:00:00Z")
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            tokenHistory: [1, 2, 3].map { day in
                TokenDay(
                    date: now.addingTimeInterval(TimeInterval(-day * 86_400)),
                    tokens: Int64(day * 100),
                    completeness: .complete
                )
            }
        )

        let activity = rollingDayActivity(
            account: account,
            samples: [],
            now: now,
            timeRange: .threeDays
        )

        XCTAssertEqual(activity.state, .exact)
        XCTAssertEqual(activity.tokens, 600)
        XCTAssertEqual(activity.intervals.count, 3)
    }

    func testUTCFallbackPreservesDetectedCounterBreaks() throws {
        let now = try date("2026-08-03T00:00:00Z")
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            tokenHistory: [TokenDay(
                date: now.addingTimeInterval(-86_400),
                tokens: 900,
                completeness: .complete
            )]
        )
        let reset = account.mainLimit!.window.resetsAt
        let readings = [
            UsageSample(
                observedAt: now.addingTimeInterval(-7_200),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 2_000
            ),
            UsageSample(
                observedAt: now.addingTimeInterval(-3_600),
                remainingPercent: 80,
                resetsAt: reset,
                lifetimeTokens: 1_000
            )
        ]

        let activity = rollingDayActivity(
            account: account,
            samples: readings,
            now: now
        )

        XCTAssertEqual(activity.method, .dailyBuckets)
        XCTAssertEqual(activity.breaks.map(\.reason), [.counterDecrease])
    }

    func testRollingDayExcludesPartialUTCDailyBuckets() throws {
        let now = try date("2026-08-03T12:00:00Z")
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            tokenHistory: [
                TokenDay(
                    date: try date("2026-08-02T00:00:00Z"),
                    tokens: 800,
                    completeness: .complete
                ),
                TokenDay(
                    date: try date("2026-08-03T00:00:00Z"),
                    tokens: 900,
                    completeness: .complete
                )
            ]
        )

        let activity = rollingDayActivity(
            account: account,
            samples: [],
            now: now
        )

        XCTAssertNil(activity.tokens)
        XCTAssertTrue(activity.intervals.isEmpty)
        XCTAssertEqual(activity.reason, "No account readings in this range")
    }

    func testEveryRollingTokenRangeUsesExactContainedIntervals() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let cases: [(AnalyticsTimeRange, TimeInterval)] = [
            (.threeDays, 3 * 86_400),
            (.fourWeeks, 28 * 86_400),
            (.twelveWeeks, 84 * 86_400)
        ]

        for (timeRange, duration) in cases {
            let rangeStart = now.addingTimeInterval(-duration)
            let readings = [
                UsageSample(
                    observedAt: rangeStart.addingTimeInterval(-60),
                    remainingPercent: 95,
                    resetsAt: reset,
                    lifetimeTokens: 900
                ),
                UsageSample(
                    observedAt: rangeStart,
                    remainingPercent: 90,
                    resetsAt: reset,
                    lifetimeTokens: 1_000
                ),
                UsageSample(
                    observedAt: rangeStart.addingTimeInterval(3_600),
                    remainingPercent: 85,
                    resetsAt: reset,
                    lifetimeTokens: 1_200
                ),
                UsageSample(
                    observedAt: now,
                    remainingPercent: 80,
                    resetsAt: reset,
                    lifetimeTokens: 1_600
                )
            ]

            let activity = rollingDayActivity(
                account: account,
                samples: readings,
                now: now,
                timeRange: timeRange
            )

            XCTAssertEqual(
                activity.range,
                DateInterval(start: rangeStart, end: now),
                timeRange.rawValue
            )
            XCTAssertEqual(activity.range?.duration, duration, timeRange.rawValue)
            XCTAssertEqual(activity.tokens, 600, timeRange.rawValue)
            XCTAssertEqual(
                activity.interval,
                DateInterval(start: rangeStart, end: now),
                timeRange.rawValue
            )
            XCTAssertEqual(activity.intervals.count, 2, timeRange.rawValue)
            XCTAssertFalse(activity.intervals.contains {
                $0.start < rangeStart
            }, timeRange.rawValue)
            XCTAssertFalse(activity.intervals.contains {
                $0.end > now
            }, timeRange.rawValue)
        }
    }

    func testSelectedTokenRangeKeepsExactPersistedBoundariesAcrossRefresh() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let selected = DateInterval(
            start: now.addingTimeInterval(-10 * 86_400),
            end: now.addingTimeInterval(-5 * 86_400)
        )
        let readings = [
            UsageSample(
                observedAt: selected.start.addingTimeInterval(-60),
                remainingPercent: 95,
                resetsAt: reset,
                lifetimeTokens: 900
            ),
            UsageSample(
                observedAt: selected.start,
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: selected.start.addingTimeInterval(3_600),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_200
            ),
            UsageSample(
                observedAt: selected.end,
                remainingPercent: 80,
                resetsAt: reset,
                lifetimeTokens: 1_500
            ),
            UsageSample(
                observedAt: selected.end.addingTimeInterval(60),
                remainingPercent: 79,
                resetsAt: reset,
                lifetimeTokens: 1_600
            )
        ]

        let activity = rollingDayActivity(
            account: account,
            samples: readings,
            now: now,
            timeRange: .selected,
            visibleRange: selected
        )
        let refreshed = rollingDayActivity(
            account: account,
            samples: readings,
            now: now.addingTimeInterval(86_400),
            timeRange: .selected,
            visibleRange: selected
        )

        XCTAssertEqual(activity.range, selected)
        XCTAssertEqual(activity.tokens, 500)
        XCTAssertEqual(activity.interval, selected)
        XCTAssertEqual(activity.intervals.count, 2)
        XCTAssertEqual(refreshed.range, selected)
        XCTAssertEqual(refreshed.intervals, activity.intervals)
        XCTAssertEqual(refreshed.tokens, activity.tokens)
    }

    func testTokenSourcePrecedenceIsEvaluatedInsideEachRange() throws {
        let now = try date("2026-08-03T00:00:00Z")
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            tokenHistory: [
                TokenDay(
                    date: try date("2026-08-01T00:00:00Z"),
                    tokens: 100,
                    completeness: .complete
                ),
                TokenDay(
                    date: try date("2026-08-02T00:00:00Z"),
                    tokens: 200,
                    completeness: .complete
                )
            ]
        )
        let reset = account.mainLimit!.window.resetsAt
        let lifetimeReadings = [
            UsageSample(
                observedAt: try date("2026-07-23T00:00:00Z"),
                remainingPercent: 90,
                resetsAt: reset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: try date("2026-07-24T00:00:00Z"),
                remainingPercent: 85,
                resetsAt: reset,
                lifetimeTokens: 1_300
            )
        ]

        let threeDays = rollingDayActivity(
            account: account,
            samples: lifetimeReadings,
            now: now,
            timeRange: .threeDays
        )
        let twelveWeeks = rollingDayActivity(
            account: account,
            samples: lifetimeReadings,
            now: now,
            timeRange: .twelveWeeks
        )

        XCTAssertEqual(threeDays.method, .dailyBuckets)
        XCTAssertEqual(threeDays.tokens, 300)
        XCTAssertEqual(threeDays.intervals.count, 2)
        XCTAssertEqual(twelveWeeks.method, .lifetimeDelta)
        XCTAssertEqual(twelveWeeks.tokens, 300)
        XCTAssertEqual(twelveWeeks.intervals.count, 1)
    }

    func testReaderPublishesBoundedCurrentUsagePerTokenFacts() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            accountFacts: AccountFacts(
                lifetimeTokens: 1_600,
                peakDailyTokens: nil,
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil,
                credits: nil,
                spendControl: nil
            )
        )
        let reset = try XCTUnwrap(account.mainLimit?.window.resetsAt)
        let boundary = UsageSample(
            observedAt: try XCTUnwrap(account.mainLimit?.window.startsAt),
            remainingPercent: 100,
            resetsAt: reset,
            lifetimeTokens: 1_000
        )
        let current = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: reset,
            lifetimeTokens: 1_600
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [boundary, current],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a"
            )
        )

        XCTAssertEqual(
            reader.usagePerToken.current?.accountMovementPoints,
            20
        )
        XCTAssertEqual(
            reader.usagePerToken.current?.accountTokenActivity,
            600
        )
        XCTAssertNil(reader.usagePerToken.comparison)
        XCTAssertEqual(
            reader.usagePerToken.reason,
            "Account samples are more than 6 hours apart"
        )
    }

    func testReaderPublishesMeasuredActiveTimeWithoutInventingAnEstimate() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let start = now.addingTimeInterval(-3_600)
        let end = now.addingTimeInterval(-1_800)
        let fact = timingFact(
            id: "turn-1",
            taskID: "task-1",
            start: start,
            end: end,
            observedAt: now
        )
        let projection = ThreadProjection(
            taskID: "task-1",
            parentTaskID: nil,
            projectLabel: "atlas",
            rolloutFileURL: nil,
            createdAt: start,
            updatedAt: end,
            source: fact.source
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a",
                localActivityFacts: [fact],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                ),
                localTaskProjections: [projection]
            )
        )

        XCTAssertEqual(
            reader.activeTimeAvailability.activeTimeThisWeek,
            1_800
        )
        XCTAssertEqual(
            reader.activeTimeAvailability.activeTimeCoverage,
            .partial
        )
        XCTAssertNil(reader.activeTimeAvailability.estimate)
        XCTAssertEqual(
            reader.activeTimeAvailability.reason,
            "Current weekly evidence is unavailable"
        )

        let updated = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a",
                localActivityFacts: [
                    fact,
                    timingFact(
                        id: "turn-2",
                        taskID: "task-1",
                        start: now.addingTimeInterval(-1_200),
                        end: now.addingTimeInterval(-600),
                        observedAt: now
                    )
                ],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                ),
                localTaskProjections: [projection]
            )
        )

        XCTAssertEqual(
            updated.activeTimeAvailability.activeTimeThisWeek,
            2_400
        )
    }

    func testReaderEstimatesActiveTimeAndNamesChangedWorkload() throws {
        let firstStart = Date(timeIntervalSince1970: 10_000)
        let weekDuration = 7 * 86_400.0
        let currentStart = firstStart.addingTimeInterval(4 * weekDuration)
        let now = currentStart.addingTimeInterval(4 * 86_400)
        let currentReset = currentStart.addingTimeInterval(weekDuration)
        let account = UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "weekly",
                name: "Weekly",
                window: UsageWindow(
                    remainingPercent: 60,
                    resetsAt: currentReset,
                    durationMinutes: 10_080
                )
            ),
            otherLimits: [],
            tokenHistory: [],
            emergencyResetCount: 0,
            fetchedAt: now,
            accountFacts: AccountFacts(
                lifetimeTokens: 46_000_000,
                peakDailyTokens: nil,
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil,
                credits: nil,
                spendControl: nil,
                lifetimeTokensObservedAt: now
            )
        )
        var samples: [UsageSample] = []
        var historyFacts: [LocalActivityFact] = []
        var projections: [ThreadProjection] = []
        for index in 0 ..< 5 {
            let start = firstStart.addingTimeInterval(
                Double(index) * weekDuration
            )
            let isCurrent = index == 4
            let end = isCurrent ? now : start.addingTimeInterval(weekDuration)
            let reset = start.addingTimeInterval(weekDuration)
            let startTokens = Int64(1_000_000 + index * 10_000_000)
            let endTokens = isCurrent
                ? 46_000_000
                : startTokens + 10_000_000
            samples += weeklySamples(
                start: start,
                end: end,
                reset: reset,
                startRemaining: 100,
                endRemaining: isCurrent ? 60 : 20,
                startTokens: startTokens,
                endTokens: endTokens
            )
            let taskID = "task-\(index)"
            historyFacts.append(
                tokenFact(
                    tokens: isCurrent ? 4_500_000 : 9_000_000,
                    date: start.addingTimeInterval(60),
                    eventID: "tokens-\(index)"
                )
            )
            historyFacts.append(
                timingFact(
                    id: "turn-\(index)",
                    taskID: taskID,
                    start: start.addingTimeInterval(3_600),
                    end: start.addingTimeInterval(
                        (isCurrent ? 6 : 11) * 3_600
                    ),
                    observedAt: end
                )
            )
            projections.append(
                ThreadProjection(
                    taskID: taskID,
                    parentTaskID: nil,
                    projectLabel: "atlas",
                    rolloutFileURL: nil,
                    createdAt: start,
                    updatedAt: end,
                    source: historyFacts.last!.source
                )
            )
        }
        let currentFacts = historyFacts.filter {
            guard let timestamp = $0.eventTimestamp,
                  let date = ISO8601DateFormatter().date(from: timestamp) else {
                return false
            }
            return date >= currentStart
        }

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a",
                localActivityFacts: currentFacts,
                localActivityHistoryFacts: historyFacts,
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                ),
                localTaskProjections: projections,
                compatibleTokenSources: [
                    LocalTokenDefinitionSource(
                        sourceVersion: "0.145.0",
                        schemaVersion: "rollout-jsonl-v1"
                    )
                ]
            )
        )
        let estimate = try XCTUnwrap(
            reader.activeTimeAvailability.estimate
        )

        XCTAssertEqual(estimate.lowerSeconds, 7.5 * 60 * 60)
        XCTAssertEqual(estimate.upperSeconds, 7.5 * 60 * 60)
        XCTAssertEqual(estimate.confidence, .medium)
        XCTAssertEqual(estimate.referenceIntervalIDs.count, 4)
        let pinnedID = try XCTUnwrap(
            reader.usagePerToken.history.last?.id
        )
        var pinnedExploration = AnalyticsExplorationState.initial
        pinnedExploration.pinnedUsageBaselineID = pinnedID
        pinnedExploration.pinnedUsageBaselineAccountPartitionID =
            "account-a"
        let pinnedReader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a",
                localActivityFacts: currentFacts,
                localActivityHistoryFacts: historyFacts,
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                ),
                localTaskProjections: projections,
                compatibleTokenSources: [
                    LocalTokenDefinitionSource(
                        sourceVersion: "0.145.0",
                        schemaVersion: "rollout-jsonl-v1"
                    )
                ],
                analyticsExploration: pinnedExploration
            )
        )

        XCTAssertEqual(
            pinnedReader.usagePerToken.comparison?.baseline.id,
            pinnedID
        )
        XCTAssertTrue(
            pinnedReader.usagePerToken.comparison?.baseline.isPinned
                == true
        )

        let changedHistoryFacts = historyFacts.map { fact in
            guard fact.key == .token,
                  let timestamp = fact.eventTimestamp,
                  let date = ISO8601DateFormatter().date(from: timestamp),
                  date < currentStart,
                  let tokens = fact.tokenDelta?.totalTokens,
                  let eventID = fact.eventID else {
                return fact
            }
            return tokenFact(
                tokens: tokens,
                date: date,
                eventID: eventID,
                model: "gpt-5.6-luna"
            )
        }
        let changedReader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a",
                localActivityFacts: currentFacts,
                localActivityHistoryFacts: changedHistoryFacts,
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                ),
                localTaskProjections: projections,
                compatibleTokenSources: [
                    LocalTokenDefinitionSource(
                        sourceVersion: "0.145.0",
                        schemaVersion: "rollout-jsonl-v1"
                    )
                ]
            )
        )

        XCTAssertNil(changedReader.activeTimeAvailability.estimate)
        XCTAssertEqual(
            changedReader.activeTimeAvailability.reason,
            "Recent workload mix is not comparable"
        )
    }

    func testReaderUsesHistoricalFactsOnlyForHistoricalWeeklyEvidence() throws {
        let now = Date(timeIntervalSince1970: 8_000_000)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            accountFacts: AccountFacts(
                lifetimeTokens: 16_000_000,
                peakDailyTokens: nil,
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil,
                credits: nil,
                spendControl: nil,
                lifetimeTokensObservedAt: now
            )
        )
        let currentReset = try XCTUnwrap(account.mainLimit?.window.resetsAt)
        let currentStart = try XCTUnwrap(account.mainLimit?.window.startsAt)
        let previousReset = currentStart
        let previousStart = previousReset.addingTimeInterval(-7 * 86_400)
        let samples = [
            UsageSample(
                observedAt: previousStart,
                remainingPercent: 100,
                resetsAt: previousReset,
                lifetimeTokens: 1_000_000
            ),
            UsageSample(
                observedAt: previousReset,
                remainingPercent: 60,
                resetsAt: previousReset,
                lifetimeTokens: 11_000_000
            ),
            UsageSample(
                observedAt: currentStart,
                remainingPercent: 100,
                resetsAt: currentReset,
                lifetimeTokens: 11_000_000
            ),
            UsageSample(
                observedAt: now,
                remainingPercent: 80,
                resetsAt: currentReset,
                lifetimeTokens: 16_000_000
            )
        ]
        let pastFact = tokenFact(
            tokens: 9_000_000,
            date: previousStart.addingTimeInterval(60),
            eventID: "past"
        )
        let currentFact = tokenFact(
            tokens: 4_000_000,
            date: currentStart.addingTimeInterval(60),
            eventID: "current"
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a",
                localActivityFacts: [currentFact],
                localActivityHistoryFacts: [pastFact, currentFact],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                )
            )
        )

        XCTAssertEqual(reader.localTokenActivity.tokens, 4_000_000)
        XCTAssertEqual(
            reader.usagePerToken.current?.localTokenActivity,
            4_000_000
        )
        XCTAssertEqual(
            reader.usagePerToken.history.first?.localTokenActivity,
            9_000_000
        )
        XCTAssertNil(reader.usagePerToken.current?.localCoveragePercent)
        XCTAssertFalse(
            try XCTUnwrap(
                reader.usagePerToken.current
            ).tokenDefinitionsAlign
        )
    }

    func testPreservedLifetimeReadingDoesNotExtendTheExactInterval() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let observedAt = now.addingTimeInterval(-600)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            accountFacts: AccountFacts(
                lifetimeTokens: 1_600,
                peakDailyTokens: nil,
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil,
                credits: nil,
                spendControl: nil,
                lifetimeTokensObservedAt: observedAt
            )
        )
        let boundary = UsageSample(
            observedAt: account.mainLimit!.window.startsAt.addingTimeInterval(5 * 60),
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
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.accountTokenActivity.state, .partial)
        XCTAssertEqual(
            reader.accountTokenActivity.interval,
            DateInterval(start: boundary.observedAt, end: observedAt)
        )
    }

    func testPreservedLifetimeReadingDoesNotInheritANewerAllowanceReset() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let observedAt = now.addingTimeInterval(-6 * 86_400)
        let oldReset = now.addingTimeInterval(-4 * 86_400)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            accountFacts: AccountFacts(
                lifetimeTokens: 1_200,
                peakDailyTokens: nil,
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil,
                credits: nil,
                spendControl: nil,
                lifetimeTokensObservedAt: observedAt
            )
        )
        let samples = [
            UsageSample(
                observedAt: now.addingTimeInterval(-7 * 86_400),
                remainingPercent: 90,
                resetsAt: oldReset,
                lifetimeTokens: 1_000
            ),
            UsageSample(
                observedAt: observedAt,
                remainingPercent: 85,
                resetsAt: oldReset,
                lifetimeTokens: 1_200
            )
        ]
        var exploration = AnalyticsExplorationState.initial
        exploration.timeRange = .twelveWeeks

        let activity = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                analyticsExploration: exploration
            )
        ).accountTokenActivity

        XCTAssertEqual(activity.tokens, 200)
        XCTAssertTrue(activity.breaks.isEmpty)
    }

    func testCompleteDailyBucketsProducePartialAccountTokenActivity() throws {
        let fetchedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-28T12:00:00Z")
        )
        let calendar = Calendar(identifier: .gregorian)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: fetchedAt,
            tokenHistory: [
                TokenDay(
                    date: try XCTUnwrap(
                        ISO8601DateFormatter().date(from: "2026-07-24T00:00:00Z")
                    ),
                    tokens: 100,
                    completeness: .complete
                ),
                TokenDay(
                    date: try XCTUnwrap(
                        ISO8601DateFormatter().date(from: "2026-07-25T00:00:00Z")
                    ),
                    tokens: 200,
                    completeness: .complete
                ),
                TokenDay(
                    date: try XCTUnwrap(
                        ISO8601DateFormatter().date(from: "2026-07-28T00:00:00Z")
                    ),
                    tokens: 900,
                    completeness: .partial
                )
            ],
            accountFacts: AccountFacts(
                lifetimeTokens: 1_600,
                peakDailyTokens: nil,
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil,
                credits: nil,
                spendControl: nil
            )
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: fetchedAt,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.accountTokenActivity.state, .partial)
        XCTAssertEqual(reader.accountTokenActivity.tokens, 300)
        XCTAssertEqual(reader.accountTokenActivity.method, .dailyBuckets)
        XCTAssertEqual(
            reader.accountTokenActivity.interval,
            DateInterval(
                start: try XCTUnwrap(
                    ISO8601DateFormatter().date(from: "2026-07-24T00:00:00Z")
                ),
                end: try XCTUnwrap(
                    calendar.date(
                        byAdding: .day,
                        value: 1,
                        to: ISO8601DateFormatter().date(
                            from: "2026-07-25T00:00:00Z"
                        )!
                    )
                )
            )
        )
        XCTAssertNil(reader.accountTokenActivity.reason)
    }

    func testAlignedCompleteDailyBucketsProduceExactAccountTokenActivity() throws {
        let formatter = ISO8601DateFormatter()
        let fetchedAt = try XCTUnwrap(
            formatter.date(from: "2026-07-28T00:00:00Z")
        )
        let dates = [
            "2026-07-23T00:00:00Z",
            "2026-07-24T00:00:00Z",
            "2026-07-25T00:00:00Z",
            "2026-07-26T00:00:00Z",
            "2026-07-27T00:00:00Z"
        ]
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: fetchedAt,
            tokenHistory: try dates.map {
                TokenDay(
                    date: try XCTUnwrap(formatter.date(from: $0)),
                    tokens: 100,
                    completeness: .complete
                )
            }
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: fetchedAt,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.accountTokenActivity.state, .partial)
        XCTAssertEqual(reader.accountTokenActivity.tokens, 500)
        XCTAssertEqual(reader.accountTokenActivity.method, .dailyBuckets)
        XCTAssertEqual(
            reader.accountTokenActivity.interval,
            DateInterval(
                start: account.mainLimit!.window.startsAt,
                end: fetchedAt
            )
        )
        XCTAssertNil(reader.accountTokenActivity.reason)
    }

    func testDecreasedLifetimeCounterWithholdsAccountTokenActivity() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            accountFacts: AccountFacts(
                lifetimeTokens: 900,
                peakDailyTokens: nil,
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil,
                credits: nil,
                spendControl: nil
            )
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
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.accountTokenActivity.state, .unavailable)
        XCTAssertNil(reader.accountTokenActivity.tokens)
        XCTAssertEqual(
            reader.accountTokenActivity.breaks.map(\.reason),
            [.counterDecrease]
        )
    }

    func testInvalidLifetimeCounterWithholdsAccountTokenActivity() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            accountFacts: AccountFacts(
                lifetimeTokens: .max,
                peakDailyTokens: nil,
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil,
                credits: nil,
                spendControl: nil
            )
        )
        let boundary = UsageSample(
            observedAt: account.mainLimit!.window.startsAt,
            remainingPercent: 100,
            resetsAt: account.mainLimit!.window.resetsAt,
            lifetimeTokens: -1
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [boundary],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.accountTokenActivity.state, .unavailable)
        XCTAssertNil(reader.accountTokenActivity.tokens)
        XCTAssertEqual(
            reader.accountTokenActivity.breaks.map(\.reason),
            [.invalidCounter]
        )
    }

    func testFreshDenseHistoryProducesHighConfidenceGuidance() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 20, fetchedAt: now)
        let samples = denseSamples(
            account: account,
            firstOffset: 10 * 60,
            step: 30 * 60
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.evidence.coverage, .high)
        XCTAssertEqual(reader.evidence.confidence, .high)
        XCTAssertEqual(reader.evidence.policyVersion, 1)
        XCTAssertEqual(
            reader.evidenceText,
            "Derived estimate · High coverage · High confidence"
        )
        XCTAssertEqual(reader.guidance?.status, .slowDown)
        XCTAssertEqual(reader.guidance?.title, "Slow down")
        XCTAssertEqual(reader.guidance?.source, .derivedEstimate)
        XCTAssertEqual(
            reader.guidance?.message,
            "At this pace, your limit may run out 23 hours early."
        )
        XCTAssertEqual(
            reader.guidance?.suggestedPace,
            "Up to 8.5 percentage points a day"
        )
        XCTAssertNotNil(reader.guidance?.runway)
        XCTAssertNil(reader.guidance?.remainingAtResetRange)
        XCTAssertNil(reader.guidance?.caveat)
        XCTAssertEqual(
            reader.insights.insights.first(where: {
                $0.kind == .pace
            })?.title,
            "Slow down"
        )
        XCTAssertEqual(
            reader.insights.insights.first(where: {
                $0.kind == .pace
            })?.source,
            "Derived estimate"
        )
        XCTAssertEqual(
            reader.chart.target,
            [
                UsageChartPoint(
                    date: account.mainLimit!.window.startsAt,
                    remaining: 100
                ),
                UsageChartPoint(
                    date: account.mainLimit!.window.resetsAt,
                    remaining: 3
                )
            ]
        )
        XCTAssertEqual(
            reader.chart.observed.last,
            UsageChartPoint(date: now, remaining: 20)
        )
        XCTAssertEqual(reader.chart.currentProjection.count, 2)
        XCTAssertTrue(reader.chart.historicalProjection.isEmpty)
        XCTAssertEqual(
            reader.chart.accessibilityValue,
            "Now has 20 percent remaining. At reset, the current pace leaves 0 percent."
        )
    }

    func testLooseBoundaryProducesStaleMediumConfidenceGuidance() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let fetchedAt = now.addingTimeInterval(-42 * 60)
        let account = makeSnapshot(remaining: 60, fetchedAt: fetchedAt)
        let samples = denseSamples(
            account: account,
            firstOffset: 42 * 60,
            step: 2 * 3_600
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.freshness, .stale)
        XCTAssertEqual(reader.evidence.coverage, .partial)
        XCTAssertEqual(reader.evidence.confidence, .medium)
        XCTAssertEqual(reader.evidence.reason, "Account boundary is 42 minutes late")
        XCTAssertNotNil(reader.guidance)
        XCTAssertNotNil(reader.guidance?.remainingAtResetRange)
        XCTAssertEqual(reader.guidance?.caveat, "Account boundary is 42 minutes late")
    }

    func testRefreshFailureKeepsFactsAndWithholdsGuidance() {
        let now = Date(timeIntervalSince1970: 4_000_000)
        let account = makeSnapshot(remaining: 41, fetchedAt: now.addingTimeInterval(-600))
        let samples = [
            UsageSample(
                observedAt: now.addingTimeInterval(-1_200),
                remainingPercent: 42,
                resetsAt: account.mainLimit!.window.resetsAt
            ),
            UsageSample(
                observedAt: now.addingTimeInterval(-600),
                remainingPercent: 41,
                resetsAt: account.mainLimit!.window.resetsAt
            )
        ]

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .failed("Couldn’t read Codex usage. Try refreshing again."),
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.account, account)
        XCTAssertEqual(reader.menuBarText, "41%")
        XCTAssertEqual(reader.freshness, .stale)
        XCTAssertEqual(reader.evidence.coverage, .low)
        XCTAssertEqual(reader.evidence.confidence, .low)
        XCTAssertNil(reader.guidance)
        XCTAssertTrue(reader.chart.currentProjection.isEmpty)
        XCTAssertTrue(reader.chart.historicalProjection.isEmpty)
        XCTAssertEqual(
            reader.guidanceTitle,
            "Couldn’t read Codex usage. Try refreshing again."
        )
        XCTAssertEqual(
            reader.guidanceMessage,
            "Couldn’t read Codex usage. Try refreshing again."
        )
        XCTAssertNil(reader.suggestedPacePercentPerDay)
        XCTAssertEqual(
            reader.suggestedPaceText,
            "Couldn’t read Codex usage. Try refreshing again."
        )
    }

    func testReaderFormatsFreshnessFromSuppliedTime() {
        let fetchedAt = Date(timeIntervalSince1970: 5_000_000)
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: makeSnapshot(remaining: 55, fetchedAt: fetchedAt),
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: fetchedAt,
                previousStatus: nil
            )
        )

        XCTAssertEqual(
            reader.updatedText(at: fetchedAt.addingTimeInterval(3_600)),
            "Updated 1 hr ago"
        )
    }

    func testShortDenseTailDoesNotQualifyAsHighCoverage() {
        let now = Date(timeIntervalSince1970: 5_500_000)
        let account = makeSnapshot(remaining: 55, fetchedAt: now)
        let samples = stride(from: 60, through: 10, by: -10).map { minutesAgo in
            UsageSample(
                observedAt: now.addingTimeInterval(-Double(minutesAgo) * 60),
                remainingPercent: 55,
                resetsAt: account.mainLimit!.window.resetsAt
            )
        }

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.evidence.coverage, .low)
        XCTAssertEqual(reader.evidence.confidence, .low)
        XCTAssertEqual(reader.evidence.reason, "Less than half of this weekly window is observed")
        XCTAssertNotNil(reader.guidance)
        XCTAssertFalse(reader.chart.currentProjection.isEmpty)
    }

    func testLowCoverageChartStillShowsCurrentAndPastEstimates() {
        let now = Date(timeIntervalSince1970: 5_600_000)
        let day: TimeInterval = 86_400
        let account = makeSnapshot(
            remaining: 55,
            fetchedAt: now,
            tokenHistory: (-33 ... -6).map {
                TokenDay(
                    date: now.addingTimeInterval(Double($0) * day),
                    tokens: 200
                )
            } + (-5 ... -1).map {
                TokenDay(
                    date: now.addingTimeInterval(Double($0) * day),
                    tokens: 100
                )
            }
        )
        let currentWindow = account.mainLimit!.window
        let previousReset = currentWindow.startsAt
        let history = weeklySamples(
            start: previousReset.addingTimeInterval(-5 * day),
            end: previousReset.addingTimeInterval(-3 * day),
            reset: previousReset,
            startRemaining: 80,
            endRemaining: 40,
            startTokens: 1_000,
            endTokens: 2_000
        )
        let recent = stride(from: 60, through: 10, by: -10).map { minutesAgo in
            UsageSample(
                observedAt: now.addingTimeInterval(-Double(minutesAgo) * 60),
                remainingPercent: 55,
                resetsAt: currentWindow.resetsAt
            )
        }

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: history + recent,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.evidence.confidence, .low)
        XCTAssertNotNil(reader.guidance)
        XCTAssertEqual(reader.chart.currentProjection.count, 2)
        XCTAssertEqual(reader.chart.historicalProjection.count, 2)
        XCTAssertTrue(reader.chart.estimatedBackfill.isEmpty)
        XCTAssertEqual(
            reader.chart.historicalProjection.last?.remaining ?? .nan,
            15,
            accuracy: 0.000_001
        )
    }

    func testOutOfWindowHistoryDoesNotCreatePastEstimate() {
        let now = Date(timeIntervalSince1970: 5_700_000)
        let account = makeSnapshot(remaining: 55, fetchedAt: now)
        let priorReset = account.mainLimit!.window.startsAt
        let stale = weeklySamples(
            start: priorReset.addingTimeInterval(-9 * 86_400),
            end: priorReset.addingTimeInterval(-8 * 86_400),
            reset: priorReset,
            startRemaining: 80,
            endRemaining: 40,
            startTokens: 1_000,
            endTokens: 2_000
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: stale,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertTrue(reader.chart.historicalProjection.isEmpty)
    }

    func testSparseHistoryDoesNotCreatePastEstimate() {
        let now = Date(timeIntervalSince1970: 5_800_000)
        let account = makeSnapshot(remaining: 55, fetchedAt: now)
        let priorReset = account.mainLimit!.window.startsAt
        let sparse = [
            UsageSample(
                observedAt: priorReset.addingTimeInterval(-2 * 86_400),
                remainingPercent: 80,
                resetsAt: priorReset
            ),
            UsageSample(
                observedAt: priorReset.addingTimeInterval(-2 * 86_400 + 6 * 3_600),
                remainingPercent: 40,
                resetsAt: priorReset
            )
        ]

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: sparse,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertTrue(reader.chart.historicalProjection.isEmpty)
    }

    func testTokenBucketsNeverBecomeObservedAllowancePoints() {
        let now = Date(timeIntervalSince1970: 5_750_000)
        let account = makeSnapshot(
            remaining: 55,
            fetchedAt: now,
            tokenHistory: [
                TokenDay(
                    date: now.addingTimeInterval(-3 * 86_400),
                    tokens: 1_000
                )
            ]
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(
            reader.chart.observed,
            [
                UsageChartPoint(date: now, remaining: 55)
            ]
        )
        XCTAssertTrue(reader.chart.historicalProjection.isEmpty)
    }

    func testTokenBackfillUsesItsOwnEstimatedSeriesAndSource() {
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 100 * day)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            tokenHistory: (-33 ... -1).map {
                TokenDay(
                    date: now.addingTimeInterval(Double($0) * day),
                    tokens: $0 < -5 ? 200 : 100
                )
            }
        )
        let samples = denseSamples(
            account: account,
            firstOffset: 10 * 60,
            step: 30 * 60
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertTrue(reader.chart.historicalProjection.isEmpty)
        XCTAssertEqual(reader.chart.estimatedBackfill.count, 2)
        XCTAssertEqual(
            reader.chart.historicalReferenceSource,
            .tokenEstimate
        )
    }

    func testCorrectionRestoresGuidanceAfterSecondReading() {
        let now = Date(timeIntervalSince1970: 5_900_000)
        let account = makeSnapshot(remaining: 70, fetchedAt: now)
        var samples = denseSamples(
            account: account,
            firstOffset: 0,
            step: 30 * 60
        )
        samples.append(
            UsageSample(
                observedAt: now.addingTimeInterval(-15 * 60),
                remainingPercent: 85,
                resetsAt: account.mainLimit!.window.resetsAt
            )
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.evidence.coverage, .low)
        XCTAssertEqual(reader.evidence.confidence, .low)
        XCTAssertEqual(reader.evidence.reason, "Unknown reset or correction")
        XCTAssertNotNil(reader.guidance)
        XCTAssertEqual(reader.chart.observedSegments.count, 2)
        XCTAssertEqual(reader.chart.observedSegments.flatMap { $0 }, reader.chart.observed)
    }

    func testUnknownCorrectionStartsANewMediumConfidenceInterval() {
        let now = Date(timeIntervalSince1970: 6_050_000)
        let account = makeSnapshot(remaining: 70, fetchedAt: now)
        let correctionAt = now.addingTimeInterval(-26 * 3_600)
        let samples = [
            UsageSample(
                observedAt: correctionAt.addingTimeInterval(-30 * 60),
                remainingPercent: 30,
                resetsAt: account.mainLimit!.window.resetsAt
            ),
            UsageSample(
                observedAt: correctionAt,
                remainingPercent: 90,
                resetsAt: account.mainLimit!.window.resetsAt
            )
        ] + stride(from: 25.5, through: 0.5, by: -0.5).map { hoursAgo in
            UsageSample(
                observedAt: now.addingTimeInterval(-hoursAgo * 3_600),
                remainingPercent: 70 + hoursAgo / 1.275,
                resetsAt: account.mainLimit!.window.resetsAt
            )
        }

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.evidence.coverage, .partial)
        XCTAssertEqual(reader.evidence.confidence, .medium)
        XCTAssertEqual(reader.evidence.reason, "Unknown reset or correction")
        XCTAssertNotNil(reader.guidance)
    }

    func testRunwayShowsWhenUsageEndsAndHowLongBeforeReset() {
        let now = Date(timeIntervalSince1970: 6_100_000)
        let account = makeSnapshot(remaining: 20, fetchedAt: now)
        let samples = denseSamples(
            account: account,
            firstOffset: 0,
            step: 30 * 60
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        guard case let .exhausts(_, beforeReset) = reader.guidance?.runway else {
            return XCTFail("Expected an exhaustion estimate")
        }
        XCTAssertGreaterThan(beforeReset, 0)
        XCTAssertTrue(reader.guidance?.runway.gapText?.contains("before reset") == true)
    }

    func testFiveHourLimitIsNeverUsedWhenWeeklyUsageIsMissing() {
        let now = Date(timeIntervalSince1970: 6_200_000)
        let fiveHour = LimitReading(
            limitId: "codex",
            name: "Codex",
            window: UsageWindow(
                remainingPercent: 70,
                resetsAt: now.addingTimeInterval(3_600),
                durationMinutes: 300
            )
        )
        let account = UsageSnapshot(
            mainLimit: nil,
            otherLimits: [fiveHour],
            tokenHistory: [],
            emergencyResetCount: 0,
            fetchedAt: now
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertNil(reader.weeklyUsageRemaining)
        XCTAssertEqual(reader.evidence.coverage, .unavailable)
        XCTAssertEqual(
            reader.evidence.reason,
            "No current weekly allowance reading"
        )
        XCTAssertNil(reader.guidance)
        XCTAssertTrue(reader.chart.observed.isEmpty)
    }

    func testWorkloadMixChangeCapsOtherwiseHighEvidence() {
        let now = Date(timeIntervalSince1970: 6_300_000)
        let account = makeSnapshot(remaining: 70, fetchedAt: now)
        let samples = denseSamples(
            account: account,
            firstOffset: 0,
            step: 30 * 60
        )
        let currentStart = account.mainLimit!.window.startsAt
        let facts = modelFacts(
            model: "gpt-current",
            dates: (0 ..< 10).map {
                now.addingTimeInterval(-Double($0 + 1) * 60)
            }
        ) + modelFacts(
            model: "gpt-previous",
            dates: (0 ..< 10).map {
                currentStart.addingTimeInterval(-Double($0 + 1) * 60)
            }
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                localActivityFacts: facts,
                localActivityObservation: .continuous(
                    sourceVersion: "test",
                    observedAt: now
                ),
                localActivityContentRevision: 7
            )
        )
        let reused = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                localActivityFacts: [],
                localActivityObservation: .continuous(
                    sourceVersion: "test",
                    observedAt: now
                ),
                localActivityContentRevision: 7,
                reusableLocalAggregates: reader.reusableLocalAggregates
            )
        )

        XCTAssertEqual(reader.evidence.coverage, .partial)
        XCTAssertEqual(reader.evidence.confidence, .medium)
        XCTAssertEqual(reader.evidence.reason, "Workload mix changed")
        XCTAssertEqual(reused.evidence, reader.evidence)
    }

    func testKnownResetKeepsObservedWindowsSeparate() {
        let now = Date(timeIntervalSince1970: 6_400_000)
        let account = makeSnapshot(remaining: 70, fetchedAt: now)
        let currentReset = account.mainLimit!.window.resetsAt
        let previousReset = currentReset.addingTimeInterval(-7 * 86_400)
        let samples = [
            UsageSample(
                observedAt: previousReset.addingTimeInterval(-86_400),
                remainingPercent: 40,
                resetsAt: previousReset
            ),
            UsageSample(
                observedAt: previousReset,
                remainingPercent: 30,
                resetsAt: previousReset
            )
        ] + denseSamples(
            account: account,
            firstOffset: 0,
            step: 30 * 60
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(
            reader.chart.allowanceWindows.map(\.resetsAt),
            [previousReset, currentReset]
        )
        XCTAssertEqual(
            reader.chart.allowanceWindows.first?
                .observedSegments.flatMap { $0 }.count,
            2
        )
        XCTAssertFalse(
            reader.chart.allowanceWindows.last?
                .observedSegments.flatMap { $0 }.isEmpty ?? true
        )
    }

    func testAccountEpochDoesNotHideStoredChartPoints() {
        let now = Date(timeIntervalSince1970: 6_400_000)
        let account = makeSnapshot(remaining: 70, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let beforeEpoch = now.addingTimeInterval(-2 * 3_600)
        let afterEpoch = now.addingTimeInterval(-30 * 60)
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [
                    UsageSample(
                        observedAt: beforeEpoch,
                        remainingPercent: 80,
                        resetsAt: reset
                    ),
                    UsageSample(
                        observedAt: afterEpoch,
                        remainingPercent: 72,
                        resetsAt: reset
                    )
                ],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountEpochStartedAt: now.addingTimeInterval(-3_600)
            )
        )

        XCTAssertTrue(
            reader.chart.observed.contains { $0.date == beforeEpoch }
        )
    }

    func testSparseHistoryWithholdsGuidance() {
        let now = Date(timeIntervalSince1970: 6_000_000)
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: makeSnapshot(remaining: 55, fetchedAt: now),
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.evidence.coverage, .low)
        XCTAssertEqual(reader.evidence.confidence, .low)
        XCTAssertEqual(reader.evidence.reason, "Not enough account history")
        XCTAssertNil(reader.guidance)
        XCTAssertEqual(
            reader.guidanceTitle,
            "At least two compatible account readings are needed"
        )
    }

    func testRecentMovementUsesTwoReadingsFromLessThanTwentyFourHours() throws {
        let now = Date(timeIntervalSince1970: 6_005_000)
        let account = makeSnapshot(remaining: 70, fetchedAt: now)
        let first = UsageSample(
            observedAt: now.addingTimeInterval(-6 * 3_600),
            remainingPercent: 75,
            resetsAt: account.mainLimit!.window.resetsAt
        )

        let reader = makeReader(account: account, samples: [first], now: now)
        let forecast = try XCTUnwrap(reader.guidance?.forecast)

        XCTAssertEqual(forecast.currentPercentPerDay, 20, accuracy: 0.000_001)
        XCTAssertEqual(reader.chart.currentProjection.first?.date, now)
        XCTAssertEqual(reader.chart.currentProjection.first?.remaining, 70)
    }

    func testRecentMovementUsesExactRollingDayAndExcludesOlderReadings() throws {
        let now = Date(timeIntervalSince1970: 6_006_000)
        let account = makeSnapshot(remaining: 70, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let boundary = UsageSample(
            observedAt: now.addingTimeInterval(-86_400),
            remainingPercent: 90,
            resetsAt: reset
        )
        let reader = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: now.addingTimeInterval(-25 * 3_600),
                    remainingPercent: 100,
                    resetsAt: reset
                ),
                boundary
            ],
            now: now
        )
        let forecast = try XCTUnwrap(reader.guidance?.forecast)

        XCTAssertEqual(forecast.currentPercentPerDay, 20, accuracy: 0.000_001)
    }

    func testLongCompatibleIntervalIsFactualCurrentMovement() throws {
        let now = Date(timeIntervalSince1970: 6_007_000)
        let account = makeSnapshot(remaining: 70, fetchedAt: now)
        let gap = 8 * 3_600 + 36 * 60
        let reader = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: now.addingTimeInterval(-Double(gap)),
                    remainingPercent: 80,
                    resetsAt: account.mainLimit!.window.resetsAt
                )
            ],
            now: now
        )
        let forecast = try XCTUnwrap(reader.guidance?.forecast)

        XCTAssertEqual(
            forecast.currentPercentPerDay,
            10 / (Double(gap) / 86_400),
            accuracy: 0.000_001
        )
        XCTAssertNotNil(reader.guidance)
        XCTAssertEqual(reader.chart.currentProjection.count, 2)
    }

    func testZeroRecentMovementLastsThroughResetAndProjectsFlat() throws {
        let now = Date(timeIntervalSince1970: 6_008_000)
        let account = makeSnapshot(remaining: 50, fetchedAt: now)
        let reader = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: now.addingTimeInterval(-3_600),
                    remainingPercent: 50,
                    resetsAt: account.mainLimit!.window.resetsAt
                )
            ],
            now: now
        )

        XCTAssertEqual(reader.guidance?.runway, .throughReset)
        XCTAssertEqual(reader.runwayText, "Limit should last through reset")
        XCTAssertEqual(reader.guidance?.forecast.currentPercentPerDay, 0)
        XCTAssertEqual(
            reader.chart.currentProjection.last,
            UsageChartPoint(
                date: account.mainLimit!.window.resetsAt,
                remaining: 50
            )
        )
    }

    func testZeroRecentMovementKeepsPrimaryGuidanceConsistentWithFastHistory() {
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 6_008_500)
        let account = makeSnapshot(
            remaining: 50,
            fetchedAt: now,
            tokenHistory: (-33 ... -6).map {
                TokenDay(
                    date: now.addingTimeInterval(Double($0) * day),
                    tokens: 400
                )
            } + (-5 ... -1).map {
                TokenDay(
                    date: now.addingTimeInterval(Double($0) * day),
                    tokens: 100
                )
            }
        )
        let reader = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: now.addingTimeInterval(-3_600),
                    remainingPercent: 50,
                    resetsAt: account.mainLimit!.window.resetsAt
                )
            ],
            now: now
        )

        XCTAssertEqual(reader.guidance?.forecast.currentPercentPerDay, 0)
        XCTAssertEqual(reader.guidance?.status, .roomToUseMore)
        XCTAssertEqual(reader.guidance?.runway, .throughReset)
        XCTAssertEqual(
            reader.chart.currentProjection.last?.remaining,
            50
        )
    }

    func testPastEstimateRemainsWhenCurrentMovementNeedsAnotherReading() {
        let now = Date(timeIntervalSince1970: 6_008_750)
        let account = makeSnapshot(remaining: 70, fetchedAt: now)
        let priorReset = account.mainLimit!.window.startsAt
        let history = weeklySamples(
            start: priorReset.addingTimeInterval(-12 * 3_600),
            end: priorReset,
            reset: priorReset,
            startRemaining: 80,
            endRemaining: 60,
            startTokens: 1_000,
            endTokens: 2_000
        )
        let reader = makeReader(account: account, samples: history, now: now)

        XCTAssertNil(reader.guidance)
        XCTAssertTrue(reader.chart.currentProjection.isEmpty)
        XCTAssertEqual(reader.chart.historicalProjection.count, 2)
    }

    func testAllowanceBreaksNeedOneThenTwoNewReadings() {
        let now = Date(timeIntervalSince1970: 6_009_000)
        let account = makeSnapshot(
            remaining: 70,
            fetchedAt: now,
            resetAfter: 7 * 86_400 - 4 * 3_600
        )
        let reset = account.mainLimit!.window.resetsAt
        let previousReset = account.mainLimit!.window.startsAt

        let afterResetWaiting = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: previousReset,
                    remainingPercent: 40,
                    resetsAt: previousReset
                )
            ],
            now: now
        )
        let afterResetRestored = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: previousReset,
                    remainingPercent: 40,
                    resetsAt: previousReset
                ),
                UsageSample(
                    observedAt: previousReset.addingTimeInterval(3_600),
                    remainingPercent: 80,
                    resetsAt: reset
                )
            ],
            now: now
        )
        let afterCorrectionWaiting = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: now,
                    remainingPercent: 70,
                    resetsAt: reset,
                    comparisonBreak: true
                )
            ],
            now: now
        )
        let afterCorrectionRestored = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: now.addingTimeInterval(-3_600),
                    remainingPercent: 80,
                    resetsAt: reset,
                    comparisonBreak: true
                )
            ],
            now: now
        )
        let afterIncreaseWaiting = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: now.addingTimeInterval(-3_600),
                    remainingPercent: 50,
                    resetsAt: reset
                )
            ],
            now: now
        )
        let afterIncreaseRestored = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: now.addingTimeInterval(-2 * 3_600),
                    remainingPercent: 50,
                    resetsAt: reset
                ),
                UsageSample(
                    observedAt: now.addingTimeInterval(-3_600),
                    remainingPercent: 80,
                    resetsAt: reset
                )
            ],
            now: now
        )
        let accountChanged = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountEpochStartedAt: now
            )
        )
        let accountRecovered = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [
                    UsageSample(
                        observedAt: now.addingTimeInterval(-3_600),
                        remainingPercent: 80,
                        resetsAt: reset,
                        comparisonBreak: true
                    )
                ],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountEpochStartedAt: now.addingTimeInterval(-3_600)
            )
        )

        XCTAssertEqual(
            afterResetWaiting.guidanceUnavailableReason,
            "Waiting for a second account reading after reset or correction"
        )
        XCTAssertNotNil(afterResetRestored.guidance)
        XCTAssertEqual(
            afterCorrectionWaiting.guidanceUnavailableReason,
            "Waiting for a second account reading after reset or correction"
        )
        XCTAssertNotNil(afterCorrectionRestored.guidance)
        XCTAssertEqual(
            afterIncreaseWaiting.guidanceUnavailableReason,
            "Waiting for a second account reading after reset or correction"
        )
        XCTAssertNotNil(afterIncreaseRestored.guidance)
        XCTAssertEqual(
            accountChanged.guidanceUnavailableReason,
            "Account changed — waiting for a second reading"
        )
        XCTAssertNotNil(accountRecovered.guidance)
    }

    func testRunwayAndCurrentEstimateSharePaceAndLatestReading() throws {
        let now = Date(timeIntervalSince1970: 6_009_500)
        let account = makeSnapshot(remaining: 20, fetchedAt: now)
        let reader = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: now.addingTimeInterval(-12 * 3_600),
                    remainingPercent: 80,
                    resetsAt: account.mainLimit!.window.resetsAt
                )
            ],
            now: now
        )
        let forecast = try XCTUnwrap(reader.guidance?.forecast)
        let firstProjection = try XCTUnwrap(reader.chart.currentProjection.first)
        let lastProjection = try XCTUnwrap(reader.chart.currentProjection.last)
        guard case let .exhausts(runwayEnd, _) = reader.guidance?.runway else {
            return XCTFail("Expected current pace to exhaust the allowance")
        }

        XCTAssertEqual(firstProjection.date, account.fetchedAt)
        XCTAssertEqual(firstProjection.remaining, 20)
        XCTAssertEqual(forecast.currentPercentPerDay, 120, accuracy: 0.000_001)
        XCTAssertEqual(lastProjection.date, runwayEnd)
    }

    func testRefreshFailureRecoversWithoutExtendingObservedFacts() {
        let now = Date(timeIntervalSince1970: 6_009_750)
        let fetchedAt = now.addingTimeInterval(-10 * 60)
        let account = makeSnapshot(remaining: 70, fetchedAt: fetchedAt)
        let samples = [
            UsageSample(
                observedAt: fetchedAt.addingTimeInterval(-3_600),
                remainingPercent: 80,
                resetsAt: account.mainLimit!.window.resetsAt
            )
        ]
        let failed = makeReader(
            account: account,
            samples: samples,
            sourceState: .failed("Account source failed"),
            now: now
        )
        let recovered = makeReader(
            account: account,
            samples: samples,
            now: now
        )

        XCTAssertNil(failed.guidance)
        XCTAssertEqual(failed.guidanceTitle, "Account source failed")
        XCTAssertEqual(failed.chart.observed.last?.date, fetchedAt)
        XCTAssertTrue(failed.chart.currentProjection.isEmpty)
        XCTAssertNil(failed.suggestedPacePercentPerDay)
        XCTAssertNotNil(recovered.guidance)
        XCTAssertFalse(recovered.chart.currentProjection.isEmpty)
        XCTAssertNotNil(recovered.suggestedPacePercentPerDay)
    }

    func testProductionGapShapeStillProducesCurrentGuidance() throws {
        let now = Date(timeIntervalSince1970: 6_009_900)
        let account = makeSnapshot(remaining: 60, fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        let gapStart = now.addingTimeInterval(-(47 * 3_600 + 27 * 60))
        let denseStart = gapStart.addingTimeInterval(8 * 3_600 + 36 * 60)
        var samples = [
            UsageSample(
                observedAt: gapStart,
                remainingPercent: 92,
                resetsAt: reset
            )
        ]
        samples += stride(
            from: denseStart.timeIntervalSince1970,
            to: now.timeIntervalSince1970,
            by: 20 * 60
        ).map { timestamp in
            let progress = (timestamp - denseStart.timeIntervalSince1970)
                / now.timeIntervalSince(denseStart)
            return UsageSample(
                observedAt: Date(timeIntervalSince1970: timestamp),
                remainingPercent: 85 - 25 * progress,
                resetsAt: reset
            )
        }
        let maximumGap = zip(samples, samples.dropFirst())
            .map { $1.observedAt.timeIntervalSince($0.observedAt) }
            .max() ?? 0
        let reader = makeReader(account: account, samples: samples, now: now)
        let withoutHistory = makeReader(account: account, now: now)

        XCTAssertGreaterThan(maximumGap, 6 * 3_600)
        XCTAssertGreaterThan(now.timeIntervalSince(denseStart), 24 * 3_600)
        XCTAssertNotNil(reader.guidance)
        XCTAssertFalse(reader.chart.currentProjection.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(reader.suggestedPacePercentPerDay),
            try XCTUnwrap(withoutHistory.suggestedPacePercentPerDay),
            accuracy: 0.000_001
        )
    }

    func testSuggestedPaceNeedsOnlyCurrentReadingAndUsesExactFractionalDay() throws {
        let now = Date(timeIntervalSince1970: 6_010_000)
        let reader = makeReader(
            account: makeSnapshot(
                remaining: 23,
                fetchedAt: now,
                resetAfter: 12 * 60 * 60
            ),
            now: now
        )

        let pace = try XCTUnwrap(reader.suggestedPacePercentPerDay)
        XCTAssertEqual(pace, 40, accuracy: 0.000_001)
        XCTAssertTrue(pace.isFinite)
        XCTAssertGreaterThanOrEqual(pace, 0)
        XCTAssertEqual(
            reader.suggestedPaceText,
            "Up to 40.0 percentage points a day"
        )
        XCTAssertNil(reader.guidance)
    }

    func testSuggestedPaceIgnoresLongAccountHistoryGap() throws {
        let now = Date(timeIntervalSince1970: 6_020_000)
        let account = makeSnapshot(remaining: 40, fetchedAt: now)
        let withoutHistory = makeReader(account: account, now: now)
        let withLongGap = makeReader(
            account: account,
            samples: [
                UsageSample(
                    observedAt: account.mainLimit!.window.startsAt,
                    remainingPercent: 100,
                    resetsAt: account.mainLimit!.window.resetsAt
                ),
                UsageSample(
                    observedAt: now,
                    remainingPercent: 40,
                    resetsAt: account.mainLimit!.window.resetsAt
                )
            ],
            now: now
        )

        XCTAssertEqual(withLongGap.evidence.coverage, .low)
        XCTAssertEqual(
            try XCTUnwrap(withLongGap.suggestedPacePercentPerDay),
            try XCTUnwrap(withoutHistory.suggestedPacePercentPerDay),
            accuracy: 0.000_001
        )
    }

    func testSuggestedPaceClampsAllowanceAtOrBelowBufferToZero() throws {
        let now = Date(timeIntervalSince1970: 6_030_000)
        let cases: [(remaining: Double, expected: Double)] = [
            (100, 48.5),
            (3, 0),
            (2, 0),
            (0, 0)
        ]

        for testCase in cases {
            let reader = makeReader(
                account: makeSnapshot(
                    remaining: testCase.remaining,
                    fetchedAt: now
                ),
                now: now
            )
            let pace = try XCTUnwrap(reader.suggestedPacePercentPerDay)

            XCTAssertEqual(pace, testCase.expected, accuracy: 0.000_001)
            XCTAssertTrue(pace.isFinite)
            XCTAssertGreaterThanOrEqual(pace, 0)
        }
    }

    func testSuggestedPaceUsesSpecificUnavailableReasons() {
        let now = Date(timeIntervalSince1970: 6_040_000)
        let sourceError = "Couldn’t read Codex usage. Try refreshing again."
        let missing = makeReader(account: nil, now: now)
        let atReset = makeReader(
            account: makeSnapshot(
                remaining: 50,
                fetchedAt: now.addingTimeInterval(-2 * 86_400)
            ),
            now: now
        )
        let expired = makeReader(
            account: makeSnapshot(
                remaining: 50,
                fetchedAt: now.addingTimeInterval(-3 * 86_400)
            ),
            now: now
        )
        let failed = makeReader(
            account: makeSnapshot(remaining: 50, fetchedAt: now),
            sourceState: .failed(sourceError),
            now: now
        )

        XCTAssertNil(missing.suggestedPacePercentPerDay)
        XCTAssertEqual(missing.suggestedPaceText, "Weekly usage unavailable")
        XCTAssertNil(atReset.suggestedPacePercentPerDay)
        XCTAssertEqual(
            atReset.suggestedPaceText,
            "Current allowance window unavailable"
        )
        XCTAssertNil(expired.suggestedPacePercentPerDay)
        XCTAssertEqual(
            expired.suggestedPaceText,
            "Current allowance window unavailable"
        )
        XCTAssertNil(failed.suggestedPacePercentPerDay)
        XCTAssertEqual(failed.suggestedPaceText, sourceError)
    }

    func testCompleteCoverageNeedsTheWholeWindowWithoutMaterialGaps() {
        let step: TimeInterval = 30 * 60
        let now = Date(timeIntervalSince1970: 7_000_000)
        let account = makeSnapshot(remaining: 70, fetchedAt: now)
        let start = account.mainLimit!.window.startsAt
        let samples = stride(
            from: start.timeIntervalSince1970,
            through: now.timeIntervalSince1970,
            by: step
        ).map {
            UsageSample(
                observedAt: Date(timeIntervalSince1970: $0),
                remainingPercent: 70,
                resetsAt: account.mainLimit!.window.resetsAt
            )
        }

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.evidence.coverage, .complete)
        XCTAssertEqual(reader.evidence.confidence, .high)
        XCTAssertNil(reader.evidence.reason)
    }

    func testUnavailableAndEndedWindowsDoNotProduceConfidence() {
        let now = Date(timeIntervalSince1970: 8_000_000)
        let unavailable = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: nil,
                samples: [],
                safetyBuffer: 3,
                sourceState: .failed("Weekly usage unavailable"),
                now: now,
                previousStatus: nil
            )
        )
        let endedAccount = makeSnapshot(
            remaining: 100,
            fetchedAt: now.addingTimeInterval(-3 * 86_400)
        )
        let ended = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: endedAccount,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(unavailable.evidence.coverage, .unavailable)
        XCTAssertEqual(unavailable.evidence.confidence, .unavailable)
        XCTAssertEqual(unavailable.freshness, .unavailable)
        XCTAssertEqual(ended.evidence.coverage, .notApplicable)
        XCTAssertEqual(ended.evidence.confidence, .unavailable)
        XCTAssertTrue(ended.chart.currentProjection.isEmpty)
        XCTAssertTrue(ended.chart.historicalProjection.isEmpty)
    }

    func testCurrentWindowUsesFullAllowanceFrameAndStopsObservedSeries() throws {
        let start = try date("2026-08-01T12:13:00Z")
        let latestObservation = try date("2026-08-03T12:13:00Z")
        let reset = try date("2026-08-08T12:13:00Z")
        let account = UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "codex",
                name: "Codex",
                window: UsageWindow(
                    remainingPercent: 70,
                    resetsAt: reset,
                    durationMinutes: 10_080
                )
            ),
            otherLimits: [],
            tokenHistory: [
                TokenDay(
                    date: latestObservation.addingTimeInterval(-86_400),
                    tokens: 1_000,
                    completeness: .complete
                )
            ],
            emergencyResetCount: 0,
            fetchedAt: latestObservation
        )
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [
                    UsageSample(
                        observedAt: start,
                        remainingPercent: 100,
                        resetsAt: reset,
                        lifetimeTokens: 1_000
                    ),
                    UsageSample(
                        observedAt: latestObservation,
                        remainingPercent: 70,
                        resetsAt: reset,
                        lifetimeTokens: 1_300
                    )
                ],
                safetyBuffer: 3,
                sourceState: .available,
                now: latestObservation,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.interval?.startsAt, start)
        XCTAssertEqual(reader.interval?.resetsAt, reset)
        XCTAssertEqual(reader.chart.target.map(\.date), [start, reset])
        XCTAssertEqual(reader.chart.observed.map(\.date).max(), latestObservation)
        XCTAssertFalse(reader.chart.observed.contains { $0.date > latestObservation })
        XCTAssertEqual(
            reader.accountTokenActivity.range,
            DateInterval(start: start, end: reset)
        )
        XCTAssertEqual(reader.accountTokenActivity.tokens, 300)
        XCTAssertEqual(
            reader.accountTokenActivity.interval,
            DateInterval(start: start, end: latestObservation)
        )
        XCTAssertEqual(reader.accountTokenActivity.intervals.count, 1)
        XCTAssertTrue(
            reader.accountTokenActivity.currentWindowAccessibilityValue
                .contains("300 account tokens so far")
        )

        let refreshedWithoutReading = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [
                    UsageSample(
                        observedAt: start,
                        remainingPercent: 100,
                        resetsAt: reset,
                        lifetimeTokens: 1_000
                    ),
                    UsageSample(
                        observedAt: latestObservation,
                        remainingPercent: 70,
                        resetsAt: reset,
                        lifetimeTokens: 1_300
                    )
                ],
                safetyBuffer: 3,
                sourceState: .available,
                now: latestObservation.addingTimeInterval(3_600),
                previousStatus: nil
            )
        )
        XCTAssertEqual(
            refreshedWithoutReading.accountTokenActivity.intervals,
            reader.accountTokenActivity.intervals
        )
    }

    func testCurrentWindowDistinguishesZeroFromNoInterval() throws {
        let start = try date("2026-08-01T12:13:00Z")
        let now = try date("2026-08-03T12:13:00Z")
        let reset = try date("2026-08-08T12:13:00Z")
        let account = UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "codex",
                name: "Codex",
                window: UsageWindow(
                    remainingPercent: 70,
                    resetsAt: reset,
                    durationMinutes: 10_080
                )
            ),
            otherLimits: [],
            tokenHistory: [],
            emergencyResetCount: 0,
            fetchedAt: now
        )
        let first = UsageSample(
            observedAt: start,
            remainingPercent: 100,
            resetsAt: reset,
            lifetimeTokens: 1_000
        )
        let zero = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [
                    first,
                    UsageSample(
                        observedAt: now,
                        remainingPercent: 70,
                        resetsAt: reset,
                        lifetimeTokens: 1_000
                    )
                ],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        ).accountTokenActivity
        let missing = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [first],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        ).accountTokenActivity

        XCTAssertEqual(zero.tokens, 0)
        XCTAssertEqual(zero.intervals.first?.tokenDelta, 0)
        XCTAssertTrue(
            zero.currentWindowAccessibilityValue
                .contains("observed zero-token interval")
        )
        XCTAssertTrue(
            zero.currentWindowAccessibilityValue
                .contains("missing, not zero")
        )
        XCTAssertTrue(
            zero.currentWindowAccessibilityValue
                .contains("future and has no observation")
        )
        XCTAssertNil(missing.tokens)
        XCTAssertEqual(missing.reason, "No account readings in this range")
    }

    func testExpiredCurrentWindowIsUnavailableButKeepsHistoricalSamples() throws {
        let reset = try date("2026-08-08T12:13:00Z")
        let historicalObservation = try date("2026-08-03T12:13:00Z")
        let account = UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "codex",
                name: "Codex",
                window: UsageWindow(
                    remainingPercent: 70,
                    resetsAt: reset,
                    durationMinutes: 10_080
                )
            ),
            otherLimits: [],
            tokenHistory: [],
            emergencyResetCount: 0,
            fetchedAt: historicalObservation
        )
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [
                    UsageSample(
                        observedAt: historicalObservation,
                        remainingPercent: 75,
                        resetsAt: reset
                    )
                ],
                safetyBuffer: 3,
                sourceState: .available,
                now: try date("2026-08-09T12:13:00Z"),
                previousStatus: nil
            )
        )

        XCTAssertNil(reader.weeklyUsageRemaining)
        XCTAssertNil(reader.interval)
        XCTAssertEqual(reader.evidence.reason, "Current allowance window unavailable")
        XCTAssertEqual(reader.guidanceTitle, "Current allowance window unavailable")
        XCTAssertTrue(reader.chart.allObserved.contains {
            $0.date == historicalObservation
        })
        XCTAssertEqual(
            reader.accountTokenActivity.reason,
            "Current allowance window unavailable"
        )
        XCTAssertTrue(reader.accountTokenActivity.intervals.isEmpty)
    }

    func testQuietDenseHistoryLeavesRoomToUseMore() {
        let now = Date(timeIntervalSince1970: 9_000_000)
        let account = makeSnapshot(remaining: 40, fetchedAt: now)
        let historicalReset = account.mainLimit!.window.startsAt
        let historical = [
            UsageSample(
                observedAt: historicalReset.addingTimeInterval(-5 * 86_400),
                remainingPercent: 100,
                resetsAt: historicalReset
            ),
            UsageSample(
                observedAt: historicalReset,
                remainingPercent: 75,
                resetsAt: historicalReset
            )
        ]
        let recent = denseSamples(
            account: account,
            firstOffset: 10 * 60,
            step: 30 * 60
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: historical + recent,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertEqual(reader.guidance?.status, .roomToUseMore)
        XCTAssertEqual(reader.guidanceTitle, "Room to use more")
    }

    func testPreviousSlowDownStatusUsesExistingHysteresis() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let reset = now.addingTimeInterval(3 * 86_400)
        let window = UsageWindow(
            remainingPercent: 49.210526,
            resetsAt: reset,
            durationMinutes: 10_080
        )
        let account = UsageSnapshot(
            mainLimit: LimitReading(limitId: "codex", name: "Codex", window: window),
            otherLimits: [],
            tokenHistory: [],
            emergencyResetCount: 0,
            fetchedAt: now
        )
        let samples = denseSamples(
            account: account,
            firstOffset: 10 * 60,
            step: 30 * 60
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: .slowDown
            )
        )

        XCTAssertEqual(reader.guidance?.forecast.safetyRemainingAtReset ?? 0, 3.5, accuracy: 0.01)
        XCTAssertEqual(reader.guidance?.status, .slowDown)
    }

    func testIdenticalInputProducesIdenticalReaderSnapshot() {
        let now = Date(timeIntervalSince1970: 11_000_000)
        let input = UsageIntelligenceInput(
            account: makeSnapshot(remaining: 80, fetchedAt: now),
            samples: [],
            safetyBuffer: 3,
            sourceState: .available,
            now: now,
            previousStatus: nil
        )

        XCTAssertEqual(
            UsageIntelligenceEngine.evaluate(input),
            UsageIntelligenceEngine.evaluate(input)
        )
    }

    func testBankedResetSummaryUsesCountAndCompleteKnownExpiryDetail() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            emergencyResetCount: 2,
            bankedResetDetails: [
                resetDetail(id: "later", expiresAt: now.addingTimeInterval(8 * 86_400)),
                resetDetail(id: "earlier", expiresAt: now.addingTimeInterval(3 * 86_400))
            ]
        )

        let summary = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        ).bankedResets

        XCTAssertEqual(summary?.availableCount, 2)
        XCTAssertEqual(summary?.detailCoverage, .complete)
        XCTAssertEqual(summary?.knownExpiryCount, 2)
        XCTAssertEqual(
            summary?.nextKnownExpiry,
            now.addingTimeInterval(3 * 86_400)
        )
        XCTAssertEqual(
            summary?.inlineText(at: now),
            "2 banked resets · Next expires in 3 days"
        )
        XCTAssertTrue(
            summary?.inspectionText(at: now).contains(
                now.addingTimeInterval(3 * 86_400).formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            ) == true
        )
    }

    func testBankedResetSummaryExcludesExpiredDetailAndMarksPartialCoverage() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            emergencyResetCount: 3,
            bankedResetDetails: [
                resetDetail(id: "expired", expiresAt: now.addingTimeInterval(-60)),
                resetDetail(id: "known", expiresAt: now.addingTimeInterval(8 * 86_400))
            ]
        )

        let summary = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        ).bankedResets

        XCTAssertEqual(summary?.detailCoverage, .partial)
        XCTAssertEqual(summary?.knownExpiryCount, 1)
        XCTAssertEqual(
            summary?.nextKnownExpiry,
            now.addingTimeInterval(8 * 86_400)
        )
        XCTAssertEqual(
            summary?.inlineText(at: now),
            "3 banked resets · 1 expiry known · Next known in 8 days"
        )
    }

    func testBankedResetSummaryDistinguishesUnavailableDetailAndZeroCount() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let unavailable = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            emergencyResetCount: 2,
            bankedResetDetails: nil
        )
        let zero = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            emergencyResetCount: 0,
            bankedResetDetails: []
        )

        let unavailableSummary = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: unavailable,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        ).bankedResets
        let zeroSummary = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: zero,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        ).bankedResets

        XCTAssertEqual(unavailableSummary?.detailCoverage, .unavailable)
        XCTAssertNil(unavailableSummary?.nextKnownExpiry)
        XCTAssertEqual(
            unavailableSummary?.inlineText(at: now),
            "2 banked resets · Expiry dates unavailable"
        )
        XCTAssertEqual(zeroSummary?.detailCoverage, .complete)
        XCTAssertEqual(zeroSummary?.knownExpiryCount, 0)
        XCTAssertNil(zeroSummary?.nextKnownExpiry)
        XCTAssertEqual(zeroSummary?.inlineText(at: now), "0 banked resets")
    }

    func testBankedResetSummaryWithholdsAnUnavailableCount() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(
            remaining: 80,
            fetchedAt: now,
            emergencyResetCount: 0,
            bankedResetCountAvailable: false
        )

        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil
            )
        )

        XCTAssertNil(reader.bankedResets)
    }

    func testBankedResetCountdownStopsAfterTheKnownExpiryPasses() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let summary = BankedResetSummary(
            availableCount: 1,
            detailCoverage: .complete,
            knownExpiryCount: 1,
            nextKnownResetID: "reset-1",
            nextKnownExpiry: now.addingTimeInterval(60),
            observedAt: now,
            freshness: .fresh,
            sourceState: .available
        )

        XCTAssertEqual(
            summary.inlineText(at: now.addingTimeInterval(61)),
            "1 banked reset · Expiry dates need refresh"
        )
        XCTAssertNil(
            summary.currentNextKnownExpiry(
                at: now.addingTimeInterval(61)
            )
        )
        XCTAssertTrue(
            summary.inspectionText(
                at: now.addingTimeInterval(61)
            ).contains("Expiry dates need refresh")
        )
    }

    func testStableRevisionReusesLocalAggregatesAcrossLaterAccountRead() throws {
        let observedAt = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: observedAt)
        let observation = LocalActivityObservation.continuous(
            sourceVersion: "0.145.0",
            observedAt: observedAt
        )
        let first = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: observedAt,
                previousStatus: nil,
                localActivityFacts: [
                    tokenFact(
                        tokens: 100,
                        date: observedAt.addingTimeInterval(-30),
                        eventID: "token-1"
                    )
                ],
                localActivityObservation: observation,
                localActivityContentRevision: 7
            )
        )
        let later = observedAt.addingTimeInterval(60)
        let laterObservation = LocalActivityObservation.continuous(
            sourceVersion: "0.145.0",
            observedAt: later
        )
        let laterAccount = UsageSnapshot(
            mainLimit: account.mainLimit,
            otherLimits: account.otherLimits,
            tokenHistory: account.tokenHistory,
            emergencyResetCount: account.emergencyResetCount,
            bankedResetCountAvailable: account.bankedResetCountAvailable,
            bankedResetDetails: account.bankedResetDetails,
            fetchedAt: later,
            accountFacts: account.accountFacts
        )

        let reused = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: laterAccount,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: later,
                previousStatus: nil,
                localActivityFacts: [],
                localActivityObservation: laterObservation,
                localActivityContentRevision: 7,
                reusableLocalAggregates:
                    try XCTUnwrap(first.reusableLocalAggregates)
            )
        )
        let rebuilt = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: laterAccount,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: later,
                previousStatus: nil,
                localActivityFacts: [],
                localActivityObservation: laterObservation,
                localActivityContentRevision: 8,
                reusableLocalAggregates:
                    try XCTUnwrap(first.reusableLocalAggregates)
            )
        )

        XCTAssertEqual(reused.localTokenActivity.tokens, 100)
        XCTAssertEqual(reused.localTokenActivity.interval.end, later)
        XCTAssertEqual(rebuilt.localTokenActivity.tokens, 0)
    }

    func testStableRevisionReusesHistoryIndexButAppliesNewAccountSample() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: now)
        let window = try XCTUnwrap(account.mainLimit?.window)
        let earlier = now.addingTimeInterval(-60)
        let earlierAccount = UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "codex",
                name: "Codex",
                window: UsageWindow(
                    remainingPercent: 90,
                    resetsAt: window.resetsAt,
                    durationMinutes: window.durationMinutes
                )
            ),
            otherLimits: [],
            tokenHistory: [],
            emergencyResetCount: 0,
            bankedResetDetails: nil,
            fetchedAt: earlier
        )
        let startSample = UsageSample(
            observedAt: window.startsAt,
            remainingPercent: 100,
            resetsAt: window.resetsAt,
            lifetimeTokens: 1_000
        )
        let earlierSample = UsageSample(
            observedAt: earlier,
            remainingPercent: 90,
            resetsAt: window.resetsAt,
            lifetimeTokens: 1_500
        )
        let freshSample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: window.resetsAt,
            lifetimeTokens: 1_600
        )
        let fact = tokenFact(
            tokens: 500,
            date: earlier.addingTimeInterval(-60),
            eventID: "token-1"
        )
        let compatibleSources: Set<LocalTokenDefinitionSource> = [
            LocalTokenDefinitionSource(
                sourceVersion: "0.145.0",
                schemaVersion: "rollout-jsonl-v1"
            )
        ]
        let first = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: earlierAccount,
                samples: [startSample, earlierSample],
                safetyBuffer: 3,
                sourceState: .available,
                now: earlier,
                previousStatus: nil,
                accountPartitionID: "account-a",
                localActivityFacts: [fact],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: earlier
                ),
                localActivityContentRevision: 7,
                compatibleTokenSources: compatibleSources
            )
        )

        let refreshed = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [startSample, earlierSample, freshSample],
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: "account-a",
                localActivityFacts: [fact],
                localActivityHistoryFacts: [fact],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: now
                ),
                localActivityContentRevision: 7,
                reusableLocalAggregates:
                    try XCTUnwrap(first.reusableLocalAggregates),
                compatibleTokenSources: compatibleSources
            )
        )

        XCTAssertEqual(
            refreshed.usagePerToken.current?.accountMovementPoints,
            20
        )
        XCTAssertEqual(
            refreshed.usagePerToken.current?.accountTokenActivity,
            600
        )
        XCTAssertEqual(
            refreshed.usagePerToken.current?.localTokenActivity,
            500
        )
    }

    func testStableRevisionRebuildsAfterTemporaryObservationGap() throws {
        let observedAt = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: observedAt)
        let fact = tokenFact(
            tokens: 100,
            date: observedAt.addingTimeInterval(-30),
            eventID: "token-1"
        )
        let first = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: observedAt,
                previousStatus: nil,
                localActivityFacts: [fact],
                localActivityObservation: .gap(
                    sourceVersion: "0.145.0",
                    observedAt: observedAt,
                    reason: "Codex account identity could not be checked"
                ),
                localActivityContentRevision: 7
            )
        )
        let recovered = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: observedAt,
                previousStatus: nil,
                localActivityFacts: [fact],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: observedAt
                ),
                localActivityContentRevision: 7,
                reusableLocalAggregates:
                    try XCTUnwrap(first.reusableLocalAggregates)
            )
        )

        XCTAssertEqual(first.localTokenActivity.coverage, .low)
        XCTAssertEqual(recovered.localTokenActivity.coverage, .high)
        XCTAssertEqual(
            recovered.localTokenActivity.reason,
            "Only local activity on this Mac is observed"
        )
    }

    func testStableRevisionRebuildsWhenPreviousEndBoundaryBecomesIncluded() throws {
        let observedAt = Date(timeIntervalSince1970: 2_000_000)
        let account = makeSnapshot(remaining: 80, fetchedAt: observedAt)
        let observation = LocalActivityObservation.continuous(
            sourceVersion: "0.145.0",
            observedAt: observedAt
        )
        let boundaryFact = tokenFact(
            tokens: 250,
            date: observedAt,
            eventID: "boundary-token"
        )
        let first = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: observedAt,
                previousStatus: nil,
                localActivityFacts: [boundaryFact],
                localActivityObservation: observation,
                localActivityContentRevision: 7
            )
        )
        let later = observedAt.addingTimeInterval(60)
        let laterAccount = UsageSnapshot(
            mainLimit: account.mainLimit,
            otherLimits: account.otherLimits,
            tokenHistory: account.tokenHistory,
            emergencyResetCount: account.emergencyResetCount,
            bankedResetCountAvailable: account.bankedResetCountAvailable,
            bankedResetDetails: account.bankedResetDetails,
            fetchedAt: later,
            accountFacts: account.accountFacts
        )

        let refreshed = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: laterAccount,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: later,
                previousStatus: nil,
                localActivityFacts: [boundaryFact],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: later
                ),
                localActivityContentRevision: 7,
                reusableLocalAggregates:
                    try XCTUnwrap(first.reusableLocalAggregates)
            )
        )

        XCTAssertEqual(first.localTokenActivity.tokens, 0)
        XCTAssertEqual(refreshed.localTokenActivity.tokens, 250)
    }

    func testDisplayDownsamplingKeepsTheFirstAndLastPoint() {
        let points = Array(0 ..< 10_000)

        let rendered = downsampledForDisplay(points, limit: 100)

        XCTAssertEqual(rendered.count, 100)
        XCTAssertEqual(rendered.first, 0)
        XCTAssertEqual(rendered.last, 9_999)
    }

    func testNearestDisplayPointUsesChronologicalNeighbors() {
        let points = (0 ..< 100_000).map {
            LocalTokenActivityPoint(
                date: Date(timeIntervalSince1970: TimeInterval($0 * 10)),
                tokens: Int64($0)
            )
        }

        XCTAssertEqual(
            nearestPoint(
                in: points,
                to: Date(timeIntervalSince1970: 123_456),
                date: \.date
            )?.tokens,
            12_346
        )
        XCTAssertEqual(
            nearestPoint(
                in: points,
                to: Date(timeIntervalSince1970: -1),
                date: \.date
            )?.tokens,
            0
        )
    }

    func testNearestDisplayPointIncludesTheRangeEnd() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let points = [
            LocalTokenActivityPoint(date: start, tokens: 1),
            LocalTokenActivityPoint(date: end, tokens: 2)
        ]

        XCTAssertEqual(
            nearestPoint(
                in: points,
                to: end,
                date: \.date,
                within: DateInterval(start: start, end: end)
            )?.tokens,
            2
        )
    }

    private func makeSnapshot(
        remaining: Double,
        fetchedAt: Date,
        resetAfter: TimeInterval = 2 * 86_400,
        tokenHistory: [TokenDay] = [],
        accountFacts: AccountFacts? = nil,
        emergencyResetCount: Int = 0,
        bankedResetCountAvailable: Bool? = true,
        bankedResetDetails: [BankedResetDetail]? = nil
    ) -> UsageSnapshot {
        let window = UsageWindow(
            remainingPercent: remaining,
            resetsAt: fetchedAt.addingTimeInterval(resetAfter),
            durationMinutes: 10_080
        )
        return UsageSnapshot(
            mainLimit: LimitReading(limitId: "codex", name: "Codex", window: window),
            otherLimits: [],
            tokenHistory: tokenHistory,
            emergencyResetCount: emergencyResetCount,
            bankedResetCountAvailable: bankedResetCountAvailable,
            bankedResetDetails: bankedResetDetails,
            fetchedAt: fetchedAt,
            accountFacts: accountFacts
        )
    }

    private func makeReader(
        account: UsageSnapshot?,
        samples: [UsageSample] = [],
        safetyBuffer: Double = 3,
        sourceState: UsageSourceState = .available,
        now: Date
    ) -> UsageReaderSnapshot {
        UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: samples,
                safetyBuffer: safetyBuffer,
                sourceState: sourceState,
                now: now,
                previousStatus: nil
            )
        )
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func timingFact(
        id: String,
        taskID: String,
        start: Date,
        end: Date,
        observedAt: Date
    ) -> LocalActivityFact {
        LocalActivityFact(
            key: .time,
            availability: .available,
            value: .turnTiming(
                LocalTurnTiming(
                    startedAt: start,
                    completedAt: end,
                    durationMilliseconds: Int64(
                        end.timeIntervalSince(start) * 1_000
                    ),
                    timeToFirstTokenMilliseconds: nil
                )
            ),
            numericDelta: nil,
            tokenSegment: nil,
            reason: nil,
            eventID: id,
            eventTimestamp: ISO8601DateFormatter().string(from: start),
            source: LocalActivitySourceMetadata(
                source: .rolloutJSONL,
                sourceVersion: "0.145.0",
                schemaVersion: "rollout-v1",
                sourceGeneration: 0,
                historyMode: "paginated",
                observedAt: observedAt
            ),
            context: LocalActivityContext(
                taskID: taskID,
                turnID: id,
                agent: nil,
                effectiveModel: "gpt-5.6-sol",
                reasoning: "high"
            )
        )
    }

    private func resetDetail(
        id: String,
        expiresAt: Date
    ) -> BankedResetDetail {
        BankedResetDetail(
            id: id,
            resetType: "codexRateLimits",
            status: "available",
            grantedAt: Date(timeIntervalSince1970: 1_900_000),
            expiresAt: expiresAt,
            title: "Full reset",
            description: "Ready"
        )
    }

    private func denseSamples(
        account: UsageSnapshot,
        firstOffset: TimeInterval,
        step: TimeInterval
    ) -> [UsageSample] {
        let window = account.mainLimit!.window
        let first = window.startsAt.addingTimeInterval(firstOffset)
        let elapsed = account.fetchedAt.timeIntervalSince(window.startsAt)
        return stride(
            from: first.timeIntervalSince1970,
            to: account.fetchedAt.timeIntervalSince1970,
            by: step
        ).map { time in
            let progress = (time - window.startsAt.timeIntervalSince1970) / elapsed
            return UsageSample(
                observedAt: Date(timeIntervalSince1970: time),
                remainingPercent: 100 - (100 - window.remainingPercent) * progress,
                resetsAt: window.resetsAt
            )
        }
    }

    private func rollingDayActivity<S: Sequence>(
        account: UsageSnapshot,
        samples: S,
        now: Date,
        accountPartitionID: String? = nil,
        accountEpochStartedAt: Date? = nil,
        timeRange: AnalyticsTimeRange = .oneDay,
        visibleRange: DateInterval? = nil
    ) -> AccountTokenActivitySnapshot where S.Element == UsageSample {
        var exploration = AnalyticsExplorationState.initial
        exploration.timeRange = timeRange
        exploration.visibleRange = visibleRange
        return UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: Array(samples),
                safetyBuffer: 3,
                sourceState: .available,
                now: now,
                previousStatus: nil,
                accountPartitionID: accountPartitionID,
                accountEpochStartedAt: accountEpochStartedAt,
                analyticsExploration: exploration
            )
        ).accountTokenActivity
    }

    private func weeklySamples(
        start: Date,
        end: Date,
        reset: Date,
        startRemaining: Double,
        endRemaining: Double,
        startTokens: Int64,
        endTokens: Int64
    ) -> [UsageSample] {
        let step: TimeInterval = 30 * 60
        let count = Int(end.timeIntervalSince(start) / step)
        return (0 ... count).map { index in
            let progress = count == 0 ? 0 : Double(index) / Double(count)
            return UsageSample(
                observedAt: start.addingTimeInterval(Double(index) * step),
                remainingPercent: startRemaining
                    + (endRemaining - startRemaining) * progress,
                resetsAt: reset,
                lifetimeTokens: startTokens
                    + Int64(
                        (
                            Double(endTokens - startTokens) * progress
                        ).rounded()
                    )
            )
        }
    }

    private func modelFacts(
        model: String,
        dates: [Date]
    ) -> [LocalActivityFact] {
        let formatter = ISO8601DateFormatter()
        return dates.enumerated().map { index, date in
            LocalActivityFact(
                key: .effectiveModel,
                availability: .available,
                value: .text(model),
                numericDelta: nil,
                tokenSegment: nil,
                reason: nil,
                eventID: "\(model)-\(index)",
                eventTimestamp: formatter.string(from: date),
                source: LocalActivitySourceMetadata(
                    source: .rolloutJSONL,
                    sourceVersion: "test",
                    schemaVersion: "1",
                    sourceGeneration: 1,
                    historyMode: nil,
                    observedAt: date
                )
            )
        }
    }

    private func tokenFact(
        tokens: Int64,
        date: Date,
        eventID: String,
        model: String = "gpt-5.6-sol"
    ) -> LocalActivityFact {
        LocalActivityFact(
            key: .token,
            availability: .available,
            value: nil,
            numericDelta: tokens,
            tokenSegment: 0,
            reason: nil,
            eventID: eventID,
            eventTimestamp: ISO8601DateFormatter().string(from: date),
            source: LocalActivitySourceMetadata(
                source: .rolloutJSONL,
                sourceVersion: "0.145.0",
                schemaVersion: "rollout-jsonl-v1",
                sourceGeneration: 0,
                historyMode: nil,
                observedAt: date
            ),
            context: LocalActivityContext(
                taskID: eventID,
                turnID: eventID,
                agent: nil,
                effectiveModel: model,
                reasoning: "high"
            ),
            tokenDelta: LocalTokenUsage(
                inputTokens: tokens,
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: tokens
            )
        )
    }
}
