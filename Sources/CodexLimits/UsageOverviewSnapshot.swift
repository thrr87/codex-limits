import ClaudeIntegrationCore
import Foundation

/// A bounded view of real observations in the current allowance period.
struct UsageOverviewSnapshot: Equatable, Sendable {
    static let maximumPoints = 256

    let range: DateInterval
    let target: [UsageChartPoint]
    let observedSegments: [[UsageChartPoint]]
    let latest: UsageChartPoint?

    init?(chart: UsageChartSnapshot, window: UsageWindow, now: Date) {
        guard chart.observedSource == .account, window.isValid, now.isSupportedUsageDate,
              window.startsAt <= now, window.resetsAt > now,
              chart.currentAllowanceReset == window.resetsAt else { return nil }
        range = DateInterval(start: window.startsAt, end: window.resetsAt)
        target = Self.compact(chart.target.filter {
            Self.isValid($0) && $0.date >= window.startsAt && $0.date <= window.resetsAt
        }, limit: 2)

        var segments: [[UsageChartPoint]] = []
        for original in chart.observedSegments {
            var segment: [UsageChartPoint] = []
            for point in original {
                guard Self.isValid(point), point.date >= window.startsAt, point.date <= now else {
                    if !segment.isEmpty { segments.append(segment); segment = [] }
                    continue
                }
                if let previous = segment.last, point.date <= previous.date {
                    segments.append(segment)
                    segment = []
                }
                segment.append(point)
            }
            if !segment.isEmpty { segments.append(segment) }
        }
        segments.sort { $0[0].date < $1[0].date }
        latest = segments.flatMap { $0 }.max { $0.date < $1.date }
        let budget = Self.maximumPoints - target.count - (latest == nil ? 0 : 1)
        // Preserve both ends of every retained segment; omit older segments if
        // the boundary points alone exceed the thumbnail's fixed display budget.
        var endpointCount = segments.reduce(0) { $0 + min(2, $1.count) }
        var firstKept = 0
        while endpointCount > budget {
            endpointCount -= min(2, segments[firstKept].count)
            firstKept += 1
        }
        let retained = segments.dropFirst(firstKept)
        var remainingInterior = retained.reduce(0) { $0 + max(0, $1.count - 2) }
        var extraBudget = budget - endpointCount
        observedSegments = retained.map { segment in
            let interior = max(0, segment.count - 2)
            let extra = remainingInterior > 0
                ? min(interior, extraBudget * interior / remainingInterior) : 0
            extraBudget -= extra
            remainingInterior -= interior
            return Self.compact(segment, limit: min(2, segment.count) + extra)
        }
    }

    init?(observations: [AllowanceObservation], current: AllowanceObservation?, now: Date, safetyBuffer: Double) {
        guard let current, Self.historyReadStart(current: current, now: now) != nil,
              let content = IntegrationAllowanceChart(
                metric: current.metric,
                observations: observations.filter { $0.resetsAt == current.resetsAt },
                current: current, now: now, isStale: true, safetyBuffer: safetyBuffer
              ) else { return nil }
        self.init(chart: content.chart, window: content.window, now: now)
    }

    /// A 31-day elapsed range touches at most 32 UTC daily files.
    static func historyReadStart(current: AllowanceObservation?, now: Date) -> Date? {
        guard let current, current.isValid, now.isSupportedUsageDate,
              current.observedAt <= now, current.resetsAt > now else { return nil }
        let earliest = now.addingTimeInterval(-31 * 86_400)
        return max(current.startsAt ?? earliest, earliest)
    }

    private static func isValid(_ point: UsageChartPoint) -> Bool {
        point.date.isSupportedUsageDate && point.remaining.isFinite
            && (0 ... 100).contains(point.remaining)
    }

    private static func compact(_ points: [UsageChartPoint], limit: Int) -> [UsageChartPoint] {
        guard points.count > limit else { return points }
        guard limit > 1 else { return Array(points.suffix(limit)) }
        return (0 ..< limit).map { points[$0 * (points.count - 1) / (limit - 1)] }
    }
}
