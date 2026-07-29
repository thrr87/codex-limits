import Foundation

enum UsageSourceState: Equatable, Sendable {
    case available
    case failed(String)
}

enum UsageFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unavailable
}

enum CoverageLevel: String, Codable, Equatable, Sendable {
    case complete
    case high
    case partial
    case low
    case unavailable
    case notApplicable

    var displayName: String {
        switch self {
        case .complete: "Complete"
        case .high: "High"
        case .partial: "Partial"
        case .low: "Low"
        case .unavailable: "Unavailable"
        case .notApplicable: "Not applicable"
        }
    }
}

enum ConfidenceLevel: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
    case unavailable

    var displayName: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .unavailable: "Unavailable"
        }
    }
}

enum UsageValueSource: String, Equatable, Sendable {
    case account = "Account"
    case derivedEstimate = "Derived estimate"
}

struct UsageObservedInterval: Equatable, Sendable {
    let limitID: String
    let durationMinutes: Int
    let startsAt: Date
    let resetsAt: Date

    var text: String {
        let style = Date.FormatStyle()
            .month(.abbreviated)
            .day()
            .locale(Locale(identifier: "en_US"))
        let start = startsAt.formatted(style)
        let end = resetsAt.formatted(style)
        return "Weekly window · \(start)–\(end)"
    }
}

struct UsageEvidence: Equatable, Sendable {
    let coverage: CoverageLevel
    let confidence: ConfidenceLevel
    let reason: String?
    let policyVersion: Int
}

struct UsageEstimateRange: Equatable, Sendable {
    let lowerRemainingAtReset: Double
    let upperRemainingAtReset: Double

    var text: String {
        "\(Int(lowerRemainingAtReset.rounded()))–\(Int(upperRemainingAtReset.rounded()))% left at reset"
    }
}

enum UsageRunway: Equatable, Sendable {
    case exhausts(Date, beforeReset: TimeInterval)
    case throughReset

    var text: String {
        switch self {
        case let .exhausts(date, _):
            date.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened)
                    .locale(Locale(identifier: "en_US"))
            )
        case .throughReset:
            "Through reset"
        }
    }

    var gapText: String? {
        guard case let .exhausts(_, beforeReset) = self else { return nil }
        let minutes = max(Int((beforeReset / 60).rounded()), 0)
        if minutes < 60 {
            return "\(minutes) min before reset"
        }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 48 {
            return "\(hours) \(hours == 1 ? "hr" : "hrs") before reset"
        }
        let days = Int((Double(hours) / 24).rounded())
        return "\(days) \(days == 1 ? "day" : "days") before reset"
    }
}

struct UsageGuidance: Equatable, Sendable {
    let source: UsageValueSource
    let status: PaceStatus
    let title: String
    let message: String
    let suggestedPace: String
    let runway: UsageRunway
    let remainingAtResetRange: UsageEstimateRange?
    let caveat: String?
    let forecast: Forecast
}

enum ResetDetailCoverage: String, Equatable, Sendable {
    case complete
    case partial
    case unavailable

    var displayName: String {
        switch self {
        case .complete: "Complete"
        case .partial: "Partial"
        case .unavailable: "Unavailable"
        }
    }
}

struct BankedResetSummary: Equatable, Sendable {
    let availableCount: Int
    let detailCoverage: ResetDetailCoverage
    let knownExpiryCount: Int
    let nextKnownResetID: String?
    let nextKnownExpiry: Date?
    let observedAt: Date
    let freshness: UsageFreshness
    let sourceState: UsageSourceState

    func inlineText(at now: Date) -> String {
        let countText = "\(availableCount) \(availableCount == 1 ? "banked reset" : "banked resets")"
        guard availableCount > 0 else { return countText }
        guard let expiry = currentNextKnownExpiry(at: now) else {
            if nextKnownExpiry != nil {
                return "\(countText) · Expiry dates need refresh"
            }
            return "\(countText) · Expiry dates unavailable"
        }
        let time = Self.timeUntil(expiry, from: now)
        switch detailCoverage {
        case .complete:
            return "\(countText) · Next expires in \(time)"
        case .partial:
            let known = "\(knownExpiryCount) \(knownExpiryCount == 1 ? "expiry" : "expiries") known"
            return "\(countText) · \(known) · Next known in \(time)"
        case .unavailable:
            return "\(countText) · Expiry dates unavailable"
        }
    }

    func headerValue(at now: Date) -> String {
        inlineText(at: now)
            .replacingOccurrences(
                of: " \(availableCount == 1 ? "banked reset" : "banked resets")",
                with: ""
            )
    }

    func inspectionText(at now: Date) -> String {
        let source: String
        switch sourceState {
        case .available:
            source = "Account"
        case .failed:
            source = "Account source unavailable"
        }
        var parts = [
            source,
            "\(detailCoverage.displayName) reset detail"
        ]
        if let expiry = currentNextKnownExpiry(at: now) {
            parts.insert(
                "Next known expiry \(expiry.formatted(date: .abbreviated, time: .shortened))",
                at: 0
            )
        } else if nextKnownExpiry != nil {
            parts.insert("Expiry dates need refresh", at: 0)
        } else if availableCount > 0 {
            parts.insert("Expiry dates unavailable", at: 0)
        }
        let age = max(now.timeIntervalSince(observedAt), 0)
        if freshness == .stale
            || sourceState != .available
            || age > UsageHistoryPolicy.tightBoundary {
            parts.append("Stale")
        } else if age < 60 {
            parts.append("Updated just now")
        } else {
            parts.append("Updated \(Int(age / 60)) min ago")
        }
        return parts.joined(separator: " · ")
    }

    func currentNextKnownExpiry(at now: Date) -> Date? {
        nextKnownExpiry.flatMap { $0 > now ? $0 : nil }
    }

    func timeUntilNextKnownExpiry(at now: Date) -> String? {
        currentNextKnownExpiry(at: now).map {
            Self.timeUntil($0, from: now)
        }
    }

    func sourceStatusText(at now: Date) -> String {
        let age = max(now.timeIntervalSince(observedAt), 0)
        if sourceState != .available
            || freshness == .stale
            || age > UsageHistoryPolicy.tightBoundary {
            return "Stale · Updated \(Self.ageText(age))"
        }
        return "Updated \(Self.ageText(age))"
    }

    private static func ageText(_ age: TimeInterval) -> String {
        if age < 60 { return "just now" }
        if age < 3_600 { return "\(Int(age / 60)) min ago" }
        let hours = Int(age / 3_600)
        return "\(hours) \(hours == 1 ? "hr" : "hrs") ago"
    }

    private static func timeUntil(_ expiry: Date, from now: Date) -> String {
        let seconds = max(expiry.timeIntervalSince(now), 0)
        let minutes = max(Int(ceil(seconds / 60)), 1)
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = Int(ceil(Double(minutes) / 60))
        if hours < 48 {
            return "\(hours) \(hours == 1 ? "hr" : "hrs")"
        }
        let days = Int(ceil(Double(hours) / 24))
        return "\(days) \(days == 1 ? "day" : "days")"
    }
}

struct UsageChartPoint: Equatable, Identifiable, Sendable {
    let date: Date
    let remaining: Double

    var id: Date { date }
}

struct UsageAllowanceWindowSeries: Equatable, Identifiable, Sendable {
    let resetsAt: Date
    let observedSegments: [[UsageChartPoint]]

    var id: Date { resetsAt }
}

struct UsageChartReferenceSeries: Equatable, Sendable {
    let source: UsageForecastReferenceSource
    let points: [UsageChartPoint]
}

struct UsageChartSnapshot: Equatable, Sendable {
    let observedSource: UsageValueSource
    let target: [UsageChartPoint]
    let currentProjection: [UsageChartPoint]
    let reference: UsageChartReferenceSeries?
    let currentAllowanceReset: Date?
    let allowanceWindows: [UsageAllowanceWindowSeries]
    let currentRunsFaster: Bool
    let accessibilityValue: String

    var observedSegments: [[UsageChartPoint]] {
        allowanceWindows.first {
            $0.resetsAt == currentAllowanceReset
        }?.observedSegments ?? []
    }

    var observed: [UsageChartPoint] {
        observedSegments.flatMap { $0 }
    }

    var historicalProjection: [UsageChartPoint] {
        reference?.source == .accountHistory ? reference?.points ?? [] : []
    }

    var estimatedBackfill: [UsageChartPoint] {
        reference?.source == .tokenEstimate ? reference?.points ?? [] : []
    }

    var historicalReferenceSource: UsageForecastReferenceSource? {
        reference?.source
    }

    init(
        observedSource: UsageValueSource,
        target: [UsageChartPoint],
        currentProjection: [UsageChartPoint],
        reference: UsageChartReferenceSeries? = nil,
        currentAllowanceReset: Date?,
        allowanceWindows: [UsageAllowanceWindowSeries] = [],
        currentRunsFaster: Bool,
        accessibilityValue: String
    ) {
        self.observedSource = observedSource
        self.target = target
        self.currentProjection = currentProjection
        self.reference = reference
        self.currentAllowanceReset = currentAllowanceReset
        self.allowanceWindows = allowanceWindows
        self.currentRunsFaster = currentRunsFaster
        self.accessibilityValue = accessibilityValue
    }
}

enum AccountTokenActivityState: String, Equatable, Sendable {
    case exact
    case partial
    case unavailable
}

enum AccountTokenActivityMethod: String, Equatable, Sendable {
    case lifetimeDelta
    case dailyBuckets
}

struct AccountTokenActivitySnapshot: Equatable, Sendable {
    let state: AccountTokenActivityState
    let tokens: Int64?
    let method: AccountTokenActivityMethod?
    let interval: DateInterval?
    let reason: String?

    static func unavailable(
        _ reason: String,
        interval: DateInterval? = nil
    ) -> AccountTokenActivitySnapshot {
        AccountTokenActivitySnapshot(
            state: .unavailable,
            tokens: nil,
            method: nil,
            interval: interval,
            reason: reason
        )
    }
}

struct UsageIntelligenceInput: Equatable, Sendable {
    let account: UsageSnapshot?
    let samples: [UsageSample]
    let safetyBuffer: Double
    let sourceState: UsageSourceState
    let now: Date
    let previousStatus: PaceStatus?
    let accountPartitionID: String?
    let accountEpochStartedAt: Date?
    let localActivityFacts: [LocalActivityFact]
    let localActivityHistoryFacts: [LocalActivityFact]
    let localActivityObservation: LocalActivityObservation
    let localTaskProjections: [ThreadProjection]
    let compatibleTokenSources: Set<LocalTokenDefinitionSource>
    let analyticsExploration: AnalyticsExplorationState
    let insightDispositions: [String: InsightDisposition]

    init(
        account: UsageSnapshot?,
        samples: [UsageSample],
        safetyBuffer: Double,
        sourceState: UsageSourceState,
        now: Date,
        previousStatus: PaceStatus?,
        accountPartitionID: String? = nil,
        accountEpochStartedAt: Date? = nil,
        localActivityFacts: [LocalActivityFact] = [],
        localActivityHistoryFacts: [LocalActivityFact]? = nil,
        localActivityObservation: LocalActivityObservation = .unavailable(
            "Codex local records are unavailable"
        ),
        localTaskProjections: [ThreadProjection] = [],
        compatibleTokenSources: Set<LocalTokenDefinitionSource> = [],
        analyticsExploration: AnalyticsExplorationState = .initial,
        insightDispositions: [String: InsightDisposition] = [:]
    ) {
        self.account = account
        self.samples = samples
        self.safetyBuffer = safetyBuffer
        self.sourceState = sourceState
        self.now = now
        self.previousStatus = previousStatus
        self.accountPartitionID = accountPartitionID
        self.accountEpochStartedAt = accountEpochStartedAt
        self.localActivityFacts = localActivityFacts
        self.localActivityHistoryFacts =
            localActivityHistoryFacts ?? localActivityFacts
        self.localActivityObservation = localActivityObservation
        self.localTaskProjections = localTaskProjections
        self.compatibleTokenSources = compatibleTokenSources
        self.analyticsExploration = analyticsExploration
        self.insightDispositions = insightDispositions
    }
}

struct UsageReaderSnapshot: Equatable, Sendable {
    let account: UsageSnapshot?
    let accountSource: UsageValueSource
    let interval: UsageObservedInterval?
    let menuBarText: String
    let sourceState: UsageSourceState
    let freshness: UsageFreshness
    let evidence: UsageEvidence
    let guidance: UsageGuidance?
    let chart: UsageChartSnapshot
    let bankedResets: BankedResetSummary?
    let accountTokenActivity: AccountTokenActivitySnapshot
    let localTokenActivity: LocalTokenActivitySnapshot
    let usagePerToken: UsagePerTokenSnapshot
    let usageReceipts: UsageReceiptSnapshot
    let activityTimeline: ActivityTimelineSnapshot
    let activeTimeAvailability: ActiveTimeAvailabilitySnapshot
    let localTaskProjections: [ThreadProjection]
    let accountPartitionID: String?
    var insights: DeterministicInsightsSnapshot

    var fetchedAt: Date? { account?.fetchedAt }

    var weeklyUsageRemaining: LimitReading? { account?.mainLimit }

    var accountFacts: AccountFacts? { account?.accountFacts }

    var otherLimits: [LimitReading] { account?.otherLimits ?? [] }

    var guidanceTitle: String {
        guidance?.title ?? "Not enough data"
    }

    var guidanceMessage: String {
        guidance?.message ?? evidence.reason ?? "More account history is needed."
    }

    var suggestedPaceText: String {
        guidance?.suggestedPace ?? "Not enough data"
    }

    var evidenceText: String {
        "\(UsageValueSource.derivedEstimate.rawValue) · \(evidence.coverage.displayName) coverage · \(evidence.confidence.displayName) confidence"
    }

    var sourceMessage: String? {
        guard case let .failed(message) = sourceState else { return nil }
        return message
    }

    func updatedText(at now: Date) -> String {
        guard let fetchedAt = account?.fetchedAt else { return "Not updated" }
        let seconds = max(now.timeIntervalSince(fetchedAt), 0)
        if seconds < 60 { return "Updated just now" }
        if seconds < 3_600 { return "Updated \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3_600)
            return "Updated \(hours) \(hours == 1 ? "hr" : "hrs") ago"
        }
        let days = Int(seconds / 86_400)
        return "Updated \(days) \(days == 1 ? "day" : "days") ago"
    }

}

private enum CurrentUsagePolicy {
    static let version = 1
    static let tightBoundary = UsageHistoryPolicy.tightBoundary
    static let looseBoundary: TimeInterval = 60 * 60
    static let highGap = UsageHistoryPolicy.maximumComparableGap
    static let partialGap: TimeInterval = 6 * 60 * 60
    static let minimumCorrectionInterval: TimeInterval = 6 * 60 * 60
    static let highShare = 0.8
    static let partialShare = 0.5
}

enum UsageIntelligenceEngine {
    static func evaluate(_ input: UsageIntelligenceInput) -> UsageReaderSnapshot {
        let currentSamples = input.account.flatMap { account in
            account.mainLimit.map { weeklyLimit in
            input.samples
                .filter { sample in
                    sample.resetsAt == weeklyLimit.window.resetsAt
                        && sample.observedAt >= weeklyLimit.window.startsAt
                        && sample.observedAt <= account.fetchedAt
                        && sample.observedAt <= input.now
                        && (
                            input.accountEpochStartedAt.map {
                                sample.observedAt >= $0
                            } ?? true
                        )
                }
                .sorted { $0.observedAt < $1.observedAt }
            }
        } ?? []
        let workloadMixChanged = input.account?.mainLimit.map {
            LocalWorkloadMixAnalyzer.detectsChange(
                facts: input.localActivityFacts,
                observation: input.localActivityObservation,
                window: $0.window
            )
        } ?? false
        let evidence = evidence(
            account: input.account,
            samples: currentSamples,
            sourceState: input.sourceState,
            now: input.now,
            workloadMixChanged: workloadMixChanged
        )
        let guidance: UsageGuidance? = input.account.flatMap { account in
            guard let weeklyLimit = account.mainLimit else { return nil }
            guard evidence.confidence == .high || evidence.confidence == .medium else {
                return nil
            }
            let forecast = ForecastEngine.evaluate(
                window: weeklyLimit.window,
                samples: input.samples,
                tokenHistory: account.tokenHistory,
                safetyBuffer: input.safetyBuffer,
                now: input.now,
                previousStatus: input.previousStatus
            )
            return UsageGuidance(
                source: .derivedEstimate,
                status: forecast.status,
                title: title(for: forecast.status),
                message: message(
                    window: weeklyLimit.window,
                    forecast: forecast,
                    safetyBuffer: input.safetyBuffer,
                    now: input.now
                ),
                suggestedPace: suggestedPace(
                    forecast: forecast,
                    reset: weeklyLimit.window.resetsAt,
                    now: input.now
                ),
                runway: runway(
                    window: weeklyLimit.window,
                    forecast: forecast,
                    now: input.now
                ),
                remainingAtResetRange: evidence.confidence == .medium
                    ? estimateRange(forecast)
                    : nil,
                caveat: evidence.confidence == .medium ? evidence.reason : nil,
                forecast: forecast
            )
        }
        let chartSamples = input.samples.filter { sample in
            guard let currentReset = input.account?.mainLimit?.window.resetsAt,
                  sample.resetsAt == currentReset,
                  let epoch = input.accountEpochStartedAt else {
                return true
            }
            return sample.observedAt >= epoch
        }
        let chart = chart(
            account: input.account,
            samples: chartSamples,
            guidance: guidance,
            safetyBuffer: input.safetyBuffer
        )
        let currentFreshness = freshness(
            account: input.account,
            sourceState: input.sourceState,
            now: input.now
        )
        let accountTokenActivity = accountTokenActivity(
            account: input.account,
            samples: currentSamples
        )
        let localTokenActivity: LocalTokenActivitySnapshot
        if let interval = tokenActivityInterval(
            account: input.account,
            accountActivity: accountTokenActivity,
            accountEpochStartedAt: input.accountEpochStartedAt
        ) {
            localTokenActivity = LocalTokenActivityAggregator.evaluate(
                facts: input.localActivityFacts,
                interval: interval,
                observation: input.localActivityObservation
            )
        } else {
            localTokenActivity = .unavailable(
                "Weekly token interval is unavailable",
                interval: DateInterval(start: input.now, end: input.now)
            )
        }
        let usageReceipts = UsageReceiptAggregator.evaluate(
            facts: input.localActivityFacts,
            projections: input.localTaskProjections,
            interval: localTokenActivity.interval,
            observation: input.localActivityObservation
        )
        let activityTimeline = ActivityTimelineAggregator.evaluate(
            facts: input.localActivityFacts,
            projections: input.localTaskProjections,
            interval: localTokenActivity.interval,
            observation: input.localActivityObservation
        )
        let sourceUsagePerToken: UsagePerTokenSnapshot
        if let partitionID = input.accountPartitionID,
           let weekly = input.account?.mainLimit {
            let evidence = WeeklyUsageEvidenceBuilder.build(
                samples: input.samples,
                localFacts: input.localActivityHistoryFacts,
                localObservation: input.localActivityObservation,
                accountPartitionID: partitionID,
                limitID: weekly.limitId,
                currentReset: weekly.window.resetsAt,
                compatibleTokenSources: input.compatibleTokenSources
            )
            sourceUsagePerToken = UsagePerTokenEngine.evaluate(
                current: evidence.current,
                history: evidence.history,
                pinnedBaselineID: nil
            )
        } else {
            sourceUsagePerToken = UsagePerTokenEngine.evaluate(
                current: nil,
                history: [],
                pinnedBaselineID: nil
            )
        }
        let currentPartition = sourceUsagePerToken.current?
            .accountPartitionID
        let pinnedBaselineID =
            input.analyticsExploration
                .pinnedUsageBaselineAccountPartitionID
                == currentPartition
            ? input.analyticsExploration.pinnedUsageBaselineID
            : nil
        let usagePerToken = sourceUsagePerToken.selectingBaseline(
            pinnedBaselineID
        )
        let activeTimeSlice = activityTimeline.slice(
            in: activityTimeline.interval,
            filters: .all
        )
        let activeTimeHistory = ActiveTimeWeekEvidenceBuilder.build(
            currentUsage: usagePerToken.current,
            usage: usagePerToken.history,
            facts: input.localActivityHistoryFacts,
            projections: input.localTaskProjections,
            observation: input.localActivityObservation
        )
        let activeTimeAvailability = ActiveTimeAvailabilityEngine.evaluate(
            currentUsage: usagePerToken.current,
            activeTimeThisWeek: activeTimeSlice.activeTime,
            activeTimeCoverage: activeTimeSlice.coverage,
            activeTimeReason: activeTimeSlice.reason,
            history: activeTimeHistory.evidence,
            historyUnavailableReason: activeTimeHistory.unavailableReason,
            usageRemainingPercent:
                input.account?.mainLimit?.window.remainingPercent ?? .nan
        )
        let observedInterval = input.account.flatMap { account in
            account.mainLimit.map {
                UsageObservedInterval(
                    limitID: $0.limitId,
                    durationMinutes: $0.window.durationMinutes,
                    startsAt: $0.window.startsAt,
                    resetsAt: $0.window.resetsAt
                )
            }
        }
        let insightInput = DeterministicInsightInput(
            sourceState: input.sourceState,
            freshness: currentFreshness,
            fetchedAt: input.account?.fetchedAt,
            accountPartitionID: input.accountPartitionID,
            guidance: guidance,
            guidanceEvidence: evidence,
            observedInterval: observedInterval,
            usagePerToken: usagePerToken,
            selectedRange: DeterministicInsightInput.effectiveRange(
                usagePerToken: usagePerToken,
                observedInterval: observedInterval,
                fetchedAt: input.account?.fetchedAt,
                exploration: input.analyticsExploration
            ),
            filters: input.analyticsExploration.filters
        )
        let insights = DeterministicInsightEngine.evaluate(
            insightInput,
            dispositions: input.insightDispositions
        )
        return UsageReaderSnapshot(
            account: input.account,
            accountSource: .account,
            interval: observedInterval,
            menuBarText: input.account?.mainLimit.map {
                "\(Int($0.window.remainingPercent.rounded()))%"
            } ?? "—",
            sourceState: input.sourceState,
            freshness: currentFreshness,
            evidence: evidence,
            guidance: guidance,
            chart: chart,
            bankedResets: bankedResetSummary(
                account: input.account,
                freshness: currentFreshness,
                sourceState: input.sourceState
            ),
            accountTokenActivity: accountTokenActivity,
            localTokenActivity: localTokenActivity,
            usagePerToken: usagePerToken,
            usageReceipts: usageReceipts,
            activityTimeline: activityTimeline,
            activeTimeAvailability: activeTimeAvailability,
            localTaskProjections: input.localTaskProjections,
            accountPartitionID: input.accountPartitionID,
            insights: insights
        )
    }

    private static func bankedResetSummary(
        account: UsageSnapshot?,
        freshness: UsageFreshness,
        sourceState: UsageSourceState
    ) -> BankedResetSummary? {
        guard let account,
              account.bankedResetCountAvailable != false else {
            return nil
        }
        let available = (account.bankedResetDetails ?? [])
            .filter {
                $0.status.caseInsensitiveCompare("available") == .orderedSame
                    && $0.expiresAt > account.fetchedAt
            }
        let unique = Dictionary(
            available.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values
        let nextKnown = unique.min {
            if $0.expiresAt == $1.expiresAt {
                return $0.id < $1.id
            }
            return $0.expiresAt < $1.expiresAt
        }
        let knownExpiryCount = min(
            unique.count,
            account.emergencyResetCount
        )
        let coverage: ResetDetailCoverage
        if account.emergencyResetCount == 0 {
            coverage = .complete
        } else if account.bankedResetDetails == nil || knownExpiryCount == 0 {
            coverage = .unavailable
        } else if knownExpiryCount >= account.emergencyResetCount {
            coverage = .complete
        } else {
            coverage = .partial
        }
        return BankedResetSummary(
            availableCount: account.emergencyResetCount,
            detailCoverage: coverage,
            knownExpiryCount: knownExpiryCount,
            nextKnownResetID: account.emergencyResetCount > 0
                ? nextKnown?.id
                : nil,
            nextKnownExpiry: account.emergencyResetCount > 0
                ? nextKnown?.expiresAt
                : nil,
            observedAt: account.fetchedAt,
            freshness: freshness,
            sourceState: sourceState
        )
    }

    static func tokenActivityInterval(
        account: UsageSnapshot?,
        samples: [UsageSample],
        accountEpochStartedAt: Date? = nil
    ) -> DateInterval? {
        tokenActivityInterval(
            account: account,
            accountActivity: accountTokenActivity(
                account: account,
                samples: samples
            ),
            accountEpochStartedAt: accountEpochStartedAt
        )
    }

    private static func tokenActivityInterval(
        account: UsageSnapshot?,
        accountActivity: AccountTokenActivitySnapshot,
        accountEpochStartedAt: Date?
    ) -> DateInterval? {
        if let interval = accountActivity.interval {
            let start = max(
                interval.start,
                accountEpochStartedAt ?? interval.start
            )
            guard interval.end >= start else { return nil }
            return DateInterval(start: start, end: interval.end)
        }
        guard let account,
              let window = account.mainLimit?.window else {
            return nil
        }
        let start = max(
            window.startsAt,
            accountEpochStartedAt ?? window.startsAt
        )
        let end = min(account.fetchedAt, window.resetsAt)
        guard end >= start else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func accountTokenActivity(
        account: UsageSnapshot?,
        samples: [UsageSample]
    ) -> AccountTokenActivitySnapshot {
        guard let account, let weeklyLimit = account.mainLimit else {
            return .unavailable("Account token readings are unavailable")
        }
        let start = weeklyLimit.window.startsAt
        let boundary = samples
            .filter {
                $0.lifetimeTokens != nil
                    && abs($0.observedAt.timeIntervalSince(start))
                        <= CurrentUsagePolicy.tightBoundary
            }
            .min {
                abs($0.observedAt.timeIntervalSince(start))
                    < abs($1.observedAt.timeIntervalSince(start))
            }
        if let currentTokens = account.accountFacts?.lifetimeTokens,
           let boundary,
           let boundaryTokens = boundary.lifetimeTokens {
            let currentObservedAt = account.accountFacts?
                .lifetimeTokensObservedAt ?? account.fetchedAt
            guard currentObservedAt >= boundary.observedAt else {
                return .unavailable(
                    "No lifetime token reading after the weekly boundary"
                )
            }
            guard currentTokens >= 0, boundaryTokens >= 0 else {
                return .unavailable("Lifetime token reading is invalid")
            }
            guard currentTokens >= boundaryTokens else {
                return .unavailable(
                    "Lifetime token counter decreased",
                    interval: DateInterval(
                        start: boundary.observedAt,
                        end: currentObservedAt
                    )
                )
            }
            let delta = currentTokens.subtractingReportingOverflow(
                boundaryTokens
            )
            guard !delta.overflow else {
                return .unavailable("Lifetime token reading is invalid")
            }
            return AccountTokenActivitySnapshot(
                state: .exact,
                tokens: delta.partialValue,
                method: .lifetimeDelta,
                interval: DateInterval(
                    start: boundary.observedAt,
                    end: currentObservedAt
                ),
                reason: nil
            )
        }

        if let dailyActivity = dailyTokenActivity(
            account: account,
            window: weeklyLimit.window
        ) {
            return dailyActivity
        }

        return .unavailable(
            account.accountFacts?.lifetimeTokens == nil
                ? "Lifetime token readings are unavailable"
                : "No lifetime token reading at the weekly boundary"
        )
    }

    private static func dailyTokenActivity(
        account: UsageSnapshot,
        window: UsageWindow
    ) -> AccountTokenActivitySnapshot? {
        let intervalEnd = min(
            account.fetchedAt,
            window.resetsAt
        )
        let completeDays = account.tokenHistory
            .filter { day in
                let end = day.date.addingTimeInterval(24 * 60 * 60)
                return day.completeness == .complete
                    && day.tokens >= 0
                    && day.date >= window.startsAt
                    && end <= intervalEnd
            }
            .sorted { $0.date < $1.date }
        guard let first = completeDays.first,
              let last = completeDays.last else {
            return nil
        }
        var total: Int64 = 0
        for day in completeDays {
            let result = total.addingReportingOverflow(day.tokens)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        let lastDayEnd = last.date.addingTimeInterval(24 * 60 * 60)
        let isContiguous = zip(
            completeDays,
            completeDays.dropFirst()
        ).allSatisfy { previous, next in
            next.date == previous.date.addingTimeInterval(24 * 60 * 60)
        }
        let exactlyMatchesInterval = isContiguous
            && first.date == window.startsAt
            && lastDayEnd == intervalEnd
        return AccountTokenActivitySnapshot(
            state: exactlyMatchesInterval ? .exact : .partial,
            tokens: total,
            method: .dailyBuckets,
            interval: DateInterval(
                start: first.date,
                end: lastDayEnd
            ),
            reason: exactlyMatchesInterval
                ? nil
                : "Only complete daily token totals are available"
        )
    }

    private static func chart(
        account: UsageSnapshot?,
        samples: [UsageSample],
        guidance: UsageGuidance?,
        safetyBuffer: Double
    ) -> UsageChartSnapshot {
        guard let account, let weeklyLimit = account.mainLimit else {
            return UsageChartSnapshot(
                observedSource: .account,
                target: [],
                currentProjection: [],
                currentAllowanceReset: nil,
                allowanceWindows: [],
                currentRunsFaster: false,
                accessibilityValue: "Usage is not available."
            )
        }
        let window = weeklyLimit.window
        let target = [
            UsageChartPoint(date: window.startsAt, remaining: 100),
            UsageChartPoint(date: window.resetsAt, remaining: safetyBuffer)
        ]
        let allowanceWindows = allowanceWindowSeries(
            account: account,
            samples: samples
        )
        guard let forecast = guidance?.forecast else {
            return UsageChartSnapshot(
                observedSource: .account,
                target: target,
                currentProjection: [],
                currentAllowanceReset: window.resetsAt,
                allowanceWindows: allowanceWindows,
                currentRunsFaster: false,
                accessibilityValue: "Now has \(Int(window.remainingPercent.rounded())) percent remaining. A forecast is not available."
            )
        }
        let referenceProjection = projection(
            account: account,
            window: window,
            rate: forecast.historicalPercentPerDay,
            remainingAtReset: forecast.historicalRemainingAtReset
        )
        let reference = forecast.historicalReferenceSource.map {
            UsageChartReferenceSeries(
                source: $0,
                points: referenceProjection
            )
        }
        let referenceDescription = forecast.historicalReferenceSource.map {
            " and the \($0.rawValue.lowercased()) leaves \(Int(forecast.historicalRemainingAtReset.rounded())) percent"
        } ?? ""
        return UsageChartSnapshot(
            observedSource: .account,
            target: target,
            currentProjection: projection(
                account: account,
                window: window,
                rate: forecast.currentPercentPerDay,
                remainingAtReset: forecast.expectedRemainingAtReset
            ),
            reference: reference,
            currentAllowanceReset: window.resetsAt,
            allowanceWindows: allowanceWindows,
            currentRunsFaster: forecast.currentPercentPerDay
                > forecast.historicalPercentPerDay,
            accessibilityValue: "Now has \(Int(window.remainingPercent.rounded())) percent remaining. At reset, the current pace leaves \(Int(forecast.expectedRemainingAtReset.rounded())) percent\(referenceDescription)."
        )
    }

    private static func allowanceWindowSeries(
        account: UsageSnapshot,
        samples: [UsageSample]
    ) -> [UsageAllowanceWindowSeries] {
        guard let currentWindow = account.mainLimit?.window else { return [] }
        let current = UsageSample(
            observedAt: account.fetchedAt,
            remainingPercent: currentWindow.remainingPercent,
            resetsAt: currentWindow.resetsAt
        )
        return Dictionary(
            grouping: deduplicatedSamples(samples + [current]),
            by: \.resetsAt
        )
        .compactMap { reset, grouped -> UsageAllowanceWindowSeries? in
            let start = reset.addingTimeInterval(
                -Double(UsageHistoryPolicy.weeklyDurationMinutes) * 60
            )
            let end = reset == currentWindow.resetsAt
                ? min(reset, account.fetchedAt)
                : reset
            let windowSamples = grouped.filter {
                $0.observedAt >= start && $0.observedAt <= end
            }
            guard !windowSamples.isEmpty else { return nil }
            let segments = UsageHistoryPolicy.segments(windowSamples).map {
                $0.map {
                    UsageChartPoint(
                        date: $0.observedAt,
                        remaining: $0.remainingPercent
                    )
                }
            }
            return UsageAllowanceWindowSeries(
                resetsAt: reset,
                observedSegments: segments
            )
        }
        .sorted { $0.resetsAt < $1.resetsAt }
    }

    private static func projection(
        account: UsageSnapshot,
        window: UsageWindow,
        rate: Double,
        remainingAtReset: Double
    ) -> [UsageChartPoint] {
        let current = UsageChartPoint(
            date: account.fetchedAt,
            remaining: window.remainingPercent
        )
        guard rate > 0 else {
            return [
                current,
                UsageChartPoint(
                    date: window.resetsAt,
                    remaining: window.remainingPercent
                )
            ]
        }
        let exhaustion = account.fetchedAt.addingTimeInterval(
            window.remainingPercent / rate * 86_400
        )
        let endpoint = exhaustion < window.resetsAt
            ? UsageChartPoint(date: exhaustion, remaining: 0)
            : UsageChartPoint(
                date: window.resetsAt,
                remaining: remainingAtReset
            )
        return [current, endpoint]
    }

    private static func deduplicatedSamples(
        _ samples: [UsageSample]
    ) -> [UsageSample] {
        Dictionary(grouping: samples) {
            UsageSamplePointIdentity(
                observedAt: $0.observedAt,
                resetsAt: $0.resetsAt
            )
        }
        .values
        .compactMap(\.last)
        .sorted { $0.observedAt < $1.observedAt }
    }

    private struct UsageSamplePointIdentity: Hashable {
        let observedAt: Date
        let resetsAt: Date
    }

    private static func freshness(
        account: UsageSnapshot?,
        sourceState: UsageSourceState,
        now: Date
    ) -> UsageFreshness {
        guard let account else { return .unavailable }
        if case .failed = sourceState { return .stale }
        return now.timeIntervalSince(account.fetchedAt) > CurrentUsagePolicy.tightBoundary
            ? .stale
            : .fresh
    }

    private static func evidence(
        account: UsageSnapshot?,
        samples: [UsageSample],
        sourceState: UsageSourceState,
        now: Date,
        workloadMixChanged: Bool
    ) -> UsageEvidence {
        guard let account, let weeklyLimit = account.mainLimit else {
            return UsageEvidence(
                coverage: .unavailable,
                confidence: .unavailable,
                reason: "Weekly usage unavailable",
                policyVersion: CurrentUsagePolicy.version
            )
        }
        let window = weeklyLimit.window
        guard now >= window.startsAt, now < window.resetsAt else {
            return UsageEvidence(
                coverage: .notApplicable,
                confidence: .unavailable,
                reason: "Weekly window ended",
                policyVersion: CurrentUsagePolicy.version
            )
        }
        if case let .failed(message) = sourceState {
            return UsageEvidence(
                coverage: .low,
                confidence: .low,
                reason: message,
                policyVersion: CurrentUsagePolicy.version
            )
        }

        guard samples.count >= 2 else {
            return UsageEvidence(
                coverage: .low,
                confidence: .low,
                reason: "Not enough account history",
                policyVersion: CurrentUsagePolicy.version
            )
        }
        let readings = (
            samples
                + [
                    UsageSample(
                        observedAt: account.fetchedAt,
                        remainingPercent: window.remainingPercent,
                        resetsAt: window.resetsAt
                    )
                ]
        ).sorted { $0.observedAt < $1.observedAt }
        let intervals = UsageHistoryPolicy.segments(readings)
        let intervalReadings = intervals.last ?? []
        let hasCorrection = intervals.count > 1
        let points = intervalReadings.map(\.observedAt)
        let ordered = Array(Set(points)).sorted()
        guard let first = ordered.first, let last = ordered.last else {
            return UsageEvidence(
                coverage: .low,
                confidence: .low,
                reason: "Not enough account history",
                policyVersion: CurrentUsagePolicy.version
            )
        }
        let maximumGap = zip(ordered, ordered.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .max() ?? 0
        let evidenceIntervalStart = hasCorrection ? first : window.startsAt
        let startLag = max(first.timeIntervalSince(evidenceIntervalStart), 0)
        let endLag = max(now.timeIntervalSince(last), 0)
        let elapsed = max(now.timeIntervalSince(evidenceIntervalStart), 1)
        let observedShare = min(max(last.timeIntervalSince(first) / elapsed, 0), 1)

        let measured: UsageEvidence
        if startLag == 0,
           endLag == 0,
           maximumGap <= CurrentUsagePolicy.highGap {
            measured = UsageEvidence(
                coverage: .complete,
                confidence: .high,
                reason: nil,
                policyVersion: CurrentUsagePolicy.version
            )
        } else if observedShare >= CurrentUsagePolicy.highShare,
           startLag <= CurrentUsagePolicy.tightBoundary,
           endLag <= CurrentUsagePolicy.tightBoundary,
           maximumGap <= CurrentUsagePolicy.highGap {
            measured = UsageEvidence(
                coverage: .high,
                confidence: .high,
                reason: "Account boundary is within 15 minutes",
                policyVersion: CurrentUsagePolicy.version
            )
        } else if observedShare >= CurrentUsagePolicy.partialShare,
           startLag <= CurrentUsagePolicy.looseBoundary,
           endLag <= CurrentUsagePolicy.looseBoundary,
           maximumGap <= CurrentUsagePolicy.partialGap {
            let boundaryLag = max(startLag, endLag)
            let reason = boundaryLag > CurrentUsagePolicy.tightBoundary
                ? "Account boundary is \(Int(boundaryLag / 60)) minutes late"
                : "Account gap over 30 minutes"
            measured = UsageEvidence(
                coverage: .partial,
                confidence: .medium,
                reason: reason,
                policyVersion: CurrentUsagePolicy.version
            )
        } else {
            measured = UsageEvidence(
                coverage: .low,
                confidence: .low,
                reason: observedShare < CurrentUsagePolicy.partialShare
                    ? "Less than half of this weekly window is observed"
                    : maximumGap > CurrentUsagePolicy.partialGap
                        ? "Account gap over 6 hours"
                        : "Account boundary is over 1 hour late",
                policyVersion: CurrentUsagePolicy.version
            )
        }
        if hasCorrection {
            guard elapsed >= CurrentUsagePolicy.minimumCorrectionInterval else {
                return UsageEvidence(
                    coverage: .low,
                    confidence: .low,
                    reason: "Unknown reset or correction",
                    policyVersion: CurrentUsagePolicy.version
                )
            }
            return UsageEvidence(
                coverage: measured.confidence == .high ? .partial : measured.coverage,
                confidence: measured.confidence == .high ? .medium : measured.confidence,
                reason: "Unknown reset or correction",
                policyVersion: CurrentUsagePolicy.version
            )
        }
        guard workloadMixChanged, measured.confidence == .high else {
            return measured
        }
        return UsageEvidence(
            coverage: .partial,
            confidence: .medium,
            reason: "Workload mix changed",
            policyVersion: CurrentUsagePolicy.version
        )
    }

    private static func runway(
        window: UsageWindow,
        forecast: Forecast,
        now: Date
    ) -> UsageRunway {
        guard forecast.currentPercentPerDay > 0 else { return .throughReset }
        let exhaustsAt = now.addingTimeInterval(
            window.remainingPercent / forecast.currentPercentPerDay * 86_400
        )
        return exhaustsAt < window.resetsAt
            ? .exhausts(
                exhaustsAt,
                beforeReset: window.resetsAt.timeIntervalSince(exhaustsAt)
            )
            : .throughReset
    }

    private static func estimateRange(_ forecast: Forecast) -> UsageEstimateRange {
        let values = [
            forecast.expectedRemainingAtReset,
            forecast.safetyRemainingAtReset,
            forecast.historicalRemainingAtReset
        ]
        return UsageEstimateRange(
            lowerRemainingAtReset: values.min() ?? 0,
            upperRemainingAtReset: values.max() ?? 0
        )
    }

    private static func title(for status: PaceStatus) -> String {
        switch status {
        case .slowDown: "Slow down"
        case .onTrack: "On track"
        case .roomToUseMore: "Room to use more"
        }
    }

    private static func message(
        window: UsageWindow,
        forecast: Forecast,
        safetyBuffer: Double,
        now: Date
    ) -> String {
        switch forecast.status {
        case .slowDown:
            let timeLeft = window.resetsAt.timeIntervalSince(now)
            let timeToEmpty = window.remainingPercent
                / max(forecast.safetyPercentPerDay, 0.01) * 86_400
            let early = max(timeLeft - timeToEmpty, 0)
            return early > 0
                ? "At this pace, your limit may run out \(durationText(early)) early."
                : "Your current pace is too close to the limit."
        case .onTrack:
            return "You’re on track to have \(Int(forecast.expectedRemainingAtReset.rounded()))% left at reset."
        case .roomToUseMore:
            let room = max(forecast.expectedRemainingAtReset - safetyBuffer, 0)
            return "You can use about \(Int(room.rounded()))% more before the reset."
        }
    }

    private static func suggestedPace(
        forecast: Forecast,
        reset: Date,
        now: Date
    ) -> String {
        let value = reset.timeIntervalSince(now) <= 86_400
            ? forecast.recommendedPercentPerDay / 24
            : forecast.recommendedPercentPerDay
        let unit = reset.timeIntervalSince(now) <= 86_400 ? "an hour" : "a day"
        return "Up to \(oneDecimal(value))% \(unit)"
    }

    private static func oneDecimal(_ value: Double) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(1))
                .locale(Locale(identifier: "en_US"))
        )
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400 {
            let days = max(Int((seconds / 86_400).rounded()), 1)
            return "\(days) \(days == 1 ? "day" : "days")"
        }
        let hours = max(Int((seconds / 3_600).rounded()), 1)
        return "\(hours) \(hours == 1 ? "hour" : "hours")"
    }
}
