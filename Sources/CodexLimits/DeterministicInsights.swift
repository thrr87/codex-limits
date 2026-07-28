import Foundation

enum DeterministicInsightKind: String, Codable, Equatable, Sendable {
    case pace = "Pace"
    case usageDeviation = "Usage Deviation"
}

enum InsightDisposition: String, Codable, Equatable, Sendable {
    case active
    case expected
    case dismissed
}

struct DeterministicInsight: Equatable, Identifiable, Sendable {
    let id: String
    let kind: DeterministicInsightKind
    let title: String
    let message: String
    let measurement: String
    let source: String
    let evidenceSources: [String]
    let freshness: UsageFreshness
    let observedAt: Date?
    let coverage: CoverageLevel
    let confidence: ConfidenceLevel
    let interval: DateInterval?
    let caveat: String?
    let scopeNote: String?
    var disposition: InsightDisposition

    var freshnessText: String {
        let state = switch freshness {
        case .fresh:
            "Fresh"
        case .stale:
            "Stale"
        case .unavailable:
            "Unavailable"
        }
        guard let observedAt else { return state }
        return "\(state) · Updated \(observedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var periodText: String? {
        interval.map {
            "\($0.start.formatted(date: .abbreviated, time: .omitted))–\($0.end.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    var accessibilitySummary: String {
        var parts = [
            kind.rawValue,
            title,
            message,
            measurement,
            source,
            evidenceSources.joined(separator: ", "),
            freshnessText,
            "\(coverage.displayName) coverage",
            "\(confidence.displayName) confidence"
        ]
        if let periodText {
            parts.append(periodText)
        }
        if let caveat {
            parts.append(caveat)
        }
        if let scopeNote {
            parts.append(scopeNote)
        }
        if disposition == .expected {
            parts.append("Marked expected")
        }
        return parts.joined(separator: ". ")
    }

}

struct DeterministicInsightCheck: Equatable, Identifiable, Sendable {
    let kind: DeterministicInsightKind
    let reason: String

    var id: DeterministicInsightKind { kind }
}

struct DeterministicInsightsSnapshot: Equatable, Sendable {
    let insights: [DeterministicInsight]
    let checks: [DeterministicInsightCheck]

    var activeInsights: [DeterministicInsight] {
        insights.filter { $0.disposition == .active }
    }

    var expectedInsights: [DeterministicInsight] {
        insights.filter { $0.disposition == .expected }
    }
}

struct DeterministicInsightInput: Equatable, Sendable {
    let sourceState: UsageSourceState
    let freshness: UsageFreshness
    let fetchedAt: Date?
    let accountPartitionID: String?
    let guidance: UsageGuidance?
    let guidanceEvidence: UsageEvidence
    let observedInterval: UsageObservedInterval?
    let usagePerToken: UsagePerTokenSnapshot
    let selectedRange: DateInterval?
    let filters: WorkspaceFilters

    init(
        reader: UsageReaderSnapshot,
        exploration: AnalyticsExplorationState
    ) {
        sourceState = reader.sourceState
        freshness = reader.freshness
        fetchedAt = reader.fetchedAt
        accountPartitionID = reader.accountPartitionID
        guidance = reader.guidance
        guidanceEvidence = reader.evidence
        observedInterval = reader.interval
        let currentPartition = reader.usagePerToken.current?
            .accountPartitionID
        let pinnedID =
            exploration.pinnedUsageBaselineAccountPartitionID
                == currentPartition
            ? exploration.pinnedUsageBaselineID
            : nil
        let selectedUsage = reader.usagePerToken.selectingBaseline(
            pinnedID
        )
        usagePerToken = selectedUsage
        selectedRange = Self.effectiveRange(
            usagePerToken: selectedUsage,
            observedInterval: reader.interval,
            fetchedAt: reader.fetchedAt,
            exploration: exploration
        )
        filters = exploration.filters
    }

    init(
        sourceState: UsageSourceState,
        freshness: UsageFreshness,
        fetchedAt: Date?,
        accountPartitionID: String?,
        guidance: UsageGuidance?,
        guidanceEvidence: UsageEvidence,
        observedInterval: UsageObservedInterval?,
        usagePerToken: UsagePerTokenSnapshot,
        selectedRange: DateInterval?,
        filters: WorkspaceFilters
    ) {
        self.sourceState = sourceState
        self.freshness = freshness
        self.fetchedAt = fetchedAt
        self.accountPartitionID = accountPartitionID
        self.guidance = guidance
        self.guidanceEvidence = guidanceEvidence
        self.observedInterval = observedInterval
        self.usagePerToken = usagePerToken
        self.selectedRange = selectedRange
        self.filters = filters
    }

    static func effectiveRange(
        usagePerToken: UsagePerTokenSnapshot,
        observedInterval: UsageObservedInterval?,
        fetchedAt: Date?,
        exploration: AnalyticsExplorationState
    ) -> DateInterval? {
        let evidence = usagePerToken.history
            + [usagePerToken.current].compactMap { $0 }
        let evidenceStart = evidence.map(\.interval.start).min()
        let evidenceEnd = evidence.map(\.interval.end).max()
        let observedRange = observedInterval.map {
            DateInterval(start: $0.startsAt, end: $0.resetsAt)
        }
        let start = evidenceStart ?? observedRange?.start
        let end = evidenceEnd ?? observedRange?.end
        guard let start, let end, end > start else {
            return exploration.timeRange == .selected
                ? exploration.visibleRange
                : nil
        }
        let bounds = DateInterval(start: start, end: end)
        if exploration.timeRange == .currentWindow {
            return usagePerToken.current?.interval ?? observedRange
        }
        if exploration.timeRange == .selected {
            guard let selected = exploration.visibleRange else {
                return nil
            }
            return ChartRange.clamped(selected, to: bounds)
        }
        return exploration.timeRange.interval(
            within: bounds,
            endingAt: fetchedAt ?? evidenceEnd ?? end
        )
    }
}

enum DeterministicInsightEngine {
    static let policyVersion = 1
    static let deviationThreshold = 0.20

    static func evaluate(
        reader: UsageReaderSnapshot,
        exploration: AnalyticsExplorationState,
        dispositions: [String: InsightDisposition]
    ) -> DeterministicInsightsSnapshot {
        evaluate(
            DeterministicInsightInput(
                reader: reader,
                exploration: exploration
            ),
            dispositions: dispositions
        )
    }

    static func evaluate(
        _ input: DeterministicInsightInput,
        dispositions: [String: InsightDisposition]
    ) -> DeterministicInsightsSnapshot {
        var proposed: [DeterministicInsight] = []
        var checks: [DeterministicInsightCheck] = []

        switch paceInsight(input) {
        case let .insight(insight):
            proposed.append(insight)
        case let .withheld(reason):
            checks.append(
                DeterministicInsightCheck(kind: .pace, reason: reason)
            )
        }

        switch usageDeviation(input) {
        case let .insight(insight):
            proposed.append(insight)
        case let .withheld(reason):
            checks.append(
                DeterministicInsightCheck(
                    kind: .usageDeviation,
                    reason: reason
                )
            )
        }

        let visible: [DeterministicInsight] = proposed.compactMap { insight in
            let disposition = dispositions[insight.id] ?? .active
            guard disposition != .dismissed else { return nil }
            var visibleInsight = insight
            visibleInsight.disposition = disposition
            return visibleInsight
        }
        return DeterministicInsightsSnapshot(
            insights: visible,
            checks: checks
        )
    }

    private static func paceInsight(
        _ input: DeterministicInsightInput
    ) -> Evaluation {
        guard let guidance = input.guidance else {
            return .withheld(
                input.guidanceEvidence.reason
                    ?? "More Account history is needed"
            )
        }
        if let reason = sourceWithholdingReason(input) {
            return .withheld(reason)
        }
        if let reason = rangeWithholdingReason(input) {
            return .withheld(reason)
        }
        guard shows(
                coverage: input.guidanceEvidence.coverage,
                confidence: input.guidanceEvidence.confidence
              ) else {
            return .withheld(
                input.guidanceEvidence.reason
                    ?? evidenceReason(
                        coverage: input.guidanceEvidence.coverage,
                        confidence: input.guidanceEvidence.confidence
                    )
            )
        }
        let interval = input.observedInterval.map {
            DateInterval(start: $0.startsAt, end: $0.resetsAt)
        }
        let intervalID = input.observedInterval.map {
            "\($0.limitID):\(Int($0.resetsAt.timeIntervalSince1970))"
        } ?? "unbounded"
        let partitionID = input.accountPartitionID ?? "unknown-account"
        let measurement = [
            guidance.suggestedPace,
            "Runway \(guidance.runway.text)"
        ].joined(separator: " · ")
        return .insight(
            DeterministicInsight(
                id: "pace:\(policyVersion):\(partitionID):\(intervalID):\(guidance.status.rawValue)",
                kind: .pace,
                title: guidance.title,
                message: guidance.message,
                measurement: measurement,
                source: guidance.source.rawValue,
                evidenceSources: ["Account Usage remaining"],
                freshness: input.freshness,
                observedAt: input.fetchedAt,
                coverage: input.guidanceEvidence.coverage,
                confidence: input.guidanceEvidence.confidence,
                interval: interval,
                caveat: guidance.caveat,
                scopeNote: scopeNote(for: input.filters),
                disposition: .active
            )
        )
    }

    private static func usageDeviation(
        _ input: DeterministicInsightInput
    ) -> Evaluation {
        if let reason = sourceWithholdingReason(input) {
            return .withheld(reason)
        }
        guard let current = input.usagePerToken.current else {
            return .withheld(
                input.usagePerToken.reason
                    ?? "Current weekly evidence is unavailable"
            )
        }
        guard let comparison = input.usagePerToken.comparison else {
            return .withheld(
                input.usagePerToken.reason
                    ?? "Not enough comparable weeks"
            )
        }
        guard comparison.baseline.comparability != .notComparable else {
            return .withheld("The reference period is not comparable")
        }
        guard shows(
                coverage: current.coverage,
                confidence: comparison.confidence
              ) else {
            return .withheld(
                input.usagePerToken.reason
                    ?? evidenceReason(
                        coverage: current.coverage,
                        confidence: comparison.confidence
                    )
            )
        }
        guard comparison.multiplier.isFinite,
              comparison.multiplier > 0 else {
            return .withheld("The measured change is unavailable")
        }
        if let reason = weeklyRangeWithholdingReason(
            input.selectedRange,
            observation: current.interval
        ) {
            return .withheld(reason)
        }

        let direction: Direction
        if comparison.multiplier > 1 + deviationThreshold {
            direction = .faster
        } else if comparison.multiplier < 1 - deviationThreshold {
            direction = .slower
        } else {
            return .withheld(
                "Usage stayed within 20% of your baseline"
            )
        }
        let confidence: ConfidenceLevel =
            current.coverage == .partial
                ? .medium
                : comparison.confidence
        let title: String
        switch direction {
        case .faster:
            title = "Usage increased faster than your baseline"
        case .slower:
            title = "Usage per token was lower than your baseline"
        }
        let multiplier = comparison.multiplier.formatted(
            .number
                .precision(.fractionLength(2))
                .locale(Locale(identifier: "en_US"))
        )
        let message = comparison.baseline.isPinned
            ? "Compared with your pinned reference period."
            : "Compared with the median of four prior comparable weeks."
        let insight = DeterministicInsight(
            id: [
                "usage-deviation",
                "\(policyVersion)",
                current.accountPartitionID,
                current.id,
                comparison.baseline.id,
                direction.rawValue
            ].joined(separator: ":"),
            kind: .usageDeviation,
            title: title,
            message: message,
            measurement:
                "Usage per token was \(multiplier)× your baseline",
            source: UsageValueSource.derivedEstimate.rawValue,
            evidenceSources: [
                "Account Usage remaining",
                "Account Token Activity",
                "Codex local records"
            ],
            freshness: input.freshness,
            observedAt: input.fetchedAt,
            coverage: current.coverage,
            confidence: confidence,
            interval: current.interval,
            caveat: comparison.caveat ?? current.coverageReason,
            scopeNote: scopeNote(for: input.filters),
            disposition: .active
        )
        return .insight(insight)
    }

    private static func sourceWithholdingReason(
        _ input: DeterministicInsightInput
    ) -> String? {
        guard input.sourceState == .available else {
            return "Account data is unavailable"
        }
        switch input.freshness {
        case .fresh:
            return nil
        case .stale:
            return "Account data is stale"
        case .unavailable:
            return "Account data is unavailable"
        }
    }

    private static func rangeWithholdingReason(
        _ input: DeterministicInsightInput
    ) -> String? {
        guard let selectedRange = input.selectedRange,
              let fetchedAt = input.fetchedAt else {
            return nil
        }
        guard fetchedAt >= selectedRange.start,
              fetchedAt <= selectedRange.end else {
            return "The selected range does not include this observation"
        }
        return nil
    }

    private static func weeklyRangeWithholdingReason(
        _ selectedRange: DateInterval?,
        observation: DateInterval
    ) -> String? {
        guard let selectedRange else { return nil }
        guard selectedRange.start <= observation.start,
              selectedRange.end >= observation.end else {
            return "Usage Deviation needs the full observed weekly window"
        }
        return nil
    }

    private static func shows(
        coverage: CoverageLevel,
        confidence: ConfidenceLevel
    ) -> Bool {
        let enoughCoverage = switch coverage {
        case .complete, .high, .partial:
            true
        case .low, .unavailable, .notApplicable:
            false
        }
        return enoughCoverage
            && (confidence == .high || confidence == .medium)
    }

    private static func evidenceReason(
        coverage: CoverageLevel,
        confidence: ConfidenceLevel
    ) -> String {
        if coverage == .low {
            return "Local Coverage is Low"
        }
        if coverage == .unavailable || coverage == .notApplicable {
            return "Local Coverage is Unavailable"
        }
        if confidence == .low {
            return "Confidence is Low"
        }
        return "Confidence is Unavailable"
    }

    private static func scopeNote(
        for filters: WorkspaceFilters
    ) -> String? {
        guard !filters.isEmpty else { return nil }
        return "Account data does not support Project, Task, Model, or Reasoning filters"
    }

    private enum Evaluation {
        case insight(DeterministicInsight)
        case withheld(String)
    }

    private enum Direction: String {
        case faster
        case slower
    }
}
