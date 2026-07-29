import Combine
import CoreGraphics
import Foundation

enum AnalyticsSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case graphs = "Graphs"
    case facts = "Facts"
    case insights = "Insights"

    var id: String { rawValue }
}

enum AnalyticsGraph: String, CaseIterable, Codable, Identifiable, Sendable {
    case usageRemaining = "Usage remaining"
    case tokenActivity = "Token activity"
    case usagePerToken = "Usage per token"
    case concurrency = "Concurrency"

    var id: String { rawValue }

    var usesAccountScope: Bool {
        self == .usageRemaining || self == .usagePerToken
    }
}

enum AnalyticsTimeRange: String, CaseIterable, Codable, Identifiable, Sendable {
    case currentWindow = "Current window"
    case oneDay = "24 hours"
    case threeDays = "3 days"
    case fourWeeks = "4 weeks"
    case twelveWeeks = "12 weeks"
    case selected = "Selected range"

    var id: String { rawValue }

    var isPreset: Bool {
        self != .selected
    }

    func interval(
        within bounds: DateInterval,
        endingAt proposedEnd: Date
    ) -> DateInterval {
        let duration: TimeInterval
        switch self {
        case .currentWindow, .selected:
            return bounds
        case .oneDay:
            duration = 86_400
        case .threeDays:
            duration = 3 * 86_400
        case .fourWeeks:
            duration = 28 * 86_400
        case .twelveWeeks:
            duration = 84 * 86_400
        }
        let end = min(max(proposedEnd, bounds.start), bounds.end)
        return DateInterval(
            start: max(bounds.start, end.addingTimeInterval(-duration)),
            end: end
        )
    }
}

struct WorkspaceFilters: Codable, Equatable, Sendable {
    var projectID: String?
    var taskTreeID: String?
    var model: String?
    var reasoning: String?

    static let all = WorkspaceFilters(
        projectID: nil,
        taskTreeID: nil,
        model: nil,
        reasoning: nil
    )

    var isEmpty: Bool {
        projectID == nil
            && taskTreeID == nil
            && model == nil
            && reasoning == nil
    }
}

struct AnalyticsExplorationState: Codable, Equatable, Sendable {
    var section: AnalyticsSection
    var graph: AnalyticsGraph
    var timeRange: AnalyticsTimeRange
    var filters: WorkspaceFilters
    var visibleRange: DateInterval?
    var pinnedUsageBaselineID: String?
    var pinnedUsageBaselineAccountPartitionID: String?

    static let initial = AnalyticsExplorationState(
        section: .graphs,
        graph: .usageRemaining,
        timeRange: .currentWindow,
        filters: .all,
        visibleRange: nil,
        pinnedUsageBaselineID: nil,
        pinnedUsageBaselineAccountPartitionID: nil
    )
}

@MainActor
final class AnalyticsWorkspaceStore: ObservableObject {
    static let persistenceKey = "analyticsWorkspaceExploration"
    static let insightDispositionsPersistenceKey =
        "analyticsInsightDispositions"

    @Published private(set) var state: AnalyticsExplorationState
    @Published private(set) var insightDispositions:
        [String: InsightDisposition]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = Self.restoredState(from: defaults)
        insightDispositions = Self.restoredInsightDispositions(
            from: defaults
        )
    }

    static func restoredState(
        from defaults: UserDefaults
    ) -> AnalyticsExplorationState {
        guard let data = defaults.data(forKey: Self.persistenceKey),
              let restored = try? JSONDecoder().decode(
                AnalyticsExplorationState.self,
                from: data
              ) else {
            return .initial
        }
        return restored
    }

    static func restoredInsightDispositions(
        from defaults: UserDefaults
    ) -> [String: InsightDisposition] {
        guard let data = defaults.data(
            forKey: Self.insightDispositionsPersistenceKey
        ), let restored = try? JSONDecoder().decode(
            [String: InsightDisposition].self,
            from: data
        ) else {
            return [:]
        }
        return restored
    }

    func selectSection(_ section: AnalyticsSection) {
        update { $0.section = section }
    }

    func selectGraph(_ graph: AnalyticsGraph) {
        update { $0.graph = graph }
    }

    func selectTimeRange(_ range: AnalyticsTimeRange) {
        guard range.isPreset else { return }
        update {
            $0.timeRange = range
            $0.visibleRange = nil
        }
    }

    func updateFilters(_ filters: WorkspaceFilters) {
        update { $0.filters = filters }
    }

    func pinUsageBaseline(
        _ intervalID: String?,
        accountPartitionID: String? = nil
    ) {
        update {
            $0.pinnedUsageBaselineID = intervalID
            $0.pinnedUsageBaselineAccountPartitionID =
                intervalID == nil ? nil : accountPartitionID
        }
    }

    func setInsightDisposition(
        _ disposition: InsightDisposition,
        for insightID: String
    ) {
        guard !insightID.isEmpty else { return }
        var next = insightDispositions
        if disposition == .active {
            next.removeValue(forKey: insightID)
        } else {
            next[insightID] = disposition
        }
        guard next != insightDispositions else { return }
        insightDispositions = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(
                data,
                forKey: Self.insightDispositionsPersistenceKey
            )
        }
    }

    func selectVisibleRange(
        _ range: DateInterval,
        within bounds: DateInterval
    ) {
        guard let clamped = ChartRange.clamped(range, to: bounds) else { return }
        update {
            $0.timeRange = .selected
            $0.visibleRange = clamped
        }
    }

    func resetVisibleRange() {
        update {
            $0.timeRange = .currentWindow
            $0.visibleRange = nil
        }
    }

    func zoom(
        factor: Double,
        anchor: Date,
        currentRange: DateInterval,
        within bounds: DateInterval
    ) {
        let zoomed = ChartRange.zoomed(
            currentRange,
            factor: factor,
            anchor: anchor,
            within: bounds
        )
        update {
            $0.timeRange = zoomed == bounds ? .currentWindow : .selected
            $0.visibleRange = zoomed == bounds ? nil : zoomed
        }
    }

    func effectiveRange(
        within bounds: DateInterval,
        endingAt latestObserved: Date
    ) -> DateInterval {
        if state.timeRange == .selected,
           let visibleRange = state.visibleRange,
           let clamped = ChartRange.clamped(visibleRange, to: bounds) {
            return clamped
        }
        return state.timeRange.interval(
            within: bounds,
            endingAt: latestObserved
        )
    }

    private func update(
        _ change: (inout AnalyticsExplorationState) -> Void
    ) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.persistenceKey)
        }
    }
}

enum ChartRange {
    static let minimumDuration: TimeInterval = 60

    static func clamped(
        _ proposed: DateInterval,
        to bounds: DateInterval
    ) -> DateInterval? {
        guard let intersection = proposed.intersection(with: bounds),
              intersection.duration >= minimumDuration else {
            return nil
        }
        return intersection
    }

    static func zoomed(
        _ current: DateInterval,
        factor: Double,
        anchor: Date,
        within bounds: DateInterval
    ) -> DateInterval {
        guard factor.isFinite, factor > 0 else { return current }
        let boundedCurrent = clamped(current, to: bounds) ?? bounds
        let duration = boundedCurrent.duration
        let nextDuration = min(
            max(duration / factor, minimumDuration),
            bounds.duration
        )
        let boundedAnchor = min(max(anchor, boundedCurrent.start), boundedCurrent.end)
        let anchorFraction = duration > 0
            ? boundedAnchor.timeIntervalSince(boundedCurrent.start) / duration
            : 0.5
        var start = boundedAnchor.addingTimeInterval(-nextDuration * anchorFraction)
        var end = start.addingTimeInterval(nextDuration)

        if start < bounds.start {
            start = bounds.start
            end = start.addingTimeInterval(nextDuration)
        }
        if end > bounds.end {
            end = bounds.end
            start = end.addingTimeInterval(-nextDuration)
        }
        return DateInterval(start: start, end: end)
    }
}

enum UsageChartSeries: String, Equatable, Sendable {
    case observed = "Actual"
    case target = "Target"
    case currentEstimate = "Current estimate"
    case pastEstimate = "Past estimate"
    case estimatedBackfill = "Estimated backfill"
}

enum UsageChartPointSource: Equatable, Sendable {
    case account
    case derivedEstimate
    case accountHistory
    case tokenEstimate
    case weeklyTarget

    var label: String {
        switch self {
        case .account: UsageValueSource.account.rawValue
        case .derivedEstimate: UsageValueSource.derivedEstimate.rawValue
        case .accountHistory: UsageForecastReferenceSource.accountHistory.rawValue
        case .tokenEstimate: UsageForecastReferenceSource.tokenEstimate.rawValue
        case .weeklyTarget: "Weekly target"
        }
    }
}

struct UsageChartSelection: Equatable, Sendable {
    let series: UsageChartSeries
    let date: Date
    let remaining: Double
    let source: UsageChartPointSource

    var accessibilityValue: String {
        "\(series.rawValue), \(Int(remaining.rounded()))% remaining, \(source.label)"
    }

    static func nearest(
        to date: Date,
        in chart: UsageChartSnapshot,
        within visibleRange: DateInterval? = nil
    ) -> UsageChartSelection? {
        candidates(in: chart)
            .filter {
                visibleRange?.contains($0.point.date) ?? true
            }.min {
                let leftDistance = abs($0.point.date.timeIntervalSince(date))
                let rightDistance = abs($1.point.date.timeIntervalSince(date))
                if leftDistance == rightDistance {
                    return $0.priority < $1.priority
                }
                return leftDistance < rightDistance
            }.map {
                UsageChartSelection(
                    series: $0.series,
                    date: $0.point.date,
                    remaining: $0.point.remaining,
                    source: $0.source
                )
            }
    }

    private static func candidates(
        in chart: UsageChartSnapshot
    ) -> [Candidate] {
        chart.allObserved.map {
            Candidate(
                series: .observed,
                point: $0,
                priority: 0,
                source: .account
            )
        } + chart.currentProjection.map {
            Candidate(
                series: .currentEstimate,
                point: $0,
                priority: 1,
                source: .derivedEstimate
            )
        } + chart.historicalProjection.map {
            Candidate(
                series: .pastEstimate,
                point: $0,
                priority: 2,
                source: .accountHistory
            )
        } + chart.estimatedBackfill.map {
            Candidate(
                series: .estimatedBackfill,
                point: $0,
                priority: 3,
                source: .tokenEstimate
            )
        } + chart.target.map {
            Candidate(
                series: .target,
                point: $0,
                priority: 4,
                source: .weeklyTarget
            )
        }
    }

    static func stepping(
        from current: UsageChartSelection?,
        by offset: Int,
        in chart: UsageChartSnapshot,
        within visibleRange: DateInterval
    ) -> UsageChartSelection? {
        let selections = candidates(in: chart)
            .filter { visibleRange.contains($0.point.date) }
            .sorted {
                if $0.point.date == $1.point.date {
                    return $0.priority < $1.priority
                }
                return $0.point.date < $1.point.date
            }
        guard !selections.isEmpty else { return nil }
        let nextIndex: Int
        if let current {
            let currentIndex = selections.firstIndex {
                $0.series == current.series
                    && $0.point.date == current.date
            } ?? selections.enumerated().min {
                abs($0.element.point.date.timeIntervalSince(current.date))
                    < abs($1.element.point.date.timeIntervalSince(current.date))
            }?.offset ?? 0
            nextIndex = min(
                max(currentIndex + offset, 0),
                selections.count - 1
            )
        } else {
            nextIndex = offset < 0 ? selections.count - 1 : 0
        }
        let selected = selections[nextIndex]
        return UsageChartSelection(
            series: selected.series,
            date: selected.point.date,
            remaining: selected.point.remaining,
            source: selected.source
        )
    }

    private struct Candidate {
        let series: UsageChartSeries
        let point: UsageChartPoint
        let priority: Int
        let source: UsageChartPointSource
    }
}

extension UsageChartSnapshot {
    func availableRange(
        including currentWindow: DateInterval
    ) -> DateInterval {
        guard let first = allObserved.first?.date,
              let last = allObserved.last?.date else {
            return currentWindow
        }
        return DateInterval(
            start: min(first, currentWindow.start),
            end: max(last, currentWindow.end)
        )
    }

    var preferredZoomAnchor: Date? {
        allObserved.last?.date
    }
}

enum AccountFactFormatter {
    static func balance(_ rawValue: String) -> String {
        guard let value = Decimal(
            string: rawValue,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            return rawValue
        }
        return value.formatted(
            .number
                .precision(.fractionLength(0 ... 2))
                .locale(Locale(identifier: "en_US"))
        )
    }
}

struct AnalyticsWorkspaceLayout: Equatable, Sendable {
    let width: CGFloat
    let height: CGFloat
    let isCompact: Bool

    static func fitting(visibleSize: CGSize) -> AnalyticsWorkspaceLayout {
        let width = min(640, max(420, visibleSize.width - 40), visibleSize.width)
        let height = min(780, max(460, visibleSize.height - 72), visibleSize.height)
        return AnalyticsWorkspaceLayout(
            width: width,
            height: height,
            isCompact: width < 560
        )
    }
}

enum AnalyticsWorkspacePresentation: Equatable, Sendable {
    case loading
    case valid
    case stale(String)
    case empty
    case sourceError(String)

    static func resolve(
        reader: UsageReaderSnapshot,
        isRefreshing: Bool
    ) -> AnalyticsWorkspacePresentation {
        guard reader.account != nil else {
            if isRefreshing { return .loading }
            if let message = reader.sourceMessage {
                return .sourceError(message)
            }
            return .empty
        }
        if let message = reader.sourceMessage {
            return .stale(message)
        }
        if reader.freshness == .stale {
            return .stale("Account data is stale.")
        }
        return .valid
    }
}
