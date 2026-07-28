import Foundation
import XCTest
@testable import CodexLimits

final class ActiveTimeAvailabilityTests: XCTestCase {
    func testEstimatesAHighConfidenceRangeFromFourComparableWeeks() throws {
        let current = week(index: 4, movement: 40, isComplete: false)
        let history = [
            activity(week(index: 0, movement: 80), hours: 8),
            activity(week(index: 1, movement: 80), hours: 10),
            activity(week(index: 2, movement: 80), hours: 12),
            activity(week(index: 3, movement: 80), hours: 14)
        ]

        let snapshot = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: current,
            activeTimeThisWeek: 6 * 60 * 60,
            activeTimeCoverage: .high,
            activeTimeReason: nil,
            history: history,
            usageRemainingPercent: 60
        )
        let estimate = try XCTUnwrap(snapshot.estimate)

        XCTAssertEqual(estimate.lowerSeconds, 6 * 60 * 60)
        XCTAssertEqual(estimate.upperSeconds, 10.5 * 60 * 60)
        XCTAssertEqual(estimate.confidence, .high)
        XCTAssertEqual(estimate.coverage, .high)
        XCTAssertEqual(estimate.referenceIntervalIDs.count, 4)
        XCTAssertNil(snapshot.reason)
    }

    func testShowsPartialCurrentActiveTimeAsMediumWithNamedCaveat() throws {
        let current = week(index: 4, movement: 40, isComplete: false)
        let history = (0 ..< 4).map {
            activity(week(index: $0, movement: 80), hours: 10)
        }

        let snapshot = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: current,
            activeTimeThisWeek: 5 * 60 * 60,
            activeTimeCoverage: .partial,
            activeTimeReason: "Task Tree may omit Review and Guardian Tasks",
            history: history,
            usageRemainingPercent: 60
        )
        let estimate = try XCTUnwrap(snapshot.estimate)

        XCTAssertEqual(estimate.confidence, .medium)
        XCTAssertEqual(estimate.coverage, .partial)
        XCTAssertEqual(
            estimate.caveat,
            "Task Tree may omit Review and Guardian Tasks"
        )
    }

    func testShowsPartialReferenceActiveTimeAsMediumWithNamedCaveat() throws {
        let current = week(index: 4, movement: 40, isComplete: false)
        let history = (0 ..< 4).map {
            activity(
                week(index: $0, movement: 80),
                hours: 10,
                coverage: .partial,
                reason: "Task Tree may omit Review and Guardian Tasks"
            )
        }

        let snapshot = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: current,
            activeTimeThisWeek: 5 * 60 * 60,
            activeTimeCoverage: .high,
            activeTimeReason: nil,
            history: history,
            usageRemainingPercent: 60
        )
        let estimate = try XCTUnwrap(snapshot.estimate)

        XCTAssertEqual(estimate.confidence, .medium)
        XCTAssertEqual(estimate.coverage, .partial)
        XCTAssertEqual(
            estimate.caveat,
            "Task Tree may omit Review and Guardian Tasks"
        )
    }

    func testAccessibilityValueNamesRangeBasisAndConfidence() throws {
        let snapshot = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: week(index: 4, movement: 40, isComplete: false),
            activeTimeThisWeek: 6 * 60 * 60,
            activeTimeCoverage: .high,
            activeTimeReason: nil,
            history: [
                activity(week(index: 0, movement: 80), hours: 8),
                activity(week(index: 1, movement: 80), hours: 10),
                activity(week(index: 2, movement: 80), hours: 12),
                activity(week(index: 3, movement: 80), hours: 14)
            ],
            usageRemainingPercent: 60
        )
        let estimate = try XCTUnwrap(snapshot.estimate)

        XCTAssertEqual(
            estimate.accessibilityValue {
                "\(Int(($0 / 3_600).rounded(.down))) hours"
            },
            "Estimated active time available 6 hours to 10 hours. "
                + "Basis current week plus 4 comparable weeks. "
                + "Confidence High"
        )
    }

    func testWithholdsChangedWorkloadMixWithNamedReason() {
        let current = week(index: 4, movement: 40, isComplete: false)
        let history = (0 ..< 4).map {
            activity(
                week(
                    index: $0,
                    movement: 80,
                    modelShare: 0.2
                ),
                hours: 10
            )
        }

        let snapshot = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: current,
            activeTimeThisWeek: 5 * 60 * 60,
            activeTimeCoverage: .high,
            activeTimeReason: nil,
            history: history,
            usageRemainingPercent: 60
        )

        XCTAssertNil(snapshot.estimate)
        XCTAssertEqual(
            snapshot.reason,
            "Recent workload mix is not comparable"
        )
    }

    func testWithholdsLowActiveTimeCoverageButKeepsMeasuredFact() {
        let current = week(index: 4, movement: 40, isComplete: false)

        let snapshot = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: current,
            activeTimeThisWeek: 2 * 60 * 60,
            activeTimeCoverage: .low,
            activeTimeReason: "Long local source gap",
            history: comparableHistory(),
            usageRemainingPercent: 60
        )

        XCTAssertNil(snapshot.estimate)
        XCTAssertEqual(snapshot.activeTimeThisWeek, 2 * 60 * 60)
        XCTAssertEqual(snapshot.activeTimeCoverage, .low)
        XCTAssertEqual(snapshot.reason, "Long local source gap")
    }

    func testWithholdsCurrentIntervalBreaksAndLongAccountGaps() {
        let cases: [(WeeklyUsageEvidence, String)] = [
            (
                week(
                    index: 4,
                    movement: 40,
                    isComplete: false,
                    unknownCorrection: true
                ),
                "An unknown reset or correction occurred in this interval"
            ),
            (
                week(
                    index: 4,
                    movement: 40,
                    isComplete: false,
                    accountChange: true
                ),
                "The account or plan changed in this interval"
            ),
            (
                week(
                    index: 4,
                    movement: 40,
                    isComplete: false,
                    counterDecrease: true
                ),
                "The account token counter decreased in this interval"
            ),
            (
                week(
                    index: 4,
                    movement: 40,
                    isComplete: false,
                    maximumGap: 7 * 60 * 60
                ),
                "Account samples are more than 6 hours apart"
            )
        ]

        for (current, expectedReason) in cases {
            let snapshot = ActiveTimeAvailabilityEngine.evaluate(
                currentUsage: current,
                activeTimeThisWeek: 5 * 60 * 60,
                activeTimeCoverage: .high,
                activeTimeReason: nil,
                history: comparableHistory(),
                usageRemainingPercent: 60
            )

            XCTAssertNil(snapshot.estimate)
            XCTAssertEqual(snapshot.reason, expectedReason)
        }
    }

    func testWithholdsZeroAccountMovement() {
        let snapshot = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: week(
                index: 4,
                movement: 0,
                isComplete: false
            ),
            activeTimeThisWeek: 5 * 60 * 60,
            activeTimeCoverage: .high,
            activeTimeReason: nil,
            history: comparableHistory(),
            usageRemainingPercent: 100
        )

        XCTAssertNil(snapshot.estimate)
        XCTAssertEqual(snapshot.reason, "Account Movement is zero")
    }

    func testWithholdsWhenTheEstimatedRangeWouldOverflow() {
        let snapshot = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: week(
                index: 4,
                movement: .leastNonzeroMagnitude,
                isComplete: false
            ),
            activeTimeThisWeek: 5 * 60 * 60,
            activeTimeCoverage: .high,
            activeTimeReason: nil,
            history: comparableHistory(),
            usageRemainingPercent: 60
        )

        XCTAssertNil(snapshot.estimate)
        XCTAssertEqual(
            snapshot.reason,
            "Estimated active time is unavailable"
        )
    }

    func testRequiresFourCompleteComparableWeeks() {
        let snapshot = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: week(
                index: 4,
                movement: 40,
                isComplete: false
            ),
            activeTimeThisWeek: 5 * 60 * 60,
            activeTimeCoverage: .high,
            activeTimeReason: nil,
            history: Array(comparableHistory().prefix(3)),
            usageRemainingPercent: 60
        )

        XCTAssertNil(snapshot.estimate)
        XCTAssertEqual(snapshot.reason, "Not enough comparable weeks")
    }

    func testCurrentObservedRateCoversQuietAndFastUse() throws {
        let cases: [
            (
                activeHours: Double,
                expectedLowerHours: Double,
                expectedUpperHours: Double
            )
        ] = [
            (1, 1.5, 7.5),
            (20, 7.5, 30)
        ]

        for value in cases {
            let snapshot = ActiveTimeAvailabilityEngine.evaluate(
                currentUsage: week(
                    index: 4,
                    movement: 40,
                    isComplete: false
                ),
                activeTimeThisWeek: value.activeHours * 60 * 60,
                activeTimeCoverage: .high,
                activeTimeReason: nil,
                history: comparableHistory(),
                usageRemainingPercent: 60
            )
            let estimate = try XCTUnwrap(snapshot.estimate)

            XCTAssertEqual(
                estimate.lowerSeconds,
                value.expectedLowerHours * 60 * 60
            )
            XCTAssertEqual(
                estimate.upperSeconds,
                value.expectedUpperHours * 60 * 60
            )
        }
    }

    func testWithholdsWhenAccountAndLocalTokenDefinitionsDoNotAlign() {
        let snapshot = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: week(
                index: 4,
                movement: 40,
                isComplete: false,
                tokenDefinitionsAlign: false
            ),
            activeTimeThisWeek: 5 * 60 * 60,
            activeTimeCoverage: .high,
            activeTimeReason: nil,
            history: comparableHistory(),
            usageRemainingPercent: 60
        )

        XCTAssertNil(snapshot.estimate)
        XCTAssertEqual(
            snapshot.reason,
            "Token definitions have not been proven compatible"
        )
    }

    func testBuildsBoundedHistoricalActiveTimeEvidence() {
        let first = week(index: 0, movement: 80)
        let second = week(index: 1, movement: 80)
        let facts = [
            timingFact(
                id: "turn-1",
                taskID: "task-1",
                start: first.interval.start.addingTimeInterval(60),
                end: first.interval.start.addingTimeInterval(3_660)
            ),
            timingFact(
                id: "turn-2",
                taskID: "task-2",
                start: second.interval.start.addingTimeInterval(60),
                end: second.interval.start.addingTimeInterval(7_260)
            )
        ]

        let selection = ActiveTimeWeekEvidenceBuilder.build(
            currentUsage: week(index: 2, movement: 40, isComplete: false),
            usage: [first, second],
            facts: facts,
            projections: [
                projection(taskID: "task-1"),
                projection(taskID: "task-2")
            ],
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: second.interval.end
            )
        )

        XCTAssertEqual(selection.evidence.map(\.usage.id), ["week-0", "week-1"])
        XCTAssertEqual(selection.evidence.map(\.activeTimeSeconds), [3_600, 7_200])
        XCTAssertEqual(selection.evidence.map(\.coverage), [.partial, .partial])
        XCTAssertEqual(
            Set(selection.evidence.compactMap(\.reason)),
            ["Task Tree may omit Review and Guardian Tasks"]
        )
    }

    func testHistoricalActiveTimeClipsATurnAcrossTheWeeklyBoundary() {
        let first = week(index: 0, movement: 80)
        let second = week(index: 1, movement: 80)
        let boundary = first.interval.end
        let fact = timingFact(
            id: "turn-across-reset",
            taskID: "task-1",
            start: boundary.addingTimeInterval(-1_800),
            end: boundary.addingTimeInterval(1_800)
        )

        let selection = ActiveTimeWeekEvidenceBuilder.build(
            currentUsage: week(index: 2, movement: 40, isComplete: false),
            usage: [first, second],
            facts: [fact],
            projections: [projection(taskID: "task-1")],
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: second.interval.end
            )
        )

        XCTAssertEqual(
            selection.evidence.map(\.activeTimeSeconds),
            [1_800, 1_800]
        )
    }

    func testActivityIndexCarriesMissingTurnBoundsAcrossWeeks() {
        let first = week(index: 0, movement: 80)
        let second = week(index: 1, movement: 80)
        let boundary = first.interval.end
        let missingEnd = boundaryFact(
            id: "missing-end",
            start: boundary.addingTimeInterval(-1_800),
            end: nil,
            eventDate: boundary.addingTimeInterval(-1_800)
        )
        let missingStart = boundaryFact(
            id: "missing-start",
            start: nil,
            end: boundary.addingTimeInterval(1_800),
            eventDate: boundary.addingTimeInterval(1_800)
        )
        let index = LocalActivityFactIndex([missingEnd, missingStart])

        XCTAssertEqual(
            Set(index.activityFacts(in: first.interval).compactMap(\.eventID)),
            ["missing-end", "missing-start"]
        )
        XCTAssertEqual(
            Set(index.activityFacts(in: second.interval).compactMap(\.eventID)),
            ["missing-end", "missing-start"]
        )
    }

    func testHistoricalSourceGapStaysLowOutsideItsObservationTime() {
        let affected = week(
            index: 0,
            movement: 80,
            localSourceContinuous: false,
            localSourceReason: "Local records have a gap"
        )
        let fact = timingFact(
            id: "turn-1",
            taskID: "task-1",
            start: affected.interval.start.addingTimeInterval(60),
            end: affected.interval.start.addingTimeInterval(3_660)
        )

        let selection = ActiveTimeWeekEvidenceBuilder.build(
            currentUsage: week(index: 1, movement: 40, isComplete: false),
            usage: [affected],
            facts: [fact],
            projections: [projection(taskID: "task-1")],
            observation: .gap(
                sourceVersion: "0.145.0",
                observedAt: affected.interval.end.addingTimeInterval(86_400),
                reason: "A newer interval has a gap"
            )
        )

        XCTAssertTrue(selection.evidence.isEmpty)
    }

    func testFindsFourOlderEligibleWeeksPastRecentInvalidWeeks() {
        let weeks = (0 ..< 17).map { index in
            week(
                index: index,
                movement: index == 16 ? 0 : 80,
                modelShare: index < 4 || index == 16 ? 0.8 : 0.2
            )
        }
        let facts = weeks.enumerated().map { index, usage in
            timingFact(
                id: "turn-\(index)",
                taskID: "task-\(index)",
                start: usage.interval.start.addingTimeInterval(60),
                end: usage.interval.start.addingTimeInterval(3_660)
            )
        }

        let selection = ActiveTimeWeekEvidenceBuilder.build(
            currentUsage: week(
                index: 17,
                movement: 40,
                isComplete: false
            ),
            usage: weeks,
            facts: facts,
            projections: (0 ..< 17).map {
                projection(taskID: "task-\($0)")
            },
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: weeks.last!.interval.end
            )
        )

        XCTAssertEqual(
            selection.evidence.map(\.usage.id),
            ["week-0", "week-1", "week-2", "week-3"]
        )
    }

    private func activity(
        _ usage: WeeklyUsageEvidence,
        hours: Double,
        coverage: CoverageLevel = .high,
        reason: String? = nil
    ) -> ActiveTimeWeekEvidence {
        ActiveTimeWeekEvidence(
            usage: usage,
            activeTimeSeconds: hours * 60 * 60,
            coverage: coverage,
            reason: reason
        )
    }

    private func comparableHistory() -> [ActiveTimeWeekEvidence] {
        (0 ..< 4).map {
            activity(week(index: $0, movement: 80), hours: 10)
        }
    }

    private func timingFact(
        id: String,
        taskID: String,
        start: Date,
        end: Date
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
            source: source(observedAt: end),
            context: LocalActivityContext(
                taskID: taskID,
                turnID: id,
                agent: nil,
                effectiveModel: "gpt-5.6-sol",
                reasoning: "high"
            )
        )
    }

    private func boundaryFact(
        id: String,
        start: Date?,
        end: Date?,
        eventDate: Date
    ) -> LocalActivityFact {
        LocalActivityFact(
            key: .time,
            availability: .partial,
            value: .turnTiming(
                LocalTurnTiming(
                    startedAt: start,
                    completedAt: end,
                    durationMilliseconds: nil,
                    timeToFirstTokenMilliseconds: nil
                )
            ),
            numericDelta: nil,
            tokenSegment: nil,
            reason: "Turn boundary is unavailable",
            eventID: id,
            eventTimestamp: ISO8601DateFormatter().string(from: eventDate),
            source: source(observedAt: eventDate),
            context: LocalActivityContext(
                taskID: "task-1",
                turnID: id,
                agent: nil,
                effectiveModel: "gpt-5.6-sol",
                reasoning: "high"
            )
        )
    }

    private func projection(taskID: String) -> ThreadProjection {
        ThreadProjection(
            taskID: taskID,
            parentTaskID: nil,
            projectLabel: "atlas",
            rolloutFileURL: nil,
            createdAt: nil,
            updatedAt: nil,
            source: source(observedAt: .distantPast)
        )
    }

    private func source(
        observedAt: Date
    ) -> LocalActivitySourceMetadata {
        LocalActivitySourceMetadata(
            source: .rolloutJSONL,
            sourceVersion: "0.145.0",
            schemaVersion: "rollout-v1",
            sourceGeneration: 0,
            historyMode: "paginated",
            observedAt: observedAt
        )
    }

    private func week(
        index: Int,
        movement: Double,
        isComplete: Bool = true,
        modelShare: Double = 0.8,
        maximumGap: TimeInterval = 15 * 60,
        unknownCorrection: Bool = false,
        accountChange: Bool = false,
        counterDecrease: Bool = false,
        tokenDefinitionsAlign: Bool = true,
        localSourceContinuous: Bool = true,
        localSourceReason: String? = nil
    ) -> WeeklyUsageEvidence {
        let start = Date(timeIntervalSince1970: 10_000)
            .addingTimeInterval(Double(index) * 7 * 24 * 60 * 60)
        return WeeklyUsageEvidence(
            id: "week-\(index)",
            accountPartitionID: "account-a",
            limitID: "weekly",
            windowDurationMinutes: 10_080,
            allowanceResetsAt: start.addingTimeInterval(7 * 24 * 60 * 60),
            interval: DateInterval(
                start: start,
                duration: 7 * 24 * 60 * 60
            ),
            isComplete: isComplete,
            accountMovementPoints: movement,
            accountTokenActivity: 10_000_000,
            localTokenActivity: 9_000_000,
            localCoveragePercent: 90,
            boundaryQuality: .tight,
            maximumAccountGap: maximumGap,
            modelShares: [
                "gpt-5.6-sol": modelShare,
                "gpt-5.6-luna": 1 - modelShare
            ],
            modelAttributionPercent: 100,
            reasoningShares: [
                "high": 0.8,
                "medium": 0.2
            ],
            reasoningAttributionPercent: 100,
            cachedInputShare: 0.4,
            containsUnknownCorrection: unknownCorrection,
            containsAccountChange: accountChange,
            containsCounterDecrease: counterDecrease,
            tokenDefinitionsAlign: tokenDefinitionsAlign,
            localSourceContinuous: localSourceContinuous,
            localSourceReason: localSourceReason
        )
    }
}
