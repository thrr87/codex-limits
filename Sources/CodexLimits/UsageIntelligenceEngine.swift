import Foundation

enum UsageSourceState: Equatable, Sendable {
    case available
    case failed(String)
}

enum UsageFreshness: String, Equatable, Sendable {
    case fresh
    case stale
    case unavailable
}

enum CoverageLevel: String, Equatable, Sendable {
    case complete
    case high
    case partial
    case low
    case unavailable
    case notApplicable
}

enum ConfidenceLevel: String, Equatable, Sendable {
    case high
    case medium
    case low
    case unavailable
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
    case exhausts(Date)
    case throughReset

    var text: String {
        switch self {
        case let .exhausts(date):
            date.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened)
                    .locale(Locale(identifier: "en_US"))
            )
        case .throughReset:
            "Through reset"
        }
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

struct UsageChartPoint: Equatable, Identifiable, Sendable {
    let date: Date
    let remaining: Double

    var id: Date { date }
}

struct UsageChartSnapshot: Equatable, Sendable {
    let observedSource: UsageValueSource
    let target: [UsageChartPoint]
    let observed: [UsageChartPoint]
    let currentProjection: [UsageChartPoint]
    let historicalProjection: [UsageChartPoint]
    let currentRunsFaster: Bool
    let accessibilityValue: String
}

struct UsageIntelligenceInput: Equatable, Sendable {
    let account: UsageSnapshot?
    let samples: [UsageSample]
    let safetyBuffer: Double
    let sourceState: UsageSourceState
    let now: Date
    let previousStatus: PaceStatus?
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
        "\(UsageValueSource.derivedEstimate.rawValue) · \(coverageName(evidence.coverage)) coverage · \(confidenceName(evidence.confidence)) confidence"
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

    func updateStatusText(at now: Date) -> String {
        guard let fetchedAt = account?.fetchedAt else { return "Not updated" }
        let isStale = sourceMessage != nil
            || now.timeIntervalSince(fetchedAt) > CurrentUsagePolicy.tightBoundary
        let updated = updatedText(at: now)
        return isStale ? "Stale · \(updated)" : updated
    }

    private func coverageName(_ value: CoverageLevel) -> String {
        switch value {
        case .complete: "Complete"
        case .high: "High"
        case .partial: "Partial"
        case .low: "Low"
        case .unavailable: "Unavailable"
        case .notApplicable: "Not applicable"
        }
    }

    private func confidenceName(_ value: ConfidenceLevel) -> String {
        switch value {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .unavailable: "Unavailable"
        }
    }
}

private enum CurrentUsagePolicy {
    static let version = 1
    static let tightBoundary: TimeInterval = 15 * 60
    static let looseBoundary: TimeInterval = 60 * 60
    static let highGap: TimeInterval = 30 * 60
    static let partialGap: TimeInterval = 6 * 60 * 60
    static let highShare = 0.8
    static let partialShare = 0.5
    static let correctionTolerance = 0.1
}

enum UsageIntelligenceEngine {
    static func evaluate(_ input: UsageIntelligenceInput) -> UsageReaderSnapshot {
        let currentSamples = input.account.map { account in
            input.samples
                .filter {
                    $0.resetsAt == account.mainLimit.window.resetsAt
                        && $0.observedAt >= account.mainLimit.window.startsAt
                        && $0.observedAt <= account.fetchedAt
                        && $0.observedAt <= input.now
                }
                .sorted { $0.observedAt < $1.observedAt }
        } ?? []
        let evidence = evidence(
            account: input.account,
            samples: currentSamples,
            sourceState: input.sourceState,
            now: input.now
        )
        let guidance: UsageGuidance? = input.account.flatMap { account in
            guard evidence.confidence == .high || evidence.confidence == .medium else {
                return nil
            }
            let forecast = ForecastEngine.evaluate(
                window: account.mainLimit.window,
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
                    account: account,
                    forecast: forecast,
                    safetyBuffer: input.safetyBuffer,
                    now: input.now
                ),
                suggestedPace: suggestedPace(
                    forecast: forecast,
                    reset: account.mainLimit.window.resetsAt,
                    now: input.now
                ),
                runway: runway(
                    account: account,
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
        let chart = chart(
            account: input.account,
            samples: currentSamples,
            guidance: guidance,
            safetyBuffer: input.safetyBuffer
        )
        return UsageReaderSnapshot(
            account: input.account,
            accountSource: .account,
            interval: input.account.map {
                UsageObservedInterval(
                    limitID: $0.mainLimit.limitId,
                    durationMinutes: $0.mainLimit.window.durationMinutes,
                    startsAt: $0.mainLimit.window.startsAt,
                    resetsAt: $0.mainLimit.window.resetsAt
                )
            },
            menuBarText: input.account.map {
                "\(Int($0.mainLimit.window.remainingPercent.rounded()))%"
            } ?? "—",
            sourceState: input.sourceState,
            freshness: freshness(
                account: input.account,
                sourceState: input.sourceState,
                now: input.now
            ),
            evidence: evidence,
            guidance: guidance,
            chart: chart
        )
    }

    private static func chart(
        account: UsageSnapshot?,
        samples: [UsageSample],
        guidance: UsageGuidance?,
        safetyBuffer: Double
    ) -> UsageChartSnapshot {
        guard let account else {
            return UsageChartSnapshot(
                observedSource: .account,
                target: [],
                observed: [],
                currentProjection: [],
                historicalProjection: [],
                currentRunsFaster: false,
                accessibilityValue: "Usage is not available."
            )
        }
        let window = account.mainLimit.window
        let target = [
            UsageChartPoint(date: window.startsAt, remaining: 100),
            UsageChartPoint(date: window.resetsAt, remaining: safetyBuffer)
        ]
        let observed = observedPoints(account: account, samples: samples)
        guard let forecast = guidance?.forecast else {
            return UsageChartSnapshot(
                observedSource: .account,
                target: target,
                observed: observed,
                currentProjection: [],
                historicalProjection: [],
                currentRunsFaster: false,
                accessibilityValue: "Now has \(Int(window.remainingPercent.rounded())) percent remaining. A forecast is not available."
            )
        }
        return UsageChartSnapshot(
            observedSource: .account,
            target: target,
            observed: observed,
            currentProjection: projection(
                account: account,
                rate: forecast.currentPercentPerDay,
                remainingAtReset: forecast.expectedRemainingAtReset
            ),
            historicalProjection: projection(
                account: account,
                rate: forecast.historicalPercentPerDay,
                remainingAtReset: forecast.historicalRemainingAtReset
            ),
            currentRunsFaster: forecast.currentPercentPerDay
                > forecast.historicalPercentPerDay,
            accessibilityValue: "Now has \(Int(window.remainingPercent.rounded())) percent remaining. At reset, the current pace leaves \(Int(forecast.expectedRemainingAtReset.rounded())) percent and the historical pace leaves \(Int(forecast.historicalRemainingAtReset.rounded())) percent."
        )
    }

    private static func observedPoints(
        account: UsageSnapshot,
        samples: [UsageSample]
    ) -> [UsageChartPoint] {
        let window = account.mainLimit.window
        let current = UsageChartPoint(
            date: account.fetchedAt,
            remaining: window.remainingPercent
        )
        let local = samples
            .filter {
                $0.observedAt > window.startsAt
                    && $0.observedAt < account.fetchedAt
            }
            .map {
                UsageChartPoint(
                    date: $0.observedAt,
                    remaining: $0.remainingPercent
                )
            }
            .sorted { $0.date < $1.date }
        return deduplicated(local + [current])
    }

    private static func projection(
        account: UsageSnapshot,
        rate: Double,
        remainingAtReset: Double
    ) -> [UsageChartPoint] {
        let window = account.mainLimit.window
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

    private static func deduplicated(
        _ points: [UsageChartPoint]
    ) -> [UsageChartPoint] {
        points.sorted { $0.date < $1.date }.reduce(into: []) { result, point in
            if result.last?.date == point.date {
                result[result.count - 1] = point
            } else {
                result.append(point)
            }
        }
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
        now: Date
    ) -> UsageEvidence {
        guard let account else {
            return UsageEvidence(
                coverage: .unavailable,
                confidence: .unavailable,
                reason: "Weekly usage unavailable",
                policyVersion: CurrentUsagePolicy.version
            )
        }
        let window = account.mainLimit.window
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
        let hasCorrection = zip(readings, readings.dropFirst()).contains {
            $1.remainingPercent
                > $0.remainingPercent + CurrentUsagePolicy.correctionTolerance
        }
        if hasCorrection {
            return UsageEvidence(
                coverage: .low,
                confidence: .low,
                reason: "Unknown reset or correction",
                policyVersion: CurrentUsagePolicy.version
            )
        }
        let points = samples.map(\.observedAt) + [account.fetchedAt]
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
        let startLag = max(first.timeIntervalSince(window.startsAt), 0)
        let endLag = max(now.timeIntervalSince(last), 0)
        let elapsed = max(now.timeIntervalSince(window.startsAt), 1)
        let observedShare = min(max(last.timeIntervalSince(first) / elapsed, 0), 1)

        if startLag == 0,
           endLag == 0,
           maximumGap <= CurrentUsagePolicy.highGap {
            return UsageEvidence(
                coverage: .complete,
                confidence: .high,
                reason: nil,
                policyVersion: CurrentUsagePolicy.version
            )
        }
        if observedShare >= CurrentUsagePolicy.highShare,
           startLag <= CurrentUsagePolicy.tightBoundary,
           endLag <= CurrentUsagePolicy.tightBoundary,
           maximumGap <= CurrentUsagePolicy.highGap {
            return UsageEvidence(
                coverage: .high,
                confidence: .high,
                reason: "Account boundary is within 15 minutes",
                policyVersion: CurrentUsagePolicy.version
            )
        }
        if observedShare >= CurrentUsagePolicy.partialShare,
           startLag <= CurrentUsagePolicy.looseBoundary,
           endLag <= CurrentUsagePolicy.looseBoundary,
           maximumGap <= CurrentUsagePolicy.partialGap {
            let boundaryLag = max(startLag, endLag)
            let reason = boundaryLag > CurrentUsagePolicy.tightBoundary
                ? "Account boundary is \(Int(boundaryLag / 60)) minutes late"
                : "Account gap over 30 minutes"
            return UsageEvidence(
                coverage: .partial,
                confidence: .medium,
                reason: reason,
                policyVersion: CurrentUsagePolicy.version
            )
        }
        return UsageEvidence(
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

    private static func runway(
        account: UsageSnapshot,
        forecast: Forecast,
        now: Date
    ) -> UsageRunway {
        guard forecast.currentPercentPerDay > 0 else { return .throughReset }
        let exhaustsAt = now.addingTimeInterval(
            account.mainLimit.window.remainingPercent
                / forecast.currentPercentPerDay * 86_400
        )
        return exhaustsAt < account.mainLimit.window.resetsAt
            ? .exhausts(exhaustsAt)
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
        account: UsageSnapshot,
        forecast: Forecast,
        safetyBuffer: Double,
        now: Date
    ) -> String {
        switch forecast.status {
        case .slowDown:
            let window = account.mainLimit.window
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
