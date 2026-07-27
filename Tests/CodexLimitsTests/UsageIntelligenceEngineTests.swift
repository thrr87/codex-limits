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
        XCTAssertEqual(reader.chart.observedSource, .account)
        XCTAssertEqual(reader.guidance, nil)
        XCTAssertEqual(reader.interval?.limitID, "codex")
        XCTAssertEqual(reader.interval?.durationMinutes, 10_080)
        XCTAssertEqual(
            reader.interval?.startsAt,
            account.mainLimit.window.startsAt
        )
        XCTAssertEqual(
            reader.interval?.resetsAt,
            account.mainLimit.window.resetsAt
        )
        XCTAssertTrue(reader.interval?.text.hasPrefix("Weekly window · ") == true)
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
                    date: account.mainLimit.window.startsAt,
                    remaining: 100
                ),
                UsageChartPoint(
                    date: account.mainLimit.window.resetsAt,
                    remaining: 3
                )
            ]
        )
        XCTAssertEqual(
            reader.chart.observed.last,
            UsageChartPoint(date: now, remaining: 20)
        )
        XCTAssertEqual(reader.chart.currentProjection.count, 2)
        XCTAssertEqual(reader.chart.historicalProjection.count, 2)
        XCTAssertEqual(
            reader.chart.accessibilityValue,
            "Now has 20 percent remaining. At reset, the current pace leaves 0 percent and the historical pace leaves 0 percent."
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
                resetsAt: account.mainLimit.window.resetsAt
            ),
            UsageSample(
                observedAt: now.addingTimeInterval(-600),
                remainingPercent: 41,
                resetsAt: account.mainLimit.window.resetsAt
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
                resetsAt: account.mainLimit.window.resetsAt
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
                resetsAt: account.mainLimit.window.resetsAt
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
        let start = account.mainLimit.window.startsAt
        let samples = stride(
            from: start.timeIntervalSince1970,
            through: now.timeIntervalSince1970,
            by: step
        ).map {
            UsageSample(
                observedAt: Date(timeIntervalSince1970: $0),
                remainingPercent: 70,
                resetsAt: account.mainLimit.window.resetsAt
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
        let historicalReset = account.mainLimit.window.startsAt
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

    private func makeSnapshot(
        remaining: Double,
        fetchedAt: Date,
        tokenHistory: [TokenDay] = []
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
            emergencyResetCount: 0,
            fetchedAt: fetchedAt
        )
    }

    private func denseSamples(
        account: UsageSnapshot,
        firstOffset: TimeInterval,
        step: TimeInterval
    ) -> [UsageSample] {
        let window = account.mainLimit.window
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
}
