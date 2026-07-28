import Foundation

struct ActiveTimeWeekEvidence: Equatable, Sendable {
    let usage: WeeklyUsageEvidence
    let activeTimeSeconds: TimeInterval
    let coverage: CoverageLevel
    let reason: String?
}

struct ActiveTimeAvailableEstimate: Equatable, Sendable {
    let lowerSeconds: TimeInterval
    let upperSeconds: TimeInterval
    let coverage: CoverageLevel
    let confidence: ConfidenceLevel
    let referenceIntervalIDs: [String]
    let caveat: String?

    func accessibilityValue(
        duration: (TimeInterval) -> String
    ) -> String {
        let lower = duration(lowerSeconds)
        let upper = duration(upperSeconds)
        let range = lower == upper ? lower : "\(lower) to \(upper)"
        var parts = [
            "Estimated active time available \(range)",
            "Basis current week plus "
                + "\(referenceIntervalIDs.count) comparable weeks",
            "Confidence \(confidence.displayName)"
        ]
        if let caveat {
            parts.append(caveat)
        }
        return parts.joined(separator: ". ")
    }
}

struct ActiveTimeAvailabilitySnapshot: Equatable, Sendable {
    let activeTimeThisWeek: TimeInterval
    let activeTimeCoverage: CoverageLevel
    let activeTimeReason: String?
    let observedInterval: DateInterval?
    let estimate: ActiveTimeAvailableEstimate?
    let reason: String?
}

struct ActiveTimeHistorySelection: Equatable, Sendable {
    let evidence: [ActiveTimeWeekEvidence]
    let unavailableReason: String?
}

enum ActiveTimeWeekEvidenceBuilder {
    static func build(
        currentUsage: WeeklyUsageEvidence?,
        usage: [WeeklyUsageEvidence],
        facts: [LocalActivityFact],
        projections: [ThreadProjection],
        observation: LocalActivityObservation
    ) -> ActiveTimeHistorySelection {
        guard let currentUsage else {
            return ActiveTimeHistorySelection(
                evidence: [],
                unavailableReason: nil
            )
        }
        let factIndex = LocalActivityFactIndex(facts)
        var result: [ActiveTimeWeekEvidence] = []
        var workloadMismatchCount = 0
        for candidate in usage.sorted(
            by: { $0.interval.end > $1.interval.end }
        ) {
            guard UsagePerTokenEngine.comparability(
                currentUsage,
                candidate
            ) == .high else {
                if candidate.isComplete,
                   candidate.coverage == .complete
                    || candidate.coverage == .high {
                    workloadMismatchCount += 1
                }
                continue
            }
            let timeline = ActivityTimelineAggregator.evaluate(
                facts: factIndex.activityFacts(in: candidate.interval),
                projections: projections,
                interval: candidate.interval,
                observation: scopedObservation(
                    for: candidate,
                    fallback: observation
                )
            )
            let slice = timeline.slice(
                in: candidate.interval,
                filters: .all
            )
            let evidence = ActiveTimeWeekEvidence(
                usage: candidate,
                activeTimeSeconds: slice.activeTime,
                coverage: slice.coverage,
                reason: slice.reason
            )
            guard isUsable(evidence) else { continue }
            result.append(evidence)
            if result.count == 4 { break }
        }
        return ActiveTimeHistorySelection(
            evidence: result.sorted {
                $0.usage.interval.end < $1.usage.interval.end
            },
            unavailableReason: result.count < 4
                && workloadMismatchCount >= 4
                ? "Recent workload mix is not comparable"
                : nil
        )
    }

    private static func isUsable(
        _ evidence: ActiveTimeWeekEvidence
    ) -> Bool {
        guard evidence.usage.isComplete,
              evidence.usage.accountMovementPoints.isFinite,
              evidence.usage.accountMovementPoints > 0,
              evidence.activeTimeSeconds.isFinite,
              evidence.activeTimeSeconds > 0 else {
            return false
        }
        let secondsPerPoint = evidence.activeTimeSeconds
            / evidence.usage.accountMovementPoints
        guard secondsPerPoint.isFinite, secondsPerPoint >= 0 else {
            return false
        }
        return evidence.coverage == .complete
            || evidence.coverage == .high
            || (
                evidence.coverage == .partial
                    && evidence.reason?.isEmpty == false
            )
    }

    private static func scopedObservation(
        for usage: WeeklyUsageEvidence,
        fallback: LocalActivityObservation
    ) -> LocalActivityObservation {
        let version: String
        switch fallback {
        case let .continuous(sourceVersion, _),
             let .gap(sourceVersion, _, _):
            version = sourceVersion
        case .unavailable:
            version = "unknown"
        }
        if !usage.localSourceContinuous {
            return .gap(
                sourceVersion: version,
                observedAt: usage.interval.start,
                reason: usage.localSourceReason
                    ?? "Local activity has a source gap"
            )
        }
        return .continuous(
            sourceVersion: version,
            observedAt: usage.interval.end
        )
    }

}

enum ActiveTimeAvailabilityEngine {
    static func evaluate(
        currentUsage: WeeklyUsageEvidence?,
        activeTimeThisWeek: TimeInterval,
        activeTimeCoverage: CoverageLevel,
        activeTimeReason: String?,
        history: [ActiveTimeWeekEvidence],
        historyUnavailableReason: String? = nil,
        usageRemainingPercent: Double
    ) -> ActiveTimeAvailabilitySnapshot {
        let unavailable: (String) -> ActiveTimeAvailabilitySnapshot = {
            ActiveTimeAvailabilitySnapshot(
                activeTimeThisWeek: activeTimeThisWeek,
                activeTimeCoverage: activeTimeCoverage,
                activeTimeReason: activeTimeReason,
                observedInterval: currentUsage?.interval,
                estimate: nil,
                reason: $0
            )
        }
        guard let currentUsage else {
            return unavailable("Current weekly evidence is unavailable")
        }
        guard activeTimeThisWeek.isFinite, activeTimeThisWeek >= 0 else {
            return unavailable("Active Time is unavailable")
        }
        guard usageRemainingPercent.isFinite,
              (0 ... 100).contains(usageRemainingPercent) else {
            return unavailable("Usage remaining is unavailable")
        }
        guard currentUsage.coverage == .complete
                || currentUsage.coverage == .high else {
            return unavailable(
                currentUsage.coverageReason
                    ?? "Current weekly Coverage is too low"
            )
        }
        let currentCaveat: String?
        if activeTimeCoverage == .complete || activeTimeCoverage == .high {
            currentCaveat = nil
        } else if activeTimeCoverage == .partial,
                  let activeTimeReason,
                  !activeTimeReason.isEmpty {
            currentCaveat = activeTimeReason
        } else {
            return unavailable(
                activeTimeReason ?? "Active Time Coverage is too low"
            )
        }
        guard currentUsage.accountMovementPoints > 0 else {
            return unavailable("Account Movement is zero")
        }

        let usableActivity = history.filter {
            $0.usage.isComplete
                && $0.activeTimeSeconds.isFinite
                && $0.activeTimeSeconds > 0
                && $0.usage.accountMovementPoints > 0
                && (
                    $0.coverage == .complete
                        || $0.coverage == .high
                        || (
                            $0.coverage == .partial
                                && $0.reason?.isEmpty == false
                        )
                )
        }
        let comparable = usableActivity.filter {
            UsagePerTokenEngine.comparability(
                    currentUsage,
                    $0.usage
                ) == .high
        }
        .sorted { $0.usage.interval.end < $1.usage.interval.end }
        guard comparable.count >= 4 else {
            return unavailable(
                historyUnavailableReason
                    ?? (usableActivity.count >= 4
                    ? "Recent workload mix is not comparable"
                    : "Not enough comparable weeks")
            )
        }
        let reference = Array(comparable.suffix(4))
        let secondsPerPoint = reference.map {
            $0.activeTimeSeconds / $0.usage.accountMovementPoints
        } + [activeTimeThisWeek / currentUsage.accountMovementPoints]
        guard secondsPerPoint.allSatisfy({
            $0.isFinite && $0 >= 0
        }),
        let minimum = secondsPerPoint.min(),
        let maximum = secondsPerPoint.max() else {
            return unavailable("Estimated active time is unavailable")
        }
        let lowerSeconds = minimum * usageRemainingPercent
        let upperSeconds = maximum * usageRemainingPercent
        guard lowerSeconds.isFinite, upperSeconds.isFinite else {
            return unavailable("Estimated active time is unavailable")
        }
        let caveats = ([currentCaveat] + reference.map(\.reason))
            .compactMap { $0 }
            .reduce(into: [String]()) { result, reason in
                if !result.contains(reason) {
                    result.append(reason)
                }
            }
        let confidence: ConfidenceLevel = caveats.isEmpty ? .high : .medium
        return ActiveTimeAvailabilitySnapshot(
            activeTimeThisWeek: activeTimeThisWeek,
            activeTimeCoverage: activeTimeCoverage,
            activeTimeReason: activeTimeReason,
            observedInterval: currentUsage.interval,
            estimate: ActiveTimeAvailableEstimate(
                lowerSeconds: lowerSeconds,
                upperSeconds: upperSeconds,
                coverage: caveats.isEmpty ? .high : .partial,
                confidence: confidence,
                referenceIntervalIDs: reference.map(\.usage.id),
                caveat: caveats.isEmpty
                    ? nil
                    : caveats.joined(separator: " · ")
            ),
            reason: nil
        )
    }
}
