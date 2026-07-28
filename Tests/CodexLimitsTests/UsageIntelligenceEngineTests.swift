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

        XCTAssertEqual(reader.accountTokenActivity.state, .exact)
        XCTAssertEqual(reader.accountTokenActivity.tokens, 600)
        XCTAssertEqual(reader.accountTokenActivity.method, .lifetimeDelta)
        XCTAssertEqual(
            reader.accountTokenActivity.interval,
            DateInterval(start: boundary.observedAt, end: now)
        )
        XCTAssertNil(reader.accountTokenActivity.reason)
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

        XCTAssertEqual(reader.accountTokenActivity.state, .exact)
        XCTAssertEqual(
            reader.accountTokenActivity.interval,
            DateInterval(start: boundary.observedAt, end: observedAt)
        )
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
        XCTAssertEqual(
            reader.accountTokenActivity.reason,
            "Only complete daily token totals are available"
        )
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

        XCTAssertEqual(reader.accountTokenActivity.state, .exact)
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
            reader.accountTokenActivity.reason,
            "Lifetime token counter decreased"
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
            reader.accountTokenActivity.reason,
            "Lifetime token reading is invalid"
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
        XCTAssertEqual(reader.guidance?.suggestedPace, "Up to 8.5% a day")
        XCTAssertNotNil(reader.guidance?.runway)
        XCTAssertNil(reader.guidance?.remainingAtResetRange)
        XCTAssertNil(reader.guidance?.caveat)
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
        XCTAssertEqual(reader.guidanceTitle, "Not enough data")
        XCTAssertEqual(
            reader.guidanceMessage,
            "Couldn’t read Codex usage. Try refreshing again."
        )
        XCTAssertEqual(reader.suggestedPaceText, "Not enough data")
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
        XCTAssertEqual(
            reader.updateStatusText(at: fetchedAt.addingTimeInterval(3_600)),
            "Stale · Updated 1 hr ago"
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
        XCTAssertNil(reader.guidance)
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

    func testUnknownCorrectionWithholdsGuidance() {
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
        XCTAssertNil(reader.guidance)
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
        XCTAssertEqual(reader.evidence.reason, "Weekly usage unavailable")
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
                )
            )
        )

        XCTAssertEqual(reader.evidence.coverage, .partial)
        XCTAssertEqual(reader.evidence.confidence, .medium)
        XCTAssertEqual(reader.evidence.reason, "Workload mix changed")
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

    private func makeSnapshot(
        remaining: Double,
        fetchedAt: Date,
        tokenHistory: [TokenDay] = [],
        accountFacts: AccountFacts? = nil,
        emergencyResetCount: Int = 0,
        bankedResetCountAvailable: Bool? = true,
        bankedResetDetails: [BankedResetDetail]? = nil
    ) -> UsageSnapshot {
        let window = UsageWindow(
            remainingPercent: remaining,
            resetsAt: fetchedAt.addingTimeInterval(2 * 86_400),
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
}
