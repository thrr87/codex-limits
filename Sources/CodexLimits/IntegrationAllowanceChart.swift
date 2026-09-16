import ClaudeIntegrationCore
import Foundation

extension GrokAllowanceSnapshot {
    var historyMetric: String { period == .weekly ? "grok-weekly" : "grok-monthly" }

    var historyObservation: AllowanceObservation? {
        guard let remainingPercent else { return nil }
        return AllowanceObservation(
            metric: historyMetric,
            observedAt: observedAt,
            remainingPercent: remainingPercent,
            resetsAt: resetsAt,
            startsAt: startsAt ?? (period == .weekly
                ? resetsAt.addingTimeInterval(-7 * 86_400) : nil),
            source: measurementSource
        )
    }
}

/// Provider observations feed the same chart as Codex, without token estimates.
struct IntegrationAllowanceChart: Sendable {
    let window: UsageWindow
    let chart: UsageChartSnapshot
    let evidence: UsageEvidence
    let forecastUnavailableReason: String?

    init?(
        metric: String,
        observations: [AllowanceObservation],
        current: AllowanceObservation?,
        now: Date,
        isStale: Bool,
        safetyBuffer: Double
    ) {
        guard !Task.isCancelled else { return nil }
        let values = (observations + [current].compactMap { $0 }).filter {
            $0.metric == metric && $0.isValid && $0.observedAt <= now
        }
        let grouped = Dictionary(grouping: values, by: \.observedAt)
        let samples = grouped.values.compactMap { readings -> UsageSample? in
            guard let value = readings.last else { return nil }
            return UsageSample(
                observedAt: value.observedAt,
                remainingPercent: value.remainingPercent,
                resetsAt: value.resetsAt,
                comparisonBreak: readings.contains {
                    $0.remainingPercent != value.remainingPercent || $0.resetsAt != value.resetsAt
                        || $0.startsAt != value.startsAt || $0.source != value.source
                }
            )
        }.sorted { $0.observedAt < $1.observedAt }
        guard let latest = samples.last else { return nil }
        guard !Task.isCancelled else { return nil }
        let latestValue = grouped[latest.observedAt]?.last
        let start = latestValue?.startsAt
        let first = samples.first { $0.resetsAt == latest.resetsAt } ?? latest
        window = UsageWindow(
            remainingPercent: latest.remainingPercent,
            resetsAt: latest.resetsAt,
            durationMinutes: max(1, Int(ceil(latest.resetsAt.timeIntervalSince(start ?? first.observedAt) / 60)))
        )
        guard window.isValid else { return nil }

        var segments: [[UsageSample]] = []
        for sample in samples {
            guard !Task.isCancelled else { return nil }
            if let previous = segments.last?.last,
               !sample.comparisonBreak,
               !previous.comparisonBreak,
               sample.resetsAt == previous.resetsAt,
               grouped[sample.observedAt]?.last?.startsAt == grouped[previous.observedAt]?.last?.startsAt,
               grouped[sample.observedAt]?.last?.source == grouped[previous.observedAt]?.last?.source,
               sample.remainingPercent <= previous.remainingPercent + UsageHistoryPolicy.correctionTolerance,
               sample.observedAt.timeIntervalSince(previous.observedAt) <= UsageHistoryPolicy.maximumComparableGap {
                segments[segments.count - 1].append(sample)
            } else {
                segments.append([sample])
            }
        }
        let windows = Dictionary(grouping: segments, by: { $0[0].resetsAt })
            .map { reset, segments in
                UsageAllowanceWindowSeries(
                    resetsAt: reset,
                    observedSegments: segments.map { segment in
                        segment.map { UsageChartPoint(date: $0.observedAt, remaining: $0.remainingPercent) }
                    }
                )
            }.sorted { $0.resetsAt < $1.resetsAt }

        let recent = (segments.last ?? []).filter { $0.observedAt >= now.addingTimeInterval(-86_400) }
        var projection: [UsageChartPoint] = []
        let hasCurrent = current.map {
            $0.isValid && $0.metric == metric && $0.observedAt == latest.observedAt
                && $0.resetsAt == latest.resetsAt && $0.remainingPercent == latest.remainingPercent
        } ?? false
        if hasCurrent, !isStale, latest.resetsAt > now,
           now.timeIntervalSince(latest.observedAt) < UsageHistoryPolicy.maximumComparableGap,
           let first = recent.first, recent.count >= 2,
           latest.observedAt.timeIntervalSince(first.observedAt) >= 60 {
            let days = latest.observedAt.timeIntervalSince(first.observedAt) / 86_400
            let rate = max(0, (first.remainingPercent - latest.remainingPercent) / days)
            if rate.isFinite {
                projection = UsageIntelligenceEngine.projection(
                    reading: latest, window: window, rate: rate,
                    remainingAtReset: max(0, latest.remainingPercent - rate * latest.resetsAt.timeIntervalSince(latest.observedAt) / 86_400)
                )
            }
        }
        let buffer = SafetyBufferPolicy.normalized(safetyBuffer)
        let target = start.map {
            [UsageChartPoint(date: $0, remaining: 100), UsageChartPoint(date: latest.resetsAt, remaining: buffer)]
        } ?? []
        chart = UsageChartSnapshot(
            observedSource: .account,
            target: target,
            currentProjection: projection,
            currentAllowanceReset: latest.resetsAt,
            allowanceWindows: windows,
            currentRunsFaster: projection.last.map { $0.remaining < buffer } ?? false,
            accessibilityValue: "Last observed \(Int(latest.remainingPercent.rounded())) percent remaining. "
                + (projection.isEmpty ? "A forecast is not available." : "Current estimate follows the observed usage pace.")
        )
        evidence = UsageEvidence(
            coverage: .partial,
            confidence: projection.isEmpty ? .unavailable : .low,
            reason: nil,
            policyVersion: 1
        )
        forecastUnavailableReason = !projection.isEmpty ? nil
            : !hasCurrent || latest.resetsAt <= now
                ? "A current usage observation is needed for an estimate."
                : isStale || now.timeIntervalSince(latest.observedAt) >= UsageHistoryPolicy.maximumComparableGap
                    ? "Usage is stale. A new observation is needed for an estimate."
                    : "An estimate needs at least two recent observations from the current period."
    }
}
