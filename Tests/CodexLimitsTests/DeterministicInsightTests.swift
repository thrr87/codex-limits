import Foundation
import XCTest
@testable import CodexLimits

@MainActor
final class DeterministicInsightTests: XCTestCase {
    private let week: TimeInterval = 7 * 86_400

    func testNormalVariationDoesNotCreateUsageDeviation() {
        let snapshot = insightSnapshot(multiplier: 1.19)

        XCTAssertTrue(snapshot.insights.isEmpty)
        XCTAssertEqual(
            snapshot.checks.first(where: { $0.kind == .usageDeviation })?.reason,
            "Usage stayed within 20% of your baseline"
        )
    }

    func testIncreasedUsageCreatesMeasuredPassiveDeviation() throws {
        let snapshot = insightSnapshot(multiplier: 1.25)
        let insight = try XCTUnwrap(
            snapshot.insights.first(where: { $0.kind == .usageDeviation })
        )

        XCTAssertEqual(
            insight.title,
            "Usage increased faster than your baseline"
        )
        XCTAssertEqual(
            insight.measurement,
            "Usage per token was 1.25× your baseline"
        )
        XCTAssertEqual(insight.source, "Derived estimate")
        XCTAssertEqual(
            insight.evidenceSources,
            [
                "Account Usage remaining",
                "Account Token Activity",
                "Codex local records"
            ]
        )
        XCTAssertEqual(insight.coverage, .high)
        XCTAssertEqual(insight.confidence, .high)
        XCTAssertEqual(insight.disposition, .active)
        XCTAssertTrue(insight.freshnessText.contains("Updated"))
        XCTAssertTrue(
            insight.accessibilitySummary.contains("High confidence")
        )
    }

    func testLowerUsageCreatesStableMeasuredCopy() throws {
        let insight = try XCTUnwrap(
            insightSnapshot(multiplier: 0.79).insights.first
        )

        XCTAssertEqual(
            insight.title,
            "Usage per token was lower than your baseline"
        )
        XCTAssertEqual(
            insight.measurement,
            "Usage per token was 0.79× your baseline"
        )
    }

    func testRepeatedEvaluationKeepsOneStableDeviationID() throws {
        let first = insightSnapshot(multiplier: 1.4)
        let second = insightSnapshot(multiplier: 1.4)

        XCTAssertEqual(first.insights.count, 1)
        XCTAssertEqual(second.insights.count, 1)
        XCTAssertEqual(first.insights.first?.id, second.insights.first?.id)
    }

    func testPaceDispositionDoesNotCrossAccountPartitions() throws {
        let suite = "PaceInsightAccountTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AnalyticsWorkspaceStore(defaults: defaults)
        let accountA = try XCTUnwrap(
            DeterministicInsightEngine.evaluate(
                paceInput(accountPartitionID: "account-a"),
                dispositions: store.insightDispositions
            ).insights.first(where: { $0.kind == .pace })
        )
        store.setInsightDisposition(.dismissed, for: accountA.id)

        let accountB = try XCTUnwrap(
            DeterministicInsightEngine.evaluate(
                paceInput(accountPartitionID: "account-b"),
                dispositions: store.insightDispositions
            ).insights.first(where: { $0.kind == .pace })
        )

        XCTAssertNotEqual(accountA.id, accountB.id)
        XCTAssertEqual(accountB.disposition, .active)
    }

    func testEveryPresetResolvesToItsEffectiveGraphRange() throws {
        let source = insightInput(multiplier: 1.4).usagePerToken
        let current = try XCTUnwrap(source.current)
        let usage = UsagePerTokenSnapshot(
            current: current,
            history: (1 ... 4).map {
                evidence(index: $0, coverage: .complete)
            },
            comparison: source.comparison,
            points: [],
            eligiblePinnedBaselines: [],
            reason: nil
        )
        for (range, duration) in [
            (AnalyticsTimeRange.oneDay, 86_400.0),
            (.threeDays, 3 * 86_400.0),
            (.fourWeeks, 28 * 86_400.0),
            (.twelveWeeks, 35 * 86_400.0)
        ] {
            var exploration = AnalyticsExplorationState.initial
            exploration.timeRange = range
            let resolved = try XCTUnwrap(
                DeterministicInsightInput.effectiveRange(
                    usagePerToken: usage,
                    observedInterval: nil,
                    fetchedAt: current.interval.end,
                    exploration: exploration
                )
            )
            XCTAssertEqual(
                resolved.duration,
                min(duration, 35 * 86_400),
                accuracy: 0.1
            )
        }
    }

    func testStaleLowCoverageAndUnavailableSourceWithholdConclusion() {
        let stale = insightSnapshot(
            multiplier: 1.4,
            freshness: .stale
        )
        let low = insightSnapshot(
            multiplier: 1.4,
            coverage: .low
        )
        let unavailable = insightSnapshot(
            multiplier: 1.4,
            sourceState: .failed("HTTP 500")
        )

        XCTAssertTrue(stale.insights.isEmpty)
        XCTAssertTrue(low.insights.isEmpty)
        XCTAssertTrue(unavailable.insights.isEmpty)
        XCTAssertEqual(
            stale.checks.first(where: { $0.kind == .usageDeviation })?.reason,
            "Account data is stale"
        )
        XCTAssertEqual(
            low.checks.first(where: { $0.kind == .usageDeviation })?.reason,
            "Local Coverage is Low"
        )
        XCTAssertEqual(
            unavailable.checks.first(where: { $0.kind == .usageDeviation })?.reason,
            "Account data is unavailable"
        )
    }

    func testMediumComparableBaselineShowsCaveat() throws {
        let insight = try XCTUnwrap(
            insightSnapshot(
                multiplier: 1.3,
                confidence: .medium,
                caveat: "Model mix differs by more than 10 percentage points"
            ).insights.first
        )

        XCTAssertEqual(insight.confidence, .medium)
        XCTAssertEqual(
            insight.caveat,
            "Model mix differs by more than 10 percentage points"
        )
    }

    func testNotComparableBaselineWithholdsDeviation() {
        let snapshot = insightSnapshot(
            multiplier: 1.4,
            confidence: .low,
            comparability: .notComparable
        )

        XCTAssertTrue(snapshot.insights.isEmpty)
        XCTAssertEqual(
            snapshot.checks.first(where: {
                $0.kind == .usageDeviation
            })?.reason,
            "The reference period is not comparable"
        )
    }

    func testSparseSharedChangedMixAndUnknownCorrectionExposeNamedReasons() {
        for reason in [
            "Account samples are more than 6 hours apart",
            "Local Coverage is below 50%",
            "Pinned baseline workload mix is not comparable",
            "An unknown reset or correction occurred in this interval"
        ] {
            let snapshot = insightSnapshot(
                comparison: nil,
                comparisonReason: reason
            )

            XCTAssertTrue(snapshot.insights.isEmpty)
            XCTAssertEqual(
                snapshot.checks.first(where: {
                    $0.kind == .usageDeviation
                })?.reason,
                reason
            )
        }
    }

    func testReaderEvidenceGatesProduceTheWithholdingReasons() {
        let history = (1 ... 4).map {
            evidence(index: $0, coverage: .complete)
        }
        let sparse = UsagePerTokenEngine.evaluate(
            current: evidence(
                index: 5,
                coverage: .high,
                maximumAccountGap: 7 * 3_600
            ),
            history: history,
            pinnedBaselineID: nil
        )
        let shared = UsagePerTokenEngine.evaluate(
            current: evidence(
                index: 5,
                coverage: .low,
                localCoveragePercent: 40
            ),
            history: history,
            pinnedBaselineID: nil
        )
        let changedMix = UsagePerTokenEngine.evaluate(
            current: evidence(
                index: 5,
                coverage: .high,
                modelShares: ["gpt-5.6-luna": 1]
            ),
            history: history,
            pinnedBaselineID: history.last?.id
        )
        let corrected = UsagePerTokenEngine.evaluate(
            current: evidence(
                index: 5,
                coverage: .high,
                containsUnknownCorrection: true
            ),
            history: history,
            pinnedBaselineID: nil
        )

        for (usage, reason) in [
            (sparse, "Account samples are more than 6 hours apart"),
            (shared, "Local Coverage is below 50%"),
            (
                changedMix,
                "Pinned baseline workload mix is not comparable"
            ),
            (
                corrected,
                "An unknown reset or correction occurred in this interval"
            )
        ] {
            let snapshot = DeterministicInsightEngine.evaluate(
                insightInput(usagePerToken: usage),
                dispositions: [:]
            )
            XCTAssertTrue(snapshot.insights.isEmpty)
            XCTAssertEqual(
                snapshot.checks.first(where: {
                    $0.kind == .usageDeviation
                })?.reason,
                reason
            )
        }
    }

    func testSelectedPastRangeWithholdsCurrentObservation() {
        let snapshot = insightSnapshot(
            multiplier: 1.4,
            selectedRange: DateInterval(
                start: Date(timeIntervalSince1970: 100),
                end: Date(timeIntervalSince1970: 200)
            )
        )

        XCTAssertTrue(snapshot.insights.isEmpty)
        XCTAssertEqual(
            snapshot.checks.first(where: { $0.kind == .usageDeviation })?.reason,
            "Usage Deviation needs the full observed weekly window"
        )
    }

    func testAccountInsightNamesUnsupportedLocalFilters() throws {
        let insight = try XCTUnwrap(
            insightSnapshot(
                multiplier: 1.4,
                filters: WorkspaceFilters(
                    projectID: "codex-limits",
                    taskTreeID: "task-22",
                    model: "gpt-5.6-sol",
                    reasoning: "high"
                )
            ).insights.first
        )

        XCTAssertEqual(
            insight.scopeNote,
            "Account data does not support Project, Task, Model, or Reasoning filters"
        )
    }

    func testExpectedAndDismissedDecisionsPersistWithoutChangingEvidence() throws {
        let suite = "DeterministicInsightTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AnalyticsWorkspaceStore(defaults: defaults)
        let source = insightInput(multiplier: 1.4)
        let original = try XCTUnwrap(
            DeterministicInsightEngine.evaluate(
                source,
                dispositions: first.insightDispositions
            ).insights.first
        )

        first.setInsightDisposition(.expected, for: original.id)
        let restored = AnalyticsWorkspaceStore(defaults: defaults)
        let expected = try XCTUnwrap(
            DeterministicInsightEngine.evaluate(
                source,
                dispositions: restored.insightDispositions
            ).insights.first
        )
        XCTAssertEqual(expected.disposition, .expected)
        XCTAssertEqual(expected.measurement, original.measurement)

        restored.setInsightDisposition(.dismissed, for: original.id)
        let dismissed = DeterministicInsightEngine.evaluate(
            source,
            dispositions: AnalyticsWorkspaceStore(defaults: defaults)
                .insightDispositions
        )
        XCTAssertTrue(dismissed.insights.isEmpty)
    }

    func testStableDeviationCopyNeverClaimsCauseOrLimitChange() {
        let copy = [
            insightSnapshot(multiplier: 1.25),
            insightSnapshot(multiplier: 0.79)
        ].flatMap(\.insights).map {
            [$0.title, $0.message, $0.measurement].joined(separator: " ")
        }.joined(separator: " ").lowercased()

        for prohibited in [
            "billing error",
            "limit reduction",
            "limits got worse",
            "because"
        ] {
            XCTAssertFalse(copy.contains(prohibited))
        }
    }

    private func insightSnapshot(
        multiplier: Double? = nil,
        comparison: UsagePerTokenComparison? = nil,
        comparisonReason: String? = nil,
        freshness: UsageFreshness = .fresh,
        sourceState: UsageSourceState = .available,
        coverage: CoverageLevel = .high,
        confidence: ConfidenceLevel = .high,
        comparability: WorkloadComparability? = nil,
        caveat: String? = nil,
        selectedRange: DateInterval? = nil,
        filters: WorkspaceFilters = .all
    ) -> DeterministicInsightsSnapshot {
        DeterministicInsightEngine.evaluate(
            insightInput(
                multiplier: multiplier,
                comparison: comparison,
                comparisonReason: comparisonReason,
                freshness: freshness,
                sourceState: sourceState,
                coverage: coverage,
                confidence: confidence,
                comparability: comparability,
                caveat: caveat,
                selectedRange: selectedRange,
                filters: filters
            ),
            dispositions: [:]
        )
    }

    private func insightInput(
        multiplier: Double? = nil,
        comparison: UsagePerTokenComparison? = nil,
        comparisonReason: String? = nil,
        freshness: UsageFreshness = .fresh,
        sourceState: UsageSourceState = .available,
        coverage: CoverageLevel = .high,
        confidence: ConfidenceLevel = .high,
        comparability: WorkloadComparability? = nil,
        caveat: String? = nil,
        selectedRange: DateInterval? = nil,
        filters: WorkspaceFilters = .all
    ) -> DeterministicInsightInput {
        let current = evidence(index: 5, coverage: coverage)
        let resolvedComparison = comparison ?? multiplier.map {
            UsagePerTokenComparison(
                baseline: ReferenceBaseline(
                    id: "weeks-1-4",
                    intervalIDs: (1 ... 4).map { "week-\($0)" },
                    policyVersion: ReferenceBaseline.currentPolicyVersion,
                    interval: DateInterval(
                        start: Date(timeIntervalSince1970: 10_000)
                            .addingTimeInterval(week),
                        duration: 4 * week
                    ),
                    allowancePointsPerMillionTokens: 2,
                    isPinned: confidence == .medium,
                    comparability: comparability
                        ?? (confidence == .high ? .high : .medium)
                ),
                multiplier: $0,
                confidence: confidence,
                caveat: caveat,
                equivalentCapacity: EquivalentCapacityEstimate(
                    tokens: 50_000_000,
                    lowerTokens: 45_000_000,
                    upperTokens: 55_000_000,
                    confidence: confidence
                )
            )
        }
        let usage = UsagePerTokenSnapshot(
            current: current,
            history: [],
            comparison: resolvedComparison,
            points: [],
            eligiblePinnedBaselines: [],
            reason: comparisonReason
        )
        return DeterministicInsightInput(
            sourceState: sourceState,
            freshness: freshness,
            fetchedAt: current.interval.end,
            accountPartitionID: "account-a",
            guidance: nil,
            guidanceEvidence: UsageEvidence(
                coverage: .high,
                confidence: .high,
                reason: nil,
                policyVersion: 1
            ),
            observedInterval: nil,
            usagePerToken: usage,
            selectedRange: selectedRange,
            filters: filters
        )
    }

    private func insightInput(
        usagePerToken: UsagePerTokenSnapshot
    ) -> DeterministicInsightInput {
        DeterministicInsightInput(
            sourceState: .available,
            freshness: .fresh,
            fetchedAt: usagePerToken.current?.interval.end,
            accountPartitionID: "account-a",
            guidance: nil,
            guidanceEvidence: UsageEvidence(
                coverage: .high,
                confidence: .high,
                reason: nil,
                policyVersion: 1
            ),
            observedInterval: nil,
            usagePerToken: usagePerToken,
            selectedRange: usagePerToken.current?.interval,
            filters: .all
        )
    }

    private func paceInput(
        accountPartitionID: String
    ) -> DeterministicInsightInput {
        let fetchedAt = Date(timeIntervalSince1970: 50_000)
        let reset = fetchedAt.addingTimeInterval(week)
        let forecast = Forecast(
            status: .slowDown,
            expectedRemainingAtReset: 0,
            safetyRemainingAtReset: 3,
            recommendedPercentPerDay: 8,
            currentPercentPerDay: 12,
            safetyPercentPerDay: 8,
            historicalReference: nil
        )
        return DeterministicInsightInput(
            sourceState: .available,
            freshness: .fresh,
            fetchedAt: fetchedAt,
            accountPartitionID: accountPartitionID,
            guidance: UsageGuidance(
                source: .derivedEstimate,
                status: .slowDown,
                title: "Slow down",
                message: "At this pace, your limit may run out early.",
                suggestedPace: "Up to 8% a day",
                runway: .exhausts(
                    fetchedAt.addingTimeInterval(2 * 86_400),
                    beforeReset: 5 * 86_400
                ),
                remainingAtResetRange: nil,
                caveat: nil,
                forecast: forecast
            ),
            guidanceEvidence: UsageEvidence(
                coverage: .high,
                confidence: .high,
                reason: nil,
                policyVersion: 1
            ),
            observedInterval: UsageObservedInterval(
                limitID: "weekly",
                durationMinutes: UsageHistoryPolicy.weeklyDurationMinutes,
                startsAt: reset.addingTimeInterval(-week),
                resetsAt: reset
            ),
            usagePerToken: UsagePerTokenEngine.evaluate(
                current: nil,
                history: [],
                pinnedBaselineID: nil
            ),
            selectedRange: DateInterval(
                start: fetchedAt.addingTimeInterval(-86_400),
                end: fetchedAt
            ),
            filters: .all
        )
    }

    private func evidence(
        index: Int,
        coverage: CoverageLevel,
        maximumAccountGap: TimeInterval = 15 * 60,
        localCoveragePercent: Double? = nil,
        modelShares: [String: Double] = ["gpt-5.6-sol": 1],
        containsUnknownCorrection: Bool = false
    ) -> WeeklyUsageEvidence {
        let start = Date(timeIntervalSince1970: 10_000)
            .addingTimeInterval(Double(index) * week)
        let derivedLocalCoverage: Double?
        let boundary: UsageBoundaryQuality
        switch coverage {
        case .complete, .high:
            derivedLocalCoverage = 90
            boundary = .tight
        case .partial:
            derivedLocalCoverage = 60
            boundary = .loose
        case .low:
            derivedLocalCoverage = 40
            boundary = .tight
        case .unavailable, .notApplicable:
            derivedLocalCoverage = nil
            boundary = .unbounded
        }
        let localCoverage = localCoveragePercent
            ?? derivedLocalCoverage
        return WeeklyUsageEvidence(
            id: "week-\(index)",
            accountPartitionID: "account-a",
            limitID: "weekly",
            windowDurationMinutes: UsageHistoryPolicy.weeklyDurationMinutes,
            allowanceResetsAt: start.addingTimeInterval(week),
            interval: DateInterval(start: start, duration: week),
            isComplete: coverage == .complete,
            accountMovementPoints: 25,
            accountTokenActivity: 10_000_000,
            localTokenActivity: localCoverage.map {
                Int64(Double(10_000_000) * $0 / 100)
            },
            localCoveragePercent: localCoverage,
            boundaryQuality: boundary,
            maximumAccountGap: maximumAccountGap,
            modelShares: modelShares,
            modelAttributionPercent: 100,
            reasoningShares: ["high": 1],
            reasoningAttributionPercent: 100,
            cachedInputShare: 0.4,
            containsUnknownCorrection: containsUnknownCorrection,
            containsAccountChange: false,
            containsCounterDecrease: false,
            tokenDefinitionsAlign: true,
            localSourceContinuous: true,
            localSourceReason: nil
        )
    }
}
