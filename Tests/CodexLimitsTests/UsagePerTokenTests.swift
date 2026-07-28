import XCTest
@testable import CodexLimits

final class UsagePerTokenTests: XCTestCase {
    func testDefaultBaselineUsesExactlyFourPreviousHighComparableWeeks() throws {
        let current = week(
            index: 5,
            movement: 40,
            tokens: 10_000_000,
            modelShare: 0.80
        )
        let history = [
            week(index: 0, movement: 90, tokens: 10_000_000),
            week(index: 1, movement: 10, tokens: 10_000_000),
            week(index: 2, movement: 20, tokens: 10_000_000),
            week(index: 3, movement: 30, tokens: 10_000_000),
            week(index: 4, movement: 80, tokens: 10_000_000)
        ]

        let snapshot = UsagePerTokenEngine.evaluate(
            current: current,
            history: history,
            pinnedBaselineID: nil
        )
        let comparison = try XCTUnwrap(snapshot.comparison)

        XCTAssertEqual(
            comparison.baseline.intervalIDs,
            history.suffix(4).map(\.id)
        )
        XCTAssertEqual(
            comparison.baseline.allowancePointsPerMillionTokens,
            2.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(comparison.multiplier, 1.6, accuracy: 0.000_001)
        XCTAssertEqual(comparison.confidence, .high)
        XCTAssertEqual(comparison.baseline.policyVersion, 1)
        XCTAssertNil(comparison.caveat)
        XCTAssertEqual(comparison.equivalentCapacity.tokens, 25_000_000)
        XCTAssertEqual(
            comparison.equivalentCapacity.lowerTokens,
            12_500_000
        )
        XCTAssertEqual(
            comparison.equivalentCapacity.upperTokens,
            100_000_000
        )
    }

    func testFewerThanFourHighWeeksWithholdsTheDefaultBaseline() {
        let current = week(index: 5, movement: 40, tokens: 10_000_000)
        let history = (1 ... 3).map {
            week(index: $0, movement: Double($0 * 10), tokens: 10_000_000)
        }

        let snapshot = UsagePerTokenEngine.evaluate(
            current: current,
            history: history,
            pinnedBaselineID: nil
        )

        XCTAssertNil(snapshot.comparison)
        XCTAssertEqual(snapshot.reason, "Not enough comparable weeks")
    }

    func testCurrentComparisonNamesUnprovenTokenDefinitions() {
        let current = week(
            index: 5,
            movement: 40,
            tokens: 10_000_000,
            tokenDefinitionsAlign: false
        )

        let snapshot = UsagePerTokenEngine.evaluate(
            current: current,
            history: [],
            pinnedBaselineID: nil
        )

        XCTAssertNil(snapshot.comparison)
        XCTAssertEqual(
            snapshot.reason,
            "Token definitions have not been proven compatible"
        )
    }

    func testPinnedMediumWeekReplacesTheDefaultUntilCleared() throws {
        let current = week(index: 5, movement: 40, tokens: 10_000_000)
        let high = (0 ... 3).map {
            week(index: $0, movement: Double(($0 + 1) * 10), tokens: 10_000_000)
        }
        let pinned = week(
            index: 4,
            movement: 50,
            tokens: 10_000_000,
            localCoverage: 60,
            boundary: .loose,
            maximumGap: 60 * 60,
            modelShare: 0.65
        )

        let selected = UsagePerTokenEngine.evaluate(
            current: current,
            history: high + [pinned],
            pinnedBaselineID: pinned.id
        )
        let selectedComparison = try XCTUnwrap(selected.comparison)
        XCTAssertEqual(selectedComparison.baseline.intervalIDs, [pinned.id])
        XCTAssertTrue(selectedComparison.baseline.isPinned)
        XCTAssertEqual(selectedComparison.confidence, .medium)
        XCTAssertEqual(
            selectedComparison.caveat,
            "Local Coverage is below 80% · Weekly boundaries are loose · Account samples are more than 30 minutes apart · Model mix differs by more than 10 percentage points"
        )

        let cleared = UsagePerTokenEngine.evaluate(
            current: current,
            history: high + [pinned],
            pinnedBaselineID: nil
        )
        XCTAssertEqual(
            try XCTUnwrap(cleared.comparison).baseline.intervalIDs,
            high.map(\.id)
        )
    }

    func testComparabilityAppliesCoverageBoundaryAndWorkloadThresholds() {
        let current = week(index: 5, movement: 40, tokens: 10_000_000)
        let high = week(index: 4, movement: 40, tokens: 10_000_000)
        let medium = week(
            index: 4,
            movement: 40,
            tokens: 10_000_000,
            localCoverage: 60,
            boundary: .loose,
            maximumGap: 60 * 60,
            modelShare: 0.65
        )
        let changedMix = week(
            index: 4,
            movement: 40,
            tokens: 10_000_000,
            modelShare: 0.59
        )

        XCTAssertEqual(
            UsagePerTokenEngine.comparability(current, high),
            .high
        )
        XCTAssertEqual(
            UsagePerTokenEngine.comparability(current, medium),
            .medium
        )
        XCTAssertEqual(
            UsagePerTokenEngine.comparability(current, changedMix),
            .notComparable
        )
    }

    func testComparabilityRequiresMatchingDominantModelAndReasoning() {
        let current = week(index: 5, movement: 40, tokens: 10_000_000)
        let otherModel = week(
            index: 4,
            movement: 40,
            tokens: 10_000_000,
            modelShare: 0.40
        )
        let otherReasoning = week(
            index: 4,
            movement: 40,
            tokens: 10_000_000,
            reasoningShare: 0.40
        )

        XCTAssertEqual(
            UsagePerTokenEngine.comparability(current, otherModel),
            .notComparable
        )
        XCTAssertEqual(
            UsagePerTokenEngine.comparability(current, otherReasoning),
            .notComparable
        )
    }

    func testComparabilityRejectsMalformedWorkloadShares() {
        let current = week(index: 5, movement: 40, tokens: 10_000_000)
        let invalidModel = week(
            index: 4,
            movement: 40,
            tokens: 10_000_000,
            modelShare: .nan
        )
        let invalidCache = week(
            index: 4,
            movement: 40,
            tokens: 10_000_000,
            cachedInputShare: 1.2
        )

        XCTAssertEqual(
            UsagePerTokenEngine.comparability(current, invalidModel),
            .notComparable
        )
        XCTAssertEqual(
            UsagePerTokenEngine.comparability(current, invalidCache),
            .notComparable
        )
    }

    func testCoverageNamesCompleteHighPartialLowAndUnavailableEvidence() {
        XCTAssertEqual(
            week(index: 4, movement: 40, tokens: 10_000_000).coverage,
            .complete
        )
        XCTAssertEqual(
            week(index: 5, movement: 40, tokens: 10_000_000).coverage,
            .high
        )
        XCTAssertEqual(
            week(
                index: 5,
                movement: 40,
                tokens: 10_000_000,
                localCoverage: 70
            ).coverage,
            .partial
        )
        XCTAssertEqual(
            week(
                index: 5,
                movement: 40,
                tokens: 10_000_000,
                localCoverage: 49
            ).coverage,
            .low
        )
        XCTAssertEqual(
            week(
                index: 5,
                movement: 40,
                tokens: 10_000_000,
                tokenDefinitionsAlign: false
            ).coverage,
            .unavailable
        )
    }

    func testHardBreaksAndInvalidTokenEvidenceAreNotComparable() {
        let current = week(index: 5, movement: 40, tokens: 10_000_000)
        let invalid = [
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                unknownCorrection: true
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                accountChange: true
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                counterDecrease: true
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 0
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                tokenDefinitionsAlign: false
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                windowDurationMinutes: 300
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                accountPartitionID: "account-b"
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                limitID: "other-weekly"
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                boundary: .unbounded
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                maximumGap: 6 * 60 * 60 + 1
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                localCoverage: 49
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                reasoningShare: 0.59
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                cachedInputShare: 0.61
            ),
            week(
                index: 4,
                movement: 40,
                tokens: 10_000_000,
                modelShare: 0.5
            )
        ]

        XCTAssertTrue(invalid.allSatisfy {
            UsagePerTokenEngine.comparability(current, $0)
                == .notComparable
        })
        XCTAssertTrue(invalid.prefix(3).allSatisfy {
            $0.allowancePointsPerMillionTokens == nil
        })
    }

    func testAllowanceIntensityNamesEveryInvalidAccountBoundary() {
        let cases: [(WeeklyUsageEvidence, String)] = [
            (
                week(
                    index: 5,
                    movement: 40,
                    tokens: 10_000_000,
                    boundary: .unbounded
                ),
                "Account boundaries are unbounded"
            ),
            (
                week(
                    index: 5,
                    movement: 40,
                    tokens: 10_000_000,
                    maximumGap: 6 * 60 * 60 + 1
                ),
                "Account samples are more than 6 hours apart"
            ),
            (
                week(
                    index: 5,
                    movement: 40,
                    tokens: 10_000_000,
                    unknownCorrection: true
                ),
                "An unknown reset or correction occurred in this interval"
            ),
            (
                week(
                    index: 5,
                    movement: 40,
                    tokens: 10_000_000,
                    accountChange: true
                ),
                "The account or plan changed in this interval"
            ),
            (
                week(
                    index: 5,
                    movement: 40,
                    tokens: 10_000_000,
                    counterDecrease: true
                ),
                "The account token counter decreased in this interval"
            )
        ]

        for (evidence, reason) in cases {
            XCTAssertNil(evidence.allowancePointsPerMillionTokens)
            XCTAssertEqual(evidence.intensityUnavailableReason, reason)
            XCTAssertEqual(evidence.coverage, .unavailable)
        }
    }

    func testMissingWorkloadMetadataCannotMasqueradeAsHighComparability() {
        let current = week(index: 5, movement: 40, tokens: 10_000_000)
        let mostlyUnknown = week(
            index: 4,
            movement: 40,
            tokens: 10_000_000,
            modelAttribution: 10,
            reasoningAttribution: 10
        )
        let partlyAttributedCurrent = week(
            index: 5,
            movement: 40,
            tokens: 10_000_000,
            modelAttribution: 70,
            reasoningAttribution: 70
        )
        let medium = week(
            index: 4,
            movement: 40,
            tokens: 10_000_000,
            modelAttribution: 70,
            reasoningAttribution: 70
        )

        XCTAssertEqual(
            UsagePerTokenEngine.comparability(current, mostlyUnknown),
            .notComparable
        )
        XCTAssertEqual(
            UsagePerTokenEngine.comparability(
                partlyAttributedCurrent,
                medium
            ),
            .medium
        )
    }

    func testBuilderBoundsAccountAndLocalEvidenceToTheSameWeeklyIntervals() throws {
        let firstStart = Date(timeIntervalSince1970: 1_000_000)
        let firstReset = firstStart.addingTimeInterval(7 * 24 * 60 * 60)
        let currentReset = firstReset.addingTimeInterval(7 * 24 * 60 * 60)
        let currentEnd = firstReset.addingTimeInterval(3 * 24 * 60 * 60)
        let samples = accountSamples(
            start: firstStart,
            end: firstReset,
            reset: firstReset,
            startRemaining: 100,
            endRemaining: 60,
            startTokens: 1_000_000,
            endTokens: 11_000_000
        ) + accountSamples(
            start: firstReset,
            end: currentEnd,
            reset: currentReset,
            startRemaining: 100,
            endRemaining: 70,
            startTokens: 11_000_000,
            endTokens: 21_000_000
        )
        let facts = workloadFacts(
            start: firstStart,
            totalTokens: 9_000_000,
            prefix: "past"
        ) + workloadFacts(
            start: firstReset,
            totalTokens: 9_000_000,
            prefix: "current"
        )

        let built = WeeklyUsageEvidenceBuilder.build(
            samples: samples,
            localFacts: facts,
            localObservation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: currentEnd
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: currentReset,
            compatibleTokenSources: compatibleTokenSources
        )
        let current = try XCTUnwrap(built.current)
        let previous = try XCTUnwrap(built.history.first)

        XCTAssertFalse(current.isComplete)
        XCTAssertEqual(current.accountMovementPoints, 30, accuracy: 0.001)
        XCTAssertEqual(current.accountTokenActivity, 10_000_000)
        XCTAssertEqual(current.localTokenActivity, 9_000_000)
        XCTAssertEqual(
            try XCTUnwrap(current.localCoveragePercent),
            90,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(current.cachedInputShare),
            0.4,
            accuracy: 0.001
        )
        XCTAssertTrue(previous.isComplete)
        XCTAssertEqual(
            UsagePerTokenEngine.comparability(current, previous),
            .high
        )
    }

    func testBuilderWithholdsLocalMixWhenTheSourceHasAGap() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let end = start.addingTimeInterval(2 * 24 * 60 * 60)
        let built = WeeklyUsageEvidenceBuilder.build(
            samples: accountSamples(
                start: start,
                end: end,
                reset: reset,
                startRemaining: 100,
                endRemaining: 80,
                startTokens: 1_000_000,
                endTokens: 11_000_000
            ),
            localFacts: workloadFacts(
                start: start,
                totalTokens: 9_000_000,
                prefix: "gap"
            ),
            localObservation: .gap(
                sourceVersion: "0.145.0",
                observedAt: end,
                reason: "Local records have a gap"
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: reset,
            compatibleTokenSources: compatibleTokenSources
        )

        let current = try XCTUnwrap(built.current)
        XCTAssertEqual(current.localTokenActivity, 9_000_000)
        XCTAssertNil(current.localCoveragePercent)
        XCTAssertFalse(current.localSourceContinuous)
        XCTAssertEqual(
            current.coverageReason,
            "Local records have a gap"
        )
        XCTAssertEqual(
            UsagePerTokenEngine.comparability(
                current,
                week(index: 4, movement: 20, tokens: 10_000_000)
            ),
            .notComparable
        )
    }

    func testCurrentSourceGapDoesNotLowerAnEarlierCompleteWeek() throws {
        let firstStart = Date(timeIntervalSince1970: 1_000_000)
        let firstReset = firstStart.addingTimeInterval(7 * 24 * 60 * 60)
        let currentReset = firstReset.addingTimeInterval(7 * 24 * 60 * 60)
        let currentEnd = firstReset.addingTimeInterval(3 * 60 * 60)
        let built = WeeklyUsageEvidenceBuilder.build(
            samples: accountSamples(
                start: firstStart,
                end: firstReset,
                reset: firstReset,
                startRemaining: 100,
                endRemaining: 60,
                startTokens: 1_000_000,
                endTokens: 11_000_000
            ) + accountSamples(
                start: firstReset,
                end: currentEnd,
                reset: currentReset,
                startRemaining: 100,
                endRemaining: 90,
                startTokens: 11_000_000,
                endTokens: 12_000_000
            ),
            localFacts: workloadFacts(
                start: firstStart,
                totalTokens: 9_000_000,
                prefix: "past-gap"
            ) + workloadFacts(
                start: firstReset,
                totalTokens: 900_000,
                prefix: "current-gap"
            ),
            localObservation: .gap(
                sourceVersion: "0.145.0",
                observedAt: currentEnd,
                reason: "Local records have a gap"
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: currentReset,
            compatibleTokenSources: compatibleTokenSources
        )

        XCTAssertTrue(try XCTUnwrap(built.history.first).localSourceContinuous)
        XCTAssertFalse(try XCTUnwrap(built.current).localSourceContinuous)
    }

    func testAccountOrPlanEpochSplitsTheCurrentComparisonInterval() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let end = start.addingTimeInterval(3 * 60 * 60)
        let built = WeeklyUsageEvidenceBuilder.build(
            samples: accountSamples(
                start: start,
                end: end,
                reset: reset,
                startRemaining: 100,
                endRemaining: 90,
                startTokens: 1_000_000,
                endTokens: 2_000_000,
                comparisonBreakAtEnd: true
            ),
            localFacts: workloadFacts(
                start: start,
                totalTokens: 900_000,
                prefix: "epoch"
            ),
            localObservation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: end
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: reset,
            compatibleTokenSources: compatibleTokenSources
        )

        let current = try XCTUnwrap(built.current)
        XCTAssertTrue(current.containsAccountChange)
        XCTAssertNil(current.allowancePointsPerMillionTokens)
        XCTAssertEqual(
            current.intensityUnavailableReason,
            "The account or plan changed in this interval"
        )
    }

    func testLatestPersistedBreakExcludesTheEarlierPlanCohort() throws {
        let pastStart = Date(timeIntervalSince1970: 1_000_000)
        let pastReset = pastStart.addingTimeInterval(7 * 24 * 60 * 60)
        let currentReset = pastReset.addingTimeInterval(7 * 24 * 60 * 60)
        let currentEnd = pastReset.addingTimeInterval(3 * 60 * 60)
        let built = WeeklyUsageEvidenceBuilder.build(
            samples: accountSamples(
                start: pastStart,
                end: pastReset,
                reset: pastReset,
                startRemaining: 100,
                endRemaining: 60,
                startTokens: 1_000_000,
                endTokens: 11_000_000
            ) + accountSamples(
                start: pastReset,
                end: currentEnd,
                reset: currentReset,
                startRemaining: 100,
                endRemaining: 90,
                startTokens: 11_000_000,
                endTokens: 12_000_000,
                comparisonBreakAtEnd: true
            ),
            localFacts: workloadFacts(
                start: pastStart,
                totalTokens: 9_000_000,
                prefix: "past-plan"
            ) + workloadFacts(
                start: pastReset,
                totalTokens: 900_000,
                prefix: "current-plan"
            ),
            localObservation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: currentEnd
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: currentReset,
            compatibleTokenSources: compatibleTokenSources
        )

        XCTAssertTrue(built.history.isEmpty)
        XCTAssertTrue(try XCTUnwrap(built.current).containsAccountChange)
    }

    func testBreakAtWeeklyBoundaryStartsANewBaselineCohort() throws {
        let pastStart = Date(timeIntervalSince1970: 1_000_000)
        let boundary = pastStart.addingTimeInterval(7 * 24 * 60 * 60)
        let currentReset = boundary.addingTimeInterval(7 * 24 * 60 * 60)
        let currentEnd = boundary.addingTimeInterval(3 * 60 * 60)
        let built = WeeklyUsageEvidenceBuilder.build(
            samples: accountSamples(
                start: pastStart,
                end: boundary,
                reset: boundary,
                startRemaining: 100,
                endRemaining: 60,
                startTokens: 1_000_000,
                endTokens: 11_000_000
            ) + accountSamples(
                start: boundary,
                end: currentEnd,
                reset: currentReset,
                startRemaining: 100,
                endRemaining: 90,
                startTokens: 11_000_000,
                endTokens: 12_000_000,
                comparisonBreakAtStart: true
            ),
            localFacts: workloadFacts(
                start: pastStart,
                totalTokens: 9_000_000,
                prefix: "past-boundary"
            ) + workloadFacts(
                start: boundary,
                totalTokens: 900_000,
                prefix: "current-boundary"
            ),
            localObservation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: currentEnd
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: currentReset,
            compatibleTokenSources: compatibleTokenSources
        )

        XCTAssertTrue(built.history.isEmpty)
        XCTAssertFalse(try XCTUnwrap(built.current).containsAccountChange)
    }

    func testTokenCompatibilityIsCheckedForEachIntervalsSource() throws {
        let pastStart = Date(timeIntervalSince1970: 1_000_000)
        let pastReset = pastStart.addingTimeInterval(7 * 24 * 60 * 60)
        let currentReset = pastReset.addingTimeInterval(7 * 24 * 60 * 60)
        let currentEnd = pastReset.addingTimeInterval(3 * 60 * 60)
        let built = WeeklyUsageEvidenceBuilder.build(
            samples: accountSamples(
                start: pastStart,
                end: pastReset,
                reset: pastReset,
                startRemaining: 100,
                endRemaining: 60,
                startTokens: 1_000_000,
                endTokens: 11_000_000
            ) + accountSamples(
                start: pastReset,
                end: currentEnd,
                reset: currentReset,
                startRemaining: 100,
                endRemaining: 90,
                startTokens: 11_000_000,
                endTokens: 12_000_000
            ),
            localFacts: workloadFacts(
                start: pastStart,
                totalTokens: 9_000_000,
                prefix: "old-source",
                sourceVersion: "0.144.0"
            ) + workloadFacts(
                start: pastReset,
                totalTokens: 900_000,
                prefix: "current-source"
            ),
            localObservation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: currentEnd
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: currentReset,
            compatibleTokenSources: compatibleTokenSources
        )

        XCTAssertFalse(try XCTUnwrap(built.history.first).tokenDefinitionsAlign)
        XCTAssertTrue(try XCTUnwrap(built.current).tokenDefinitionsAlign)
    }

    func testBuilderFindsALocalSourceBreakInsideTheWeeklyInterval() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let end = start.addingTimeInterval(3 * 60 * 60)
        var facts = workloadFacts(
            start: start,
            totalTokens: 900_000,
            prefix: "source-break"
        )
        facts.append(
            LocalActivityFact(
                key: .token,
                availability: .available,
                value: nil,
                numericDelta: nil,
                tokenSegment: 1,
                reason: "source-discontinuity",
                eventID: "source-break-marker",
                eventTimestamp: ISO8601DateFormatter().string(
                    from: start.addingTimeInterval(30 * 60)
                ),
                source: LocalActivitySourceMetadata(
                    source: .rolloutJSONL,
                    sourceVersion: "0.145.0",
                    schemaVersion: "rollout-jsonl-v1",
                    sourceGeneration: 1,
                    historyMode: nil,
                    observedAt: end
                )
            )
        )

        let built = WeeklyUsageEvidenceBuilder.build(
            samples: accountSamples(
                start: start,
                end: end,
                reset: reset,
                startRemaining: 100,
                endRemaining: 90,
                startTokens: 1_000_000,
                endTokens: 2_000_000
            ),
            localFacts: facts,
            localObservation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: end
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: reset,
            compatibleTokenSources: compatibleTokenSources
        )

        let current = try XCTUnwrap(built.current)
        XCTAssertEqual(current.localTokenActivity, 900_000)
        XCTAssertNil(current.localCoveragePercent)
        XCTAssertFalse(current.localSourceContinuous)
        XCTAssertEqual(
            current.localSourceReason,
            "Local token source changed in this interval"
        )
    }

    func testBuilderIgnoresSamplesOutsideTheSelectedObservedInterval() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let end = start.addingTimeInterval(3 * 60 * 60)
        var samples = accountSamples(
            start: start,
            end: end,
            reset: reset,
            startRemaining: 100,
            endRemaining: 90,
            startTokens: 1_000_000,
            endTokens: 2_000_000
        )
        samples.append(
            UsageSample(
                observedAt: start.addingTimeInterval(-50 * 60),
                remainingPercent: 100,
                resetsAt: reset,
                lifetimeTokens: 900_000
            )
        )

        let built = WeeklyUsageEvidenceBuilder.build(
            samples: samples,
            localFacts: workloadFacts(
                start: start,
                totalTokens: 900_000,
                prefix: "bounded"
            ),
            localObservation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: end
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: reset,
            compatibleTokenSources: compatibleTokenSources
        )

        let current = try XCTUnwrap(built.current)
        XCTAssertEqual(current.maximumAccountGap, 30 * 60)
        XCTAssertEqual(current.coverage, .high)
    }

    func testBuilderWithholdsAnOverflowingLocalTokenTotal() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let end = start.addingTimeInterval(3 * 60 * 60)
        let facts = [
            workloadFact(
                date: start.addingTimeInterval(60 * 60),
                tokens: .max,
                cachedInputTokens: 0,
                model: "gpt-5.6-sol",
                reasoning: "high",
                eventID: "overflow-a"
            ),
            workloadFact(
                date: start.addingTimeInterval(2 * 60 * 60),
                tokens: 1,
                cachedInputTokens: 0,
                model: "gpt-5.6-sol",
                reasoning: "high",
                eventID: "overflow-b"
            )
        ]

        let built = WeeklyUsageEvidenceBuilder.build(
            samples: accountSamples(
                start: start,
                end: end,
                reset: reset,
                startRemaining: 100,
                endRemaining: 90,
                startTokens: 1_000_000,
                endTokens: 2_000_000
            ),
            localFacts: facts,
            localObservation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: end
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: reset,
            compatibleTokenSources: compatibleTokenSources
        )

        let current = try XCTUnwrap(built.current)
        XCTAssertNil(current.localTokenActivity)
        XCTAssertNil(current.localCoveragePercent)
        XCTAssertTrue(current.modelShares.isEmpty)
        XCTAssertEqual(
            current.coverageReason,
            "Local Coverage is unavailable"
        )
    }

    func testBuilderTracksUnattributedModelAndReasoningTokens() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let end = start.addingTimeInterval(3 * 60 * 60)
        let facts = [
            workloadFact(
                date: start.addingTimeInterval(60 * 60),
                tokens: 900_000,
                cachedInputTokens: 0,
                model: nil,
                reasoning: nil,
                eventID: "unknown-workload"
            ),
            workloadFact(
                date: start.addingTimeInterval(2 * 60 * 60),
                tokens: 100_000,
                cachedInputTokens: 0,
                model: "gpt-5.6-sol",
                reasoning: "high",
                eventID: "known-workload"
            )
        ]
        let built = WeeklyUsageEvidenceBuilder.build(
            samples: accountSamples(
                start: start,
                end: end,
                reset: reset,
                startRemaining: 100,
                endRemaining: 90,
                startTokens: 1_000_000,
                endTokens: 2_000_000
            ),
            localFacts: facts,
            localObservation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: end
            ),
            accountPartitionID: "account-a",
            limitID: "weekly",
            currentReset: reset,
            compatibleTokenSources: compatibleTokenSources
        )

        let current = try XCTUnwrap(built.current)
        XCTAssertEqual(current.modelShares["gpt-5.6-sol"], 0.1)
        XCTAssertEqual(current.reasoningShares["high"], 0.1)
        XCTAssertEqual(current.modelAttributionPercent, 10)
        XCTAssertEqual(current.reasoningAttributionPercent, 10)
        XCTAssertEqual(
            UsagePerTokenEngine.comparability(current, current),
            .notComparable
        )
    }

    func testChartPointKeepsTheRawFactsUsedByTheComparison() throws {
        let current = week(
            index: 5,
            movement: 37.5,
            tokens: 12_000_000,
            localCoverage: 90
        )
        let history = (0 ... 3).map {
            week(
                index: $0,
                movement: Double(($0 + 2) * 10),
                tokens: 10_000_000
            )
        }

        let snapshot = UsagePerTokenEngine.evaluate(
            current: current,
            history: history,
            pinnedBaselineID: nil
        )
        let point = try XCTUnwrap(
            snapshot.points.first(where: \.isCurrent)
        )

        XCTAssertEqual(point.evidence.accountMovementPoints, 37.5)
        XCTAssertEqual(point.evidence.accountTokenActivity, 12_000_000)
        XCTAssertEqual(point.evidence.localTokenActivity, 10_800_000)
        XCTAssertEqual(point.evidence.localCoveragePercent, 90)
        XCTAssertEqual(point.evidence.modelShares["gpt-5.6-sol"], 0.8)
        XCTAssertEqual(point.evidence.reasoningShares["high"], 0.8)
        XCTAssertEqual(point.evidence.cachedInputShare, 0.4)
        XCTAssertEqual(point.confidence, .high)
    }

    private func week(
        index: Int,
        movement: Double,
        tokens: Int64,
        localCoverage: Double = 90,
        boundary: UsageBoundaryQuality = .tight,
        maximumGap: TimeInterval = 15 * 60,
        modelShare: Double = 0.80,
        modelAttribution: Double = 100,
        reasoningShare: Double = 0.80,
        reasoningAttribution: Double = 100,
        cachedInputShare: Double? = 0.4,
        unknownCorrection: Bool = false,
        accountChange: Bool = false,
        counterDecrease: Bool = false,
        tokenDefinitionsAlign: Bool = true,
        windowDurationMinutes: Int = 10_080,
        accountPartitionID: String = "account-a",
        limitID: String = "weekly"
    ) -> WeeklyUsageEvidence {
        let start = Date(timeIntervalSince1970: 10_000)
            .addingTimeInterval(Double(index) * 7 * 24 * 60 * 60)
        return WeeklyUsageEvidence(
            id: "week-\(index)",
            accountPartitionID: accountPartitionID,
            limitID: limitID,
            windowDurationMinutes: windowDurationMinutes,
            allowanceResetsAt: start.addingTimeInterval(
                Double(windowDurationMinutes) * 60
            ),
            interval: DateInterval(
                start: start,
                duration: 7 * 24 * 60 * 60
            ),
            isComplete: index < 5,
            accountMovementPoints: movement,
            accountTokenActivity: tokens,
            localTokenActivity: Int64(Double(tokens) * 0.9),
            localCoveragePercent: localCoverage,
            boundaryQuality: boundary,
            maximumAccountGap: maximumGap,
            modelShares: [
                "gpt-5.6-sol": modelShare * modelAttribution / 100,
                "gpt-5.6-luna":
                    (1 - modelShare) * modelAttribution / 100
            ],
            modelAttributionPercent: modelAttribution,
            reasoningShares: [
                "high": reasoningShare * reasoningAttribution / 100,
                "medium":
                    (1 - reasoningShare) * reasoningAttribution / 100
            ],
            reasoningAttributionPercent: reasoningAttribution,
            cachedInputShare: cachedInputShare,
            containsUnknownCorrection: unknownCorrection,
            containsAccountChange: accountChange,
            containsCounterDecrease: counterDecrease,
            tokenDefinitionsAlign: tokenDefinitionsAlign,
            localSourceContinuous: true,
            localSourceReason: nil
        )
    }

    private func accountSamples(
        start: Date,
        end: Date,
        reset: Date,
        startRemaining: Double,
        endRemaining: Double,
        startTokens: Int64,
        endTokens: Int64,
        comparisonBreakAtStart: Bool = false,
        comparisonBreakAtEnd: Bool = false
    ) -> [UsageSample] {
        let step: TimeInterval = 30 * 60
        let count = Int(end.timeIntervalSince(start) / step)
        return (0 ... count).map { index in
            let fraction = count == 0
                ? 0
                : Double(index) / Double(count)
            return UsageSample(
                observedAt: start.addingTimeInterval(Double(index) * step),
                remainingPercent: startRemaining
                    + (endRemaining - startRemaining) * fraction,
                resetsAt: reset,
                lifetimeTokens: startTokens
                    + Int64(
                        (Double(endTokens - startTokens) * fraction).rounded()
                    ),
                comparisonBreak:
                    (comparisonBreakAtStart && index == 0)
                    || (comparisonBreakAtEnd && index == count)
            )
        }
    }

    private func workloadFacts(
        start: Date,
        totalTokens: Int64,
        prefix: String,
        sourceVersion: String = "0.145.0"
    ) -> [LocalActivityFact] {
        [
            workloadFact(
                date: start.addingTimeInterval(60 * 60),
                tokens: Int64(Double(totalTokens) * 0.8),
                cachedInputTokens: Int64(Double(totalTokens) * 0.32),
                model: "gpt-5.6-sol",
                reasoning: "high",
                eventID: "\(prefix)-sol",
                sourceVersion: sourceVersion
            ),
            workloadFact(
                date: start.addingTimeInterval(2 * 60 * 60),
                tokens: Int64(Double(totalTokens) * 0.2),
                cachedInputTokens: Int64(Double(totalTokens) * 0.08),
                model: "gpt-5.6-luna",
                reasoning: "medium",
                eventID: "\(prefix)-luna",
                sourceVersion: sourceVersion
            )
        ]
    }

    private func workloadFact(
        date: Date,
        tokens: Int64,
        cachedInputTokens: Int64,
        model: String?,
        reasoning: String?,
        eventID: String,
        sourceVersion: String = "0.145.0"
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
                sourceVersion: sourceVersion,
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
                reasoning: reasoning
            ),
            tokenDelta: LocalTokenUsage(
                inputTokens: tokens,
                cachedInputTokens: cachedInputTokens,
                cacheWriteInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: tokens
            )
        )
    }

    private var compatibleTokenSources: Set<LocalTokenDefinitionSource> {
        [
            LocalTokenDefinitionSource(
                sourceVersion: "0.145.0",
                schemaVersion: "rollout-jsonl-v1"
            )
        ]
    }
}
