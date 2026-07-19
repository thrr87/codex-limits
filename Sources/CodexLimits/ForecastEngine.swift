import Foundation

enum ForecastEngine {
    static func evaluate(
        window: UsageWindow,
        samples: [UsageSample],
        tokenHistory: [TokenDay],
        safetyBuffer: Double,
        now: Date,
        previousStatus: PaceStatus?
    ) -> Forecast {
        let daysLeft = max(window.resetsAt.timeIntervalSince(now) / 86_400, 0)
        let currentSamples = samples
            .filter { $0.resetsAt == window.resetsAt && $0.date <= now }
            .sorted { $0.date < $1.date }
        let elapsedDays = max(now.timeIntervalSince(window.startsAt) / 86_400, 1 / 24)
        let windowRate = max((100 - window.remainingPercent) / elapsedDays, 0)
        let recentRate: Double

        if let first = currentSamples.first,
           let last = currentSamples.last,
           last.date > first.date {
            let days = last.date.timeIntervalSince(first.date) / 86_400
            recentRate = max((first.remainingPercent - last.remainingPercent) / days, 0)
        } else {
            recentRate = windowRate
        }

        let currentRate = currentSamples.count > 1
            ? 0.7 * recentRate + 0.3 * windowRate
            : windowRate
        let historicalRates = Dictionary(grouping: samples.filter { $0.resetsAt != window.resetsAt }) {
            $0.resetsAt
        }.values.compactMap { windowSamples -> Double? in
            let ordered = windowSamples.sorted { $0.date < $1.date }
            guard let first = ordered.first,
                  let last = ordered.last,
                  last.date > first.date else { return nil }
            let days = last.date.timeIntervalSince(first.date) / 86_400
            return max((first.remainingPercent - last.remainingPercent) / days, 0)
        }
        let historicalRate: Double
        if historicalRates.isEmpty {
            historicalRate = tokenBootstrapRate(
                window: window,
                windowRate: windowRate,
                tokenHistory: tokenHistory,
                now: now
            ) ?? currentRate
        } else {
            historicalRate = historicalRates.reduce(0, +) / Double(historicalRates.count)
        }
        let expectedRate = 0.75 * currentRate + 0.25 * historicalRate
        let safetyRate = max(currentRate, historicalRate) * 1.2
        let expected = max(window.remainingPercent - expectedRate * daysLeft, 0)
        let safety = max(window.remainingPercent - safetyRate * daysLeft, 0)
        let historical = max(window.remainingPercent - historicalRate * daysLeft, 0)
        let recommended = daysLeft > 0
            ? max(window.remainingPercent - safetyBuffer, 0) / daysLeft
            : 0
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
            historicalRemainingAtReset: historical,
            recommendedPercentPerDay: recommended,
            currentPercentPerDay: expectedRate,
            historicalPercentPerDay: historicalRate,
            safetyPercentPerDay: safetyRate
        )
    }

    private static func tokenBootstrapRate(
        window: UsageWindow,
        windowRate: Double,
        tokenHistory: [TokenDay],
        now: Date
    ) -> Double? {
        let day: TimeInterval = 86_400
        let dayNumber: (Date) -> Int = { Int(floor($0.timeIntervalSince1970 / day)) }
        let start = dayNumber(window.startsAt)
        let today = dayNumber(now)
        let buckets = Dictionary(grouping: tokenHistory, by: { dayNumber($0.date) })
            .mapValues { $0.reduce(Int64(0)) { $0 + $1.tokens } }
        guard let first = buckets.keys.min(),
              let latest = buckets.keys.filter({ $0 < today }).max(),
              latest >= start else { return nil }

        let currentCount = latest - start + 1
        let currentTokens = (start ... latest).reduce(Int64(0)) { $0 + (buckets[$1] ?? 0) }
        let historyEnd = start - 1
        let historyStart = max(first, historyEnd - 27)
        guard historyStart <= historyEnd, currentTokens > 0 else { return nil }

        let historyCount = historyEnd - historyStart + 1
        let historyTokens = (historyStart ... historyEnd).reduce(Int64(0)) { $0 + (buckets[$1] ?? 0) }
        let currentAverage = Double(currentTokens) / Double(currentCount)
        let historicalAverage = Double(historyTokens) / Double(historyCount)
        guard currentAverage > 0, historicalAverage > 0 else { return nil }

        // ponytail: Daily token buckets are a coarse bootstrap; local percentage windows replace it.
        let relativePace = min(max(historicalAverage / currentAverage, 0.25), 4)
        return windowRate * relativePace
    }
}
