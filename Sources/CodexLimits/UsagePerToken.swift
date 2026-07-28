import Foundation

enum UsageBoundaryQuality: String, Codable, Equatable, Sendable {
    case tight
    case loose
    case unbounded
}

enum WorkloadComparability: String, Codable, Equatable, Sendable {
    case high
    case medium
    case notComparable
}

struct LocalTokenDefinitionSource: Hashable, Sendable {
    let sourceVersion: String
    let schemaVersion: String

    init(sourceVersion: String, schemaVersion: String) {
        self.sourceVersion = sourceVersion
        self.schemaVersion = schemaVersion
    }

    init(_ source: LocalActivitySourceMetadata) {
        sourceVersion = source.sourceVersion
        schemaVersion = source.schemaVersion
    }
}

struct WeeklyUsageEvidence: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let accountPartitionID: String
    let limitID: String
    let windowDurationMinutes: Int
    let allowanceResetsAt: Date
    let interval: DateInterval
    let isComplete: Bool
    let accountMovementPoints: Double
    let accountTokenActivity: Int64
    let localTokenActivity: Int64?
    let localCoveragePercent: Double?
    let boundaryQuality: UsageBoundaryQuality
    let maximumAccountGap: TimeInterval
    let modelShares: [String: Double]
    let modelAttributionPercent: Double
    let reasoningShares: [String: Double]
    let reasoningAttributionPercent: Double
    let cachedInputShare: Double?
    let containsUnknownCorrection: Bool
    let containsAccountChange: Bool
    let containsCounterDecrease: Bool
    let tokenDefinitionsAlign: Bool
    let localSourceContinuous: Bool
    let localSourceReason: String?

    var allowancePointsPerMillionTokens: Double? {
        guard intensityUnavailableReason == nil,
              accountMovementPoints.isFinite,
              accountMovementPoints >= 0,
              accountMovementPoints <= 100,
              accountTokenActivity > 0 else {
            return nil
        }
        return accountMovementPoints
            / (Double(accountTokenActivity) / 1_000_000)
    }

    var intensityUnavailableReason: String? {
        if windowDurationMinutes != UsageHistoryPolicy.weeklyDurationMinutes {
            return "The selected interval is not the weekly allowance"
        }
        if boundaryQuality == .unbounded {
            return "Account boundaries are unbounded"
        }
        if !maximumAccountGap.isFinite
            || maximumAccountGap < 0
            || maximumAccountGap > 6 * 60 * 60 {
            return "Account samples are more than 6 hours apart"
        }
        if containsAccountChange {
            return "The account or plan changed in this interval"
        }
        if containsUnknownCorrection {
            return "An unknown reset or correction occurred in this interval"
        }
        if containsCounterDecrease {
            return "The account token counter decreased in this interval"
        }
        if !accountMovementPoints.isFinite
            || accountMovementPoints < 0
            || accountMovementPoints > 100 {
            return "Account Movement is invalid"
        }
        if accountTokenActivity <= 0 {
            return "Account Token Activity is unavailable"
        }
        return nil
    }

    var coverage: CoverageLevel {
        guard intensityUnavailableReason == nil else {
            return .unavailable
        }
        guard boundaryQuality != .unbounded else {
            return .unavailable
        }
        guard maximumAccountGap <= 6 * 60 * 60 else {
            return .low
        }
        guard tokenDefinitionsAlign else {
            return .unavailable
        }
        guard localSourceContinuous else {
            return .low
        }
        guard let localCoveragePercent else {
            return .unavailable
        }
        guard localCoveragePercent >= 50 else {
            return .low
        }
        if boundaryQuality == .tight,
           maximumAccountGap <= 30 * 60,
           localCoveragePercent >= 80 {
            return isComplete ? .complete : .high
        }
        return .partial
    }

    var coverageReason: String? {
        if let intensityUnavailableReason {
            return intensityUnavailableReason
        }
        if let localSourceReason {
            return localSourceReason
        }
        if !tokenDefinitionsAlign {
            return "Token definitions have not been proven compatible"
        }
        if boundaryQuality == .unbounded {
            return "Account boundaries are unbounded"
        }
        if maximumAccountGap > 6 * 60 * 60 {
            return "Account samples are more than 6 hours apart"
        }
        guard let localCoveragePercent else {
            return "Local Coverage is unavailable"
        }
        if localCoveragePercent < 50 {
            return "Local Coverage is below 50%"
        }
        if boundaryQuality == .loose {
            return "Weekly boundaries are within 1 hour"
        }
        if maximumAccountGap > 30 * 60 {
            return "Account samples are more than 30 minutes apart"
        }
        if localCoveragePercent < 80 {
            return "Local Coverage is below 80%"
        }
        return isComplete
            ? nil
            : "Current weekly interval is still in progress"
    }
}

struct ReferenceBaseline: Equatable, Sendable {
    static let currentPolicyVersion = 1

    let id: String
    let intervalIDs: [String]
    let policyVersion: Int
    let interval: DateInterval
    let allowancePointsPerMillionTokens: Double
    let isPinned: Bool
    let comparability: WorkloadComparability
}

struct EquivalentCapacityEstimate: Equatable, Sendable {
    let tokens: Int64
    let lowerTokens: Int64
    let upperTokens: Int64
    let confidence: ConfidenceLevel
}

struct UsagePerTokenComparison: Equatable, Sendable {
    let baseline: ReferenceBaseline
    let multiplier: Double
    let confidence: ConfidenceLevel
    let caveat: String?
    let equivalentCapacity: EquivalentCapacityEstimate
}

struct UsagePerTokenChartPoint: Equatable, Identifiable, Sendable {
    let evidence: WeeklyUsageEvidence
    let multiplier: Double
    let comparability: WorkloadComparability
    let confidence: ConfidenceLevel
    let caveat: String?
    let isCurrent: Bool

    var id: String { evidence.id }
    var date: Date { evidence.interval.end }
}

struct UsagePerTokenSnapshot: Equatable, Sendable {
    let current: WeeklyUsageEvidence?
    let history: [WeeklyUsageEvidence]
    let comparison: UsagePerTokenComparison?
    let points: [UsagePerTokenChartPoint]
    let eligiblePinnedBaselines: [WeeklyUsageEvidence]
    let reason: String?

    func selectingBaseline(
        _ intervalID: String?
    ) -> UsagePerTokenSnapshot {
        UsagePerTokenEngine.evaluate(
            current: current,
            history: history,
            pinnedBaselineID: intervalID
        )
    }
}

struct WeeklyUsageEvidenceSet: Equatable, Sendable {
    let current: WeeklyUsageEvidence?
    let history: [WeeklyUsageEvidence]
}

enum WeeklyUsageEvidenceBuilder {
    private static let tightBoundary: TimeInterval = 15 * 60
    private static let looseBoundary: TimeInterval = 60 * 60

    static func build(
        samples: [UsageSample],
        localFacts: [LocalActivityFact],
        localObservation: LocalActivityObservation,
        accountPartitionID: String,
        limitID: String,
        currentReset: Date,
        compatibleTokenSources: Set<LocalTokenDefinitionSource>
    ) -> WeeklyUsageEvidenceSet {
        let grouped = Dictionary(grouping: samples, by: \.resetsAt)
        let localFactIndex = LocalActivityFactIndex(localFacts)
        let latestComparisonBreak = samples
            .lazy
            .filter(\.comparisonBreak)
            .map(\.observedAt)
            .max()
        let evidence = grouped.compactMap { reset, samples in
            buildInterval(
                samples: samples,
                localFactIndex: localFactIndex,
                localObservation: localObservation,
                accountPartitionID: accountPartitionID,
                limitID: limitID,
                reset: reset,
                currentReset: currentReset,
                compatibleTokenSources: compatibleTokenSources,
                latestComparisonBreak: latestComparisonBreak
            )
        }
        .sorted { $0.interval.start < $1.interval.start }
        return WeeklyUsageEvidenceSet(
            current: evidence.first {
                $0.allowanceResetsAt == currentReset
            },
            history: evidence.filter {
                $0.allowanceResetsAt < currentReset
            }
        )
    }

    private static func buildInterval(
        samples: [UsageSample],
        localFactIndex: LocalActivityFactIndex,
        localObservation: LocalActivityObservation,
        accountPartitionID: String,
        limitID: String,
        reset: Date,
        currentReset: Date,
        compatibleTokenSources: Set<LocalTokenDefinitionSource>,
        latestComparisonBreak: Date?
    ) -> WeeklyUsageEvidence? {
        let windowStart = reset.addingTimeInterval(
            -Double(UsageHistoryPolicy.weeklyDurationMinutes) * 60
        )
        let ordered = samples
            .filter {
                $0.observedAt >= windowStart.addingTimeInterval(
                    -looseBoundary
                )
                    && $0.observedAt <= reset
            }
            .sorted { $0.observedAt < $1.observedAt }
        let tokenReadings = ordered.filter { $0.lifetimeTokens != nil }
        guard let start = tokenReadings.min(by: {
            abs($0.observedAt.timeIntervalSince(windowStart))
                < abs($1.observedAt.timeIntervalSince(windowStart))
        }),
        abs(start.observedAt.timeIntervalSince(windowStart))
            <= looseBoundary else {
            return nil
        }
        let isCurrent = reset == currentReset
        let end: UsageSample?
        if isCurrent {
            end = tokenReadings.last
        } else {
            end = tokenReadings.min(by: {
                abs($0.observedAt.timeIntervalSince(reset))
                    < abs($1.observedAt.timeIntervalSince(reset))
            })
        }
        guard let end,
              end.observedAt > start.observedAt,
              let startTokens = start.lifetimeTokens,
              let endTokens = end.lifetimeTokens else {
            return nil
        }
        let startOffset = abs(
            start.observedAt.timeIntervalSince(windowStart)
        )
        let endOffset = isCurrent
            ? 0
            : abs(end.observedAt.timeIntervalSince(reset))
        let boundaryQuality: UsageBoundaryQuality
        if startOffset <= tightBoundary && endOffset <= tightBoundary {
            boundaryQuality = .tight
        } else if startOffset <= looseBoundary
                    && endOffset <= looseBoundary {
            boundaryQuality = .loose
        } else {
            boundaryQuality = .unbounded
        }
        let interval = DateInterval(
            start: start.observedAt,
            end: end.observedAt
        )
        let intervalSamples = ordered.filter {
            $0.observedAt >= interval.start
                && $0.observedAt <= interval.end
        }
        let containsComparisonBreak = intervalSamples.contains {
            $0.comparisonBreak
                && $0.observedAt > interval.start
                && $0.observedAt <= interval.end
        }
        if let latestComparisonBreak,
           interval.end < latestComparisonBreak
            || (
                interval.end == latestComparisonBreak
                    && !containsComparisonBreak
            ) {
            return nil
        }
        let maximumGap = zip(
            intervalSamples,
            intervalSamples.dropFirst()
        ).reduce(0) {
            max(
                $0,
                $1.1.observedAt.timeIntervalSince($1.0.observedAt)
            )
        }
        let containsCorrection = zip(
            intervalSamples,
            intervalSamples.dropFirst()
        ).contains {
            $0.1.remainingPercent
                > $0.0.remainingPercent
                    + UsageHistoryPolicy.correctionTolerance
        }
        let boundedTokenReadings = intervalSamples.compactMap { sample in
                sample.lifetimeTokens.map {
                    (sample.observedAt, $0)
                }
            }
        let containsCounterDecrease = zip(
            boundedTokenReadings,
            boundedTokenReadings.dropFirst()
        ).contains { $0.1.1 < $0.0.1 }
        let tokenDifference = endTokens.subtractingReportingOverflow(
            startTokens
        )
        guard !tokenDifference.overflow else { return nil }
        let intervalFacts = localFactIndex.facts(in: interval)
        let workload = workload(
            facts: intervalFacts,
            interval: interval
        )
        let localSource = localSourceStatus(
            localObservation,
            interval: interval,
            intervalBreakReason: workload.sourceBreakReason
        )
        let accountTokens = tokenDifference.partialValue
        let tokenDefinitionsAlign = tokenDefinitionsAlign(
            facts: intervalFacts,
            compatibleSources: compatibleTokenSources
        )
        let localCoverage = localCoveragePercent(
            localTokens: workload.tokens,
            accountTokens: accountTokens,
            definitionsAlign: tokenDefinitionsAlign
                && localSource.continuous
        )
        return WeeklyUsageEvidence(
            id: intervalID(limitID: limitID, reset: reset),
            accountPartitionID: accountPartitionID,
            limitID: limitID,
            windowDurationMinutes: UsageHistoryPolicy.weeklyDurationMinutes,
            allowanceResetsAt: reset,
            interval: interval,
            isComplete: !isCurrent
                && boundaryQuality != .unbounded,
            accountMovementPoints:
                start.remainingPercent - end.remainingPercent,
            accountTokenActivity: accountTokens,
            localTokenActivity: workload.tokens,
            localCoveragePercent: localCoverage,
            boundaryQuality: boundaryQuality,
            maximumAccountGap: maximumGap,
            modelShares: shares(
                workload.models,
                totalTokens: workload.tokens
            ),
            modelAttributionPercent: attributionPercent(
                workload.models,
                totalTokens: workload.tokens
            ),
            reasoningShares: shares(
                workload.reasoning,
                totalTokens: workload.tokens
            ),
            reasoningAttributionPercent: attributionPercent(
                workload.reasoning,
                totalTokens: workload.tokens
            ),
            cachedInputShare: workload.cachedInputShare,
            containsUnknownCorrection: containsCorrection,
            containsAccountChange: containsComparisonBreak,
            containsCounterDecrease: containsCounterDecrease
                || endTokens < startTokens,
            tokenDefinitionsAlign: tokenDefinitionsAlign,
            localSourceContinuous: localSource.continuous,
            localSourceReason: localSource.reason
        )
    }

    private static func localSourceStatus(
        _ observation: LocalActivityObservation,
        interval: DateInterval,
        intervalBreakReason: String?
    ) -> (continuous: Bool, reason: String?) {
        if let intervalBreakReason {
            return (false, intervalBreakReason)
        }
        switch observation {
        case .continuous:
            return (true, nil)
        case let .gap(_, observedAt, reason):
            return interval.contains(observedAt)
                ? (false, reason)
                : (true, nil)
        case let .unavailable(reason):
            return (false, reason)
        }
    }

    private static func intervalID(
        limitID: String,
        reset: Date
    ) -> String {
        "\(limitID)|\(Int64(reset.timeIntervalSince1970.rounded()))"
    }

    private static func tokenDefinitionsAlign(
        facts: [LocalActivityFact],
        compatibleSources: Set<LocalTokenDefinitionSource>
    ) -> Bool {
        guard !compatibleSources.isEmpty else { return false }
        let observedSources = Set(
            facts.lazy
                .filter { $0.key == .token }
                .map { LocalTokenDefinitionSource($0.source) }
        )
        return !observedSources.isEmpty
            && observedSources.isSubset(of: compatibleSources)
    }

    private struct Workload {
        let tokens: Int64?
        let models: [String: Int64]
        let reasoning: [String: Int64]
        let cachedInputShare: Double?
        let sourceBreakReason: String?
    }

    private static func workload(
        facts: [LocalActivityFact],
        interval: DateInterval
    ) -> Workload {
        let parser = LocalEventTimestampParser()
        let sourceBreakReason = facts.lazy.compactMap {
            fact -> String? in
            guard fact.key == .token,
                  let timestamp = fact.eventTimestamp,
                  let date = parser.date(from: timestamp),
                  date >= interval.start,
                  date < interval.end else {
                return nil
            }
            switch fact.reason {
            case "source-discontinuity":
                return "Local token source changed in this interval"
            case "segment-baseline":
                return "Local token activity starts from an unbounded counter"
            case "cumulative-counter-decreased":
                return "Local token counter decreased in this interval"
            default:
                return nil
            }
        }.first
        var seen = Set<String>()
        let selected = facts.compactMap {
            fact -> (Int64, LocalActivityContext?, LocalTokenUsage?)? in
            guard fact.key == .token,
                  fact.availability == .available,
                  let eventID = fact.eventID,
                  seen.insert(eventID).inserted,
                  let timestamp = fact.eventTimestamp,
                  let date = parser.date(from: timestamp),
                  date >= interval.start,
                  date < interval.end,
                  let tokens = fact.numericDelta,
                  tokens >= 0 else {
                return nil
            }
            return (tokens, fact.context, fact.tokenDelta)
        }
        var total: Int64 = 0
        var models: [String: Int64] = [:]
        var reasoning: [String: Int64] = [:]
        var cachedInput: Int64 = 0
        var input: Int64 = 0
        var hasCacheEvidence = !selected.isEmpty
        for (tokens, context, tokenDelta) in selected {
            guard add(tokens, to: &total) else {
                return Workload(
                    tokens: nil,
                    models: [:],
                    reasoning: [:],
                    cachedInputShare: nil,
                    sourceBreakReason: sourceBreakReason
                )
            }
            if let model = context?.effectiveModel {
                var modelTokens = models[model] ?? 0
                guard add(tokens, to: &modelTokens) else {
                    return Workload(
                        tokens: nil,
                        models: [:],
                        reasoning: [:],
                        cachedInputShare: nil,
                        sourceBreakReason: sourceBreakReason
                    )
                }
                models[model] = modelTokens
            }
            if let level = context?.reasoning {
                var reasoningTokens = reasoning[level] ?? 0
                guard add(tokens, to: &reasoningTokens) else {
                    return Workload(
                        tokens: nil,
                        models: [:],
                        reasoning: [:],
                        cachedInputShare: nil,
                        sourceBreakReason: sourceBreakReason
                    )
                }
                reasoning[level] = reasoningTokens
            }
            guard let tokenDelta,
                  tokenDelta.observedComponents.contains(.input),
                  tokenDelta.observedComponents.contains(.cachedInput) else {
                hasCacheEvidence = false
                continue
            }
            guard add(tokenDelta.inputTokens, to: &input),
                  add(
                      tokenDelta.cachedInputTokens,
                      to: &cachedInput
                  ) else {
                return Workload(
                    tokens: nil,
                    models: [:],
                    reasoning: [:],
                    cachedInputShare: nil,
                    sourceBreakReason: sourceBreakReason
                )
            }
        }
        let cacheShare = hasCacheEvidence && input > 0
            ? Double(cachedInput) / Double(input)
            : nil
        return Workload(
            tokens: total,
            models: models,
            reasoning: reasoning,
            cachedInputShare: cacheShare,
            sourceBreakReason: sourceBreakReason
        )
    }

    private static func add(
        _ value: Int64,
        to total: inout Int64
    ) -> Bool {
        let result = total.addingReportingOverflow(value)
        guard !result.overflow else { return false }
        total = result.partialValue
        return true
    }

    private static func shares(
        _ values: [String: Int64],
        totalTokens: Int64?
    ) -> [String: Double] {
        guard let totalTokens, totalTokens > 0 else {
            return [:]
        }
        return values.mapValues {
            Double($0) / Double(totalTokens)
        }
    }

    private static func attributionPercent(
        _ values: [String: Int64],
        totalTokens: Int64?
    ) -> Double {
        guard let totalTokens, totalTokens > 0 else { return 0 }
        var attributed: Int64 = 0
        guard values.values.allSatisfy({
            add($0, to: &attributed)
        }) else {
            return 0
        }
        return min(
            Double(attributed) / Double(totalTokens) * 100,
            100
        )
    }

    private static func localCoveragePercent(
        localTokens: Int64?,
        accountTokens: Int64,
        definitionsAlign: Bool
    ) -> Double? {
        guard definitionsAlign,
              let localTokens,
              localTokens >= 0,
              accountTokens > 0 else {
            return nil
        }
        let percentage = Double(localTokens) / Double(accountTokens) * 100
        guard percentage <= 102 else { return nil }
        return min(percentage, 100)
    }
}

enum UsagePerTokenEngine {
    private static let highShareDelta = 0.10
    private static let mediumShareDelta = 0.20
    private static let highLocalCoverage = 80.0
    private static let mediumLocalCoverage = 50.0
    private static let highMaximumGap: TimeInterval = 30 * 60
    private static let mediumMaximumGap: TimeInterval = 6 * 60 * 60

    static func evaluate(
        current: WeeklyUsageEvidence?,
        history: [WeeklyUsageEvidence],
        pinnedBaselineID: String?
    ) -> UsagePerTokenSnapshot {
        guard let current,
              let currentIntensity =
                current.allowancePointsPerMillionTokens else {
            return UsagePerTokenSnapshot(
                current: current,
                history: history,
                comparison: nil,
                points: [],
                eligiblePinnedBaselines: [],
                reason: current?.intensityUnavailableReason
                    ?? "Account Movement and Account Token Activity need the same bounded interval"
            )
        }
        guard currentIntensity > 0 else {
            return UsagePerTokenSnapshot(
                current: current,
                history: history,
                comparison: nil,
                points: [],
                eligiblePinnedBaselines: [],
                reason: "No Account Movement was observed"
            )
        }
        if let reason = comparisonUnavailableReason(current) {
            return UsagePerTokenSnapshot(
                current: current,
                history: history,
                comparison: nil,
                points: [],
                eligiblePinnedBaselines: [],
                reason: reason
            )
        }
        let previous = history
            .filter {
                $0.interval.end <= current.interval.start
                    && $0.isComplete
                    && $0.allowancePointsPerMillionTokens != nil
            }
            .sorted { $0.interval.end < $1.interval.end }
        let eligible = previous.filter {
            comparability(current, $0) != .notComparable
        }

        let baseline: ReferenceBaseline?
        if let pinnedBaselineID {
            baseline = eligible
                .first { $0.id == pinnedBaselineID }
                .flatMap {
                    reference(
                        from: [$0],
                        current: current,
                        isPinned: true
                    )
                }
        } else {
            let high = previous.filter {
                comparability(current, $0) == .high
            }
            baseline = high.count >= 4
                ? reference(
                    from: Array(high.suffix(4)),
                    current: current,
                    isPinned: false
                )
                : nil
        }

        guard let baseline,
              baseline.allowancePointsPerMillionTokens > 0 else {
            return UsagePerTokenSnapshot(
                current: current,
                history: history,
                comparison: nil,
                points: [],
                eligiblePinnedBaselines: eligible,
                reason: pinnedBaselineID == nil
                    ? "Not enough comparable weeks"
                    : pinnedFailureReason(
                        pinnedBaselineID,
                        current: current,
                        previous: previous
                    )
            )
        }
        let confidence: ConfidenceLevel =
            baseline.comparability == .high ? .high : .medium
        let referenceIntervals = history.filter {
            baseline.intervalIDs.contains($0.id)
        }
        let observedIntensities = [currentIntensity]
            + referenceIntervals.compactMap(
                \.allowancePointsPerMillionTokens
            )
        let capacities = observedIntensities.compactMap {
            capacity(for: $0)
        }
        guard let estimate = capacity(for: currentIntensity),
              let lower = capacities.min(),
              let upper = capacities.max() else {
            return UsagePerTokenSnapshot(
                current: current,
                history: history,
                comparison: nil,
                points: [],
                eligiblePinnedBaselines: eligible,
                reason: "Equivalent Capacity is not available"
            )
        }
        return UsagePerTokenSnapshot(
            current: current,
            history: history,
            comparison: UsagePerTokenComparison(
                baseline: baseline,
                multiplier: currentIntensity
                    / baseline.allowancePointsPerMillionTokens,
                confidence: confidence,
                caveat: confidence == .medium
                    ? comparabilityCaveats(
                        current,
                        referenceIntervals
                    ).joined(separator: " · ")
                    : nil,
                equivalentCapacity: EquivalentCapacityEstimate(
                    tokens: estimate,
                    lowerTokens: lower,
                    upperTokens: upper,
                    confidence: confidence
                )
            ),
            points: chartPoints(
                current: current,
                history: history,
                baseline: baseline
            ),
            eligiblePinnedBaselines: eligible,
            reason: nil
        )
    }

    static func comparability(
        _ current: WeeklyUsageEvidence,
        _ reference: WeeklyUsageEvidence
    ) -> WorkloadComparability {
        guard !current.accountPartitionID.isEmpty,
              current.accountPartitionID == reference.accountPartitionID,
              !current.limitID.isEmpty,
              current.limitID == reference.limitID,
              isWeekly(current),
              isWeekly(reference),
              current.boundaryQuality != .unbounded,
              reference.boundaryQuality != .unbounded,
              current.maximumAccountGap <= mediumMaximumGap,
              reference.maximumAccountGap <= mediumMaximumGap,
              current.maximumAccountGap.isFinite,
              reference.maximumAccountGap.isFinite,
              current.maximumAccountGap >= 0,
              reference.maximumAccountGap >= 0,
              !hasHardBreak(current),
              !hasHardBreak(reference),
              current.accountTokenActivity > 0,
              reference.accountTokenActivity > 0,
              current.tokenDefinitionsAlign,
              reference.tokenDefinitionsAlign,
              current.localSourceContinuous,
              reference.localSourceContinuous,
              let currentCoverage = current.localCoveragePercent,
              let referenceCoverage = reference.localCoveragePercent,
              validPercent(currentCoverage),
              validPercent(referenceCoverage),
              currentCoverage >= mediumLocalCoverage,
              referenceCoverage >= mediumLocalCoverage,
              validAttribution(current.modelAttributionPercent),
              validAttribution(reference.modelAttributionPercent),
              validAttribution(current.reasoningAttributionPercent),
              validAttribution(reference.reasoningAttributionPercent),
              current.modelAttributionPercent >= mediumLocalCoverage,
              reference.modelAttributionPercent >= mediumLocalCoverage,
              current.reasoningAttributionPercent >= mediumLocalCoverage,
              reference.reasoningAttributionPercent >= mediumLocalCoverage,
              validShares(
                current.modelShares,
                attributionPercent: current.modelAttributionPercent
              ),
              validShares(
                reference.modelShares,
                attributionPercent: reference.modelAttributionPercent
              ),
              validShares(
                current.reasoningShares,
                attributionPercent: current.reasoningAttributionPercent
              ),
              validShares(
                reference.reasoningShares,
                attributionPercent: reference.reasoningAttributionPercent
              ),
              let currentModel = dominantShare(
                in: current.modelShares,
                attributionPercent: current.modelAttributionPercent
              ),
              let referenceModel = dominantShare(
                in: reference.modelShares,
                attributionPercent: reference.modelAttributionPercent
              ),
              currentModel.0 == referenceModel.0,
              let currentReasoning = dominantShare(
                in: current.reasoningShares,
                attributionPercent: current.reasoningAttributionPercent
              ),
              let referenceReasoning = dominantShare(
                in: reference.reasoningShares,
                attributionPercent: reference.reasoningAttributionPercent
              ),
              currentReasoning.0 == referenceReasoning.0,
              let currentCache = current.cachedInputShare,
              let referenceCache = reference.cachedInputShare,
              validShare(currentCache),
              validShare(referenceCache) else {
            return .notComparable
        }
        let maximumDelta = max(
            shareDelta(current.modelShares, reference.modelShares),
            shareDelta(current.reasoningShares, reference.reasoningShares),
            abs(currentCache - referenceCache)
        )
        if currentCoverage >= highLocalCoverage,
           referenceCoverage >= highLocalCoverage,
           current.boundaryQuality == .tight,
           reference.boundaryQuality == .tight,
           current.maximumAccountGap <= highMaximumGap,
           reference.maximumAccountGap <= highMaximumGap,
           current.modelAttributionPercent >= highLocalCoverage,
           reference.modelAttributionPercent >= highLocalCoverage,
           current.reasoningAttributionPercent >= highLocalCoverage,
           reference.reasoningAttributionPercent >= highLocalCoverage,
           maximumDelta <= highShareDelta {
            return .high
        }
        return maximumDelta <= mediumShareDelta
            ? .medium
            : .notComparable
    }

    private static func reference(
        from intervals: [WeeklyUsageEvidence],
        current: WeeklyUsageEvidence,
        isPinned: Bool
    ) -> ReferenceBaseline? {
        let values = intervals.compactMap(
            \.allowancePointsPerMillionTokens
        ).sorted()
        guard values.count == intervals.count,
              let first = intervals.first,
              let last = intervals.last else {
            return nil
        }
        let middle = values.count / 2
        let median = values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
        let levels = intervals.map { comparability(current, $0) }
        let level: WorkloadComparability = levels.allSatisfy { $0 == .high }
            ? .high
            : .medium
        return ReferenceBaseline(
            id: isPinned ? first.id : intervals.map(\.id).joined(separator: "|"),
            intervalIDs: intervals.map(\.id),
            policyVersion: ReferenceBaseline.currentPolicyVersion,
            interval: DateInterval(
                start: first.interval.start,
                end: last.interval.end
            ),
            allowancePointsPerMillionTokens: median,
            isPinned: isPinned,
            comparability: level
        )
    }

    private static func isWeekly(
        _ evidence: WeeklyUsageEvidence
    ) -> Bool {
        evidence.windowDurationMinutes == UsageHistoryPolicy.weeklyDurationMinutes
    }

    private static func hasHardBreak(
        _ evidence: WeeklyUsageEvidence
    ) -> Bool {
        evidence.containsUnknownCorrection
            || evidence.containsAccountChange
            || evidence.containsCounterDecrease
    }

    private static func dominantShare(
        in shares: [String: Double],
        attributionPercent: Double
    ) -> (String, Double)? {
        let ordered = shares.sorted { $0.value > $1.value }
        guard let first = ordered.first else { return nil }
        let second = ordered.dropFirst().first?.value ?? 0
        let unknown = max(0, 1 - attributionPercent / 100)
        if first.value <= second + unknown + 0.001 {
            return nil
        }
        return first
    }

    private static func validShares(
        _ shares: [String: Double],
        attributionPercent: Double
    ) -> Bool {
        guard !shares.isEmpty,
              shares.keys.allSatisfy({ !$0.isEmpty }),
              shares.values.allSatisfy(validShare) else {
            return false
        }
        return abs(
            shares.values.reduce(0, +) - attributionPercent / 100
        ) <= 0.001
    }

    private static func validShare(_ share: Double) -> Bool {
        share.isFinite && share >= 0 && share <= 1
    }

    private static func validPercent(_ percent: Double) -> Bool {
        percent.isFinite && percent >= 0 && percent <= 100
    }

    private static func validAttribution(_ percent: Double) -> Bool {
        validPercent(percent)
    }

    private static func comparabilityCaveats(
        _ current: WeeklyUsageEvidence,
        _ references: [WeeklyUsageEvidence]
    ) -> [String] {
        var caveats: [String] = []
        if references.contains(where: {
            ($0.localCoveragePercent ?? 0) < highLocalCoverage
        }) || (current.localCoveragePercent ?? 0) < highLocalCoverage {
            caveats.append("Local Coverage is below 80%")
        }
        if references.contains(where: {
            $0.modelAttributionPercent < highLocalCoverage
        }) || current.modelAttributionPercent < highLocalCoverage {
            caveats.append(
                "Model metadata covers less than 80% of Local Token Activity"
            )
        }
        if references.contains(where: {
            $0.reasoningAttributionPercent < highLocalCoverage
        }) || current.reasoningAttributionPercent < highLocalCoverage {
            caveats.append(
                "Reasoning metadata covers less than 80% of Local Token Activity"
            )
        }
        if references.contains(where: {
            $0.boundaryQuality != .tight
        }) || current.boundaryQuality != .tight {
            caveats.append("Weekly boundaries are loose")
        }
        if references.contains(where: {
            $0.maximumAccountGap > highMaximumGap
        }) || current.maximumAccountGap > highMaximumGap {
            caveats.append("Account samples are more than 30 minutes apart")
        }
        if references.contains(where: {
            shareDelta(current.modelShares, $0.modelShares)
                > highShareDelta
        }) {
            caveats.append(
                "Model mix differs by more than 10 percentage points"
            )
        }
        if references.contains(where: {
            shareDelta(current.reasoningShares, $0.reasoningShares)
                > highShareDelta
        }) {
            caveats.append(
                "Reasoning mix differs by more than 10 percentage points"
            )
        }
        if references.contains(where: {
            guard let currentCache = current.cachedInputShare,
                  let referenceCache = $0.cachedInputShare else {
                return false
            }
            return abs(currentCache - referenceCache) > highShareDelta
        }) {
            caveats.append(
                "Cached input share differs by more than 10 percentage points"
            )
        }
        return caveats
    }

    private static func pinnedFailureReason(
        _ pinnedBaselineID: String?,
        current: WeeklyUsageEvidence,
        previous: [WeeklyUsageEvidence]
    ) -> String {
        guard let pinnedBaselineID,
              let pinned = previous.first(where: {
                  $0.id == pinnedBaselineID
              }) else {
            return "Pinned baseline is not a complete prior weekly interval"
        }
        if current.accountPartitionID != pinned.accountPartitionID {
            return "Pinned baseline belongs to another account partition"
        }
        if !isWeekly(pinned) || current.limitID != pinned.limitID {
            return "Pinned baseline does not use the same weekly limit"
        }
        if pinned.boundaryQuality == .unbounded {
            return "Pinned baseline has an unbounded account reading"
        }
        if hasHardBreak(pinned) {
            return "Pinned baseline contains a reset, account change, correction, or counter decrease"
        }
        if !pinned.localSourceContinuous {
            return pinned.localSourceReason
                ?? "Pinned baseline has a local source gap"
        }
        if !pinned.tokenDefinitionsAlign {
            return "Pinned baseline token definitions have not been proven compatible"
        }
        if (pinned.localCoveragePercent ?? 0) < mediumLocalCoverage {
            return "Pinned baseline Local Coverage is below 50%"
        }
        return "Pinned baseline workload mix is not comparable"
    }

    private static func comparisonUnavailableReason(
        _ evidence: WeeklyUsageEvidence
    ) -> String? {
        if !evidence.tokenDefinitionsAlign {
            return "Token definitions have not been proven compatible"
        }
        if !evidence.localSourceContinuous {
            return evidence.localSourceReason
                ?? "Local activity has a source gap"
        }
        guard let localCoverage = evidence.localCoveragePercent else {
            return "Local Coverage is unavailable"
        }
        if localCoverage < mediumLocalCoverage {
            return "Local Coverage is below 50%"
        }
        if evidence.modelAttributionPercent < mediumLocalCoverage {
            return "Model metadata covers less than 50% of Local Token Activity"
        }
        if evidence.reasoningAttributionPercent < mediumLocalCoverage {
            return "Reasoning metadata covers less than 50% of Local Token Activity"
        }
        guard validShares(
                evidence.modelShares,
                attributionPercent: evidence.modelAttributionPercent
              ),
              validShares(
                evidence.reasoningShares,
                attributionPercent: evidence.reasoningAttributionPercent
              ),
              dominantShare(
                in: evidence.modelShares,
                attributionPercent: evidence.modelAttributionPercent
              ) != nil,
              dominantShare(
                in: evidence.reasoningShares,
                attributionPercent: evidence.reasoningAttributionPercent
              ) != nil,
              let cachedInputShare = evidence.cachedInputShare,
              validShare(cachedInputShare) else {
            return "Workload mix is unavailable"
        }
        return nil
    }

    private static func shareDelta(
        _ lhs: [String: Double],
        _ rhs: [String: Double]
    ) -> Double {
        Set(lhs.keys).union(rhs.keys).reduce(0) { result, key in
            max(result, abs((lhs[key] ?? 0) - (rhs[key] ?? 0)))
        }
    }

    private static func capacity(
        for intensity: Double
    ) -> Int64? {
        guard intensity.isFinite, intensity > 0 else { return nil }
        let tokens = 100 / intensity * 1_000_000
        guard tokens.isFinite,
              tokens >= 0,
              tokens < Double(Int64.max) else {
            return nil
        }
        return Int64(tokens.rounded())
    }

    private static func chartPoints(
        current: WeeklyUsageEvidence,
        history: [WeeklyUsageEvidence],
        baseline: ReferenceBaseline
    ) -> [UsagePerTokenChartPoint] {
        let values = history + [current]
        let baselineIntervals = history.filter {
            baseline.intervalIDs.contains($0.id)
        }
        return values.compactMap { evidence in
            guard let intensity =
                    evidence.allowancePointsPerMillionTokens,
                  intensity >= 0 else {
                return nil
            }
            let level = evidence.id == current.id
                ? baseline.comparability
                : comparability(current, evidence)
            guard evidence.id == current.id
                    || level != .notComparable else {
                return nil
            }
            let confidence: ConfidenceLevel
            switch level {
            case .high:
                confidence = .high
            case .medium:
                confidence = .medium
            case .notComparable:
                confidence = .low
            }
            return UsagePerTokenChartPoint(
                evidence: evidence,
                multiplier:
                    intensity / baseline.allowancePointsPerMillionTokens,
                comparability: level,
                confidence: confidence,
                caveat: level == .medium
                    ? comparabilityCaveats(
                        current,
                        evidence.id == current.id
                            ? baselineIntervals
                            : [evidence]
                    ).joined(separator: " · ")
                    : nil,
                isCurrent: evidence.id == current.id
            )
        }
        .sorted { $0.date < $1.date }
    }
}
