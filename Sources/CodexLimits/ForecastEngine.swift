import Foundation

struct RecentAccountMovement: Equatable, Sendable {
    let latest: UsageSample
    let percentPerDay: Double
}

enum ForecastEngine {
    static func evaluate(
        window: UsageWindow,
        samples: [UsageSample],
        tokenHistory: [TokenDay],
        safetyBuffer: Double,
        now: Date,
        previousStatus: PaceStatus?,
        recentMovement: RecentAccountMovement? = nil
    ) -> Forecast {
        let latestDate = recentMovement?.latest.observedAt ?? now
        let latestRemaining = recentMovement?.latest.remainingPercent
            ?? window.remainingPercent
        let daysLeft = max(
            window.resetsAt.timeIntervalSince(latestDate) / 86_400,
            0
        )
        let currentSamples = samples
            .filter { $0.resetsAt == window.resetsAt && $0.observedAt <= now }
            .sorted { $0.observedAt < $1.observedAt }
        let currentIntervalSamples = samplesAfterLastCorrection(currentSamples)
        let elapsedDays = max(now.timeIntervalSince(window.startsAt) / 86_400, 1 / 24)
        let windowRate = max((100 - window.remainingPercent) / elapsedDays, 0)
        let recentRate: Double

        if let first = currentIntervalSamples.first,
           let last = currentIntervalSamples.last,
           last.observedAt > first.observedAt {
            let days = last.observedAt.timeIntervalSince(first.observedAt) / 86_400
            recentRate = max((first.remainingPercent - last.remainingPercent) / days, 0)
        } else {
            recentRate = windowRate
        }

        let currentRate = recentMovement?.percentPerDay
            ?? (currentIntervalSamples.count > 1
                ? 0.7 * recentRate + 0.3 * windowRate
                : windowRate)
        let historicalRates = comparableHistoricalRates(
            samples: samples,
            excluding: window.resetsAt
        )
        let historicalRate: Double
        let historicalReferenceSource: UsageForecastReferenceSource?
        if historicalRates.isEmpty {
            let tokenRate = tokenBootstrapRate(
                window: window,
                windowRate: windowRate,
                tokenHistory: tokenHistory,
                now: now
            )
            historicalRate = tokenRate ?? currentRate
            historicalReferenceSource = tokenRate == nil ? nil : .tokenEstimate
        } else {
            historicalRate = median(Array(historicalRates.prefix(4)))
            historicalReferenceSource = .accountHistory
        }
        let expectedRate = recentMovement == nil
            ? 0.75 * currentRate + 0.25 * historicalRate
            : currentRate
        let safetyRate = (
            recentMovement == nil
                ? max(currentRate, historicalRate)
                : currentRate
        ) * 1.2
        let expected = max(latestRemaining - expectedRate * daysLeft, 0)
        let safety = max(latestRemaining - safetyRate * daysLeft, 0)
        let historical = max(latestRemaining - historicalRate * daysLeft, 0)
        let historicalReference = historicalReferenceSource.map {
            UsageForecastReference(
                source: $0,
                percentPerDay: historicalRate,
                remainingAtReset: historical
            )
        }
        let allowanceRate = daysLeft > 0
            ? max(latestRemaining - safetyBuffer, 0) / daysLeft
            : 0
        let recommended = historicalReferenceSource == .accountHistory
            ? min(allowanceRate, historicalRate * 1.2)
            : allowanceRate
        let status: PaceStatus
        if safety < safetyBuffer || (previousStatus == .slowDown && safety < safetyBuffer + 1) {
            status = .slowDown
        } else if expected > 8 || (previousStatus == .roomToUseMore && expected > 7) {
            status = .roomToUseMore
        } else {
            status = .onTrack
        }

        return Forecast(
            status: status,
            expectedRemainingAtReset: expected,
            safetyRemainingAtReset: safety,
            recommendedPercentPerDay: recommended,
            currentPercentPerDay: expectedRate,
            safetyPercentPerDay: safetyRate,
            historicalReference: historicalReference
        )
    }

    private static func samplesAfterLastCorrection(
        _ samples: [UsageSample]
    ) -> [UsageSample] {
        UsageHistoryPolicy.segments(samples).last ?? []
    }

    private static func comparableHistoricalRates(
        samples: [UsageSample],
        excluding currentReset: Date
    ) -> [Double] {
        let day: TimeInterval = 86_400
        return Dictionary(
            grouping: samples.filter { $0.resetsAt != currentReset },
            by: \.resetsAt
        )
        .compactMap { reset, windowSamples -> (Date, Double)? in
            let start = reset.addingTimeInterval(-7 * day)
            let ordered = windowSamples
                .filter {
                    $0.observedAt >= start && $0.observedAt <= reset
                }
                .sorted { $0.observedAt < $1.observedAt }
            let intervals = UsageHistoryPolicy.segments(ordered)
            guard let first = ordered.first,
                  let last = ordered.last,
                  ordered.count >= 2,
                  intervals.count == 1,
                  first.observedAt.timeIntervalSince(start)
                    <= UsageHistoryPolicy.tightBoundary,
                  reset.timeIntervalSince(last.observedAt)
                    <= UsageHistoryPolicy.tightBoundary,
                  zip(ordered, ordered.dropFirst()).allSatisfy({
                      $1.observedAt.timeIntervalSince($0.observedAt)
                          <= UsageHistoryPolicy.maximumComparableGap
                  }),
                  last.observedAt > first.observedAt else {
                return nil
            }
            let days = last.observedAt.timeIntervalSince(first.observedAt) / day
            return (reset, max(
                (first.remainingPercent - last.remainingPercent) / days,
                0
            ))
        }
        .sorted { $0.0 > $1.0 }
        .map(\.1)
    }

    static func median(_ values: [Double]) -> Double {
        let ordered = values.sorted()
        guard !ordered.isEmpty else { return 0 }
        let middle = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return (ordered[middle - 1] + ordered[middle]) / 2
        }
        return ordered[middle]
    }

    private static func tokenBootstrapRate(
        window: UsageWindow,
        windowRate: Double,
        tokenHistory: [TokenDay],
        now: Date
    ) -> Double? {
        let day: TimeInterval = 86_400
        let dayNumber: (Date) -> Int? = {
            let value = floor($0.timeIntervalSince1970 / day)
            guard value.isFinite else { return nil }
            return Int(exactly: value)
        }
        guard let start = dayNumber(window.startsAt),
              let today = dayNumber(now) else { return nil }
        var buckets: [Int: Double] = [:]
        for tokenDay in tokenHistory {
            guard tokenDay.tokens >= 0,
                  let bucket = dayNumber(tokenDay.date) else { return nil }
            let total = (buckets[bucket] ?? 0) + Double(tokenDay.tokens)
            guard total.isFinite else { return nil }
            buckets[bucket] = total
        }
        guard let first = buckets.keys.min(),
              let latest = buckets.keys.filter({ $0 < today }).max(),
              latest >= start else { return nil }

        let currentCount = Double(latest) - Double(start) + 1
        let currentTokens = buckets.reduce(0.0) {
            $1.key >= start && $1.key <= latest ? $0 + $1.value : $0
        }
        let (historyEnd, endOverflow) = start.subtractingReportingOverflow(1)
        guard !endOverflow else { return nil }
        let (candidateStart, startOverflow) =
            historyEnd.subtractingReportingOverflow(27)
        guard !startOverflow else { return nil }
        let historyStart = max(first, candidateStart)
        guard historyStart <= historyEnd, currentTokens > 0 else { return nil }

        let historyCount = Double(historyEnd) - Double(historyStart) + 1
        let historyTokens = buckets.reduce(0.0) {
            $1.key >= historyStart && $1.key <= historyEnd
                ? $0 + $1.value
                : $0
        }
        let currentAverage = currentTokens / currentCount
        let historicalAverage = historyTokens / historyCount
        guard currentAverage.isFinite,
              historicalAverage.isFinite,
              currentAverage > 0,
              historicalAverage > 0 else { return nil }

        // Daily token buckets are a coarse bootstrap; percentage-based windows replace them.
        let relativePace = min(max(historicalAverage / currentAverage, 0.25), 4)
        return windowRate * relativePace
    }
}
