import Foundation

struct ConcurrencyPoint: Equatable, Identifiable, Sendable {
    let date: Date
    let count: Int
    let taskTreeIDs: [String]

    var id: Date { date }
}

struct ActivityTimelineSlice: Equatable, Sendable {
    let activeTime: TimeInterval
    let waitingTime: TimeInterval?
    let pollingTime: TimeInterval?
    let activityBreakdownReason: String?
    let points: [ConcurrencyPoint]
    let coverage: CoverageLevel
    let reason: String?

    var maximumConcurrency: Int {
        points.map(\.count).max() ?? 0
    }
}

struct ActivityTimelineSnapshot: Equatable, Sendable {
    fileprivate struct TurnInterval: Equatable, Sendable {
        let start: Date
        let end: Date
        let rootTaskID: String
        let projectLabel: String?
        let context: LocalActivityContext
    }

    fileprivate struct BoundaryIssue: Equatable, Sendable {
        let date: Date
        let affectedStart: Date?
        let affectedEnd: Date?
        let reason: String
        let rootTaskID: String?
        let projectLabel: String?
        let context: LocalActivityContext?

        func affects(_ interval: DateInterval) -> Bool {
            switch (affectedStart, affectedEnd) {
            case let (start?, end?):
                return start < interval.end && end > interval.start
            case let (start?, nil):
                return start < interval.end
            case let (nil, end?):
                return end > interval.start
            case (nil, nil):
                return date >= interval.start && date < interval.end
            }
        }
    }

    fileprivate let turns: [TurnInterval]
    fileprivate let boundaryIssues: [BoundaryIssue]
    fileprivate let observation: LocalActivityObservation
    let interval: DateInterval

    func slice(
        in selectedInterval: DateInterval,
        filters: WorkspaceFilters
    ) -> ActivityTimelineSlice {
        let inRange = turns.compactMap { turn -> TurnInterval? in
            let start = max(turn.start, selectedInterval.start)
            let end = min(turn.end, selectedInterval.end)
            guard start < end else { return nil }
            return TurnInterval(
                start: start,
                end: end,
                rootTaskID: turn.rootTaskID,
                projectLabel: turn.projectLabel,
                context: turn.context
            )
        }
        let selected = inRange.filter {
            matches($0, filters: filters)
        }
        let rootIntervals = Dictionary(grouping: selected, by: \.rootTaskID)
            .flatMap { root, turns in
                Self.union(turns.map { DateInterval(start: $0.start, end: $0.end) })
                    .map { (root, $0) }
            }
        let activeTime = Self.union(rootIntervals.map(\.1))
            .reduce(0) { $0 + $1.duration }
        let points = Self.points(for: rootIntervals)
        let relevantIssues = boundaryIssues.filter {
            $0.affects(selectedInterval)
                && matches($0, filters: filters)
        }
        let filterGapReason = filterGapReason(
            in: inRange,
            filters: filters
        )
        let coverage: CoverageLevel
        let reason: String?
        switch observation {
        case let .unavailable(message):
            coverage = .unavailable
            reason = message
        case let .gap(_, _, message):
            coverage = .low
            reason = message
        case .continuous:
            if !relevantIssues.isEmpty {
                coverage = selected.isEmpty ? .low : .partial
                reason = relevantIssues.contains {
                    $0.reason == "Task Tree metadata is missing"
                } ? "Task Tree metadata is missing"
                    : "Some Active Turn boundaries are missing or invalid"
            } else if let filterGapReason {
                coverage = selected.isEmpty ? .low : .partial
                reason = filterGapReason
            } else {
                coverage = selected.isEmpty ? .notApplicable : .partial
                reason = selected.isEmpty
                    ? "No completed Active Turns were observed"
                    : "Task Tree may omit Review and Guardian Tasks"
            }
        }
        return ActivityTimelineSlice(
            activeTime: activeTime,
            waitingTime: nil,
            pollingTime: nil,
            activityBreakdownReason: "Wait and poll time are unavailable",
            points: points,
            coverage: coverage,
            reason: reason
        )
    }

    private func filterGapReason(
        in turns: [TurnInterval],
        filters: WorkspaceFilters
    ) -> String? {
        if filters.projectID != nil,
           turns.contains(where: { $0.projectLabel == nil }) {
            return "Some Active Turns have no Project metadata"
        }
        if filters.model != nil,
           turns.contains(where: { $0.context.effectiveModel == nil }) {
            return "Some Active Turns have no model metadata"
        }
        if filters.reasoning != nil,
           turns.contains(where: { $0.context.reasoning == nil }) {
            return "Some Active Turns have no reasoning metadata"
        }
        return nil
    }

    private func matches(
        _ issue: BoundaryIssue,
        filters: WorkspaceFilters
    ) -> Bool {
        (filters.projectID == nil
            || issue.projectLabel == nil
            || filters.projectID == issue.projectLabel)
            && (
                filters.taskTreeID == nil
                    || issue.rootTaskID == nil
                    || filters.taskTreeID == issue.rootTaskID
            )
            && (
                filters.model == nil
                    || issue.context?.effectiveModel == nil
                    || filters.model == issue.context?.effectiveModel
            )
            && (
                filters.reasoning == nil
                    || issue.context?.reasoning == nil
                    || filters.reasoning == issue.context?.reasoning
            )
    }

    private func matches(
        _ turn: TurnInterval,
        filters: WorkspaceFilters
    ) -> Bool {
        (filters.projectID == nil || filters.projectID == turn.projectLabel)
            && (
                filters.taskTreeID == nil
                    || filters.taskTreeID == turn.rootTaskID
            )
            && (
                filters.model == nil
                    || filters.model == turn.context.effectiveModel
            )
            && (
                filters.reasoning == nil
                    || filters.reasoning == turn.context.reasoning
            )
    }

    private static func union(
        _ intervals: [DateInterval]
    ) -> [DateInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var result: [DateInterval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(
                    start: current.start,
                    end: max(current.end, interval.end)
                )
            } else {
                result.append(current)
                current = interval
            }
        }
        result.append(current)
        return result
    }

    private static func points(
        for intervals: [(root: String, interval: DateInterval)]
    ) -> [ConcurrencyPoint] {
        var starts: [Date: Set<String>] = [:]
        var ends: [Date: Set<String>] = [:]
        for value in intervals {
            starts[value.interval.start, default: []].insert(value.root)
            ends[value.interval.end, default: []].insert(value.root)
        }
        var active = Set<String>()
        return Set(starts.keys).union(ends.keys).sorted().map { date in
            active.subtract(ends[date] ?? [])
            active.formUnion(starts[date] ?? [])
            return ConcurrencyPoint(
                date: date,
                count: active.count,
                taskTreeIDs: active.sorted()
            )
        }
    }
}

enum ActivityTimelineAggregator {
    static func evaluate(
        facts: [LocalActivityFact],
        projections: [ThreadProjection],
        interval: DateInterval,
        observation: LocalActivityObservation
    ) -> ActivityTimelineSnapshot {
        let projectionsByTask = Dictionary(
            projections.map { ($0.taskID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let knownRoots = Set(
            facts.compactMap { fact -> String? in
                guard fact.key == .root,
                      fact.availability == .available,
                      case let .identifier(taskID) = fact.value else {
                    return nil
                }
                return taskID
            }
        )
        let timestampParser = LocalEventTimestampParser()
        var seen = Set<String>()
        var turns: [ActivityTimelineSnapshot.TurnInterval] = []
        var completedTurnKeys = Set<String>()
        var pendingIssues: [
            (turnKey: String?, issue: ActivityTimelineSnapshot.BoundaryIssue)
        ] = []
        for fact in facts {
            guard fact.key == .time,
                  let eventID = fact.eventID,
                  seen.insert(eventID).inserted else {
                continue
            }
            let timing: LocalTurnTiming?
            if case let .turnTiming(value) = fact.value {
                timing = value
            } else {
                timing = nil
            }
            let start = timing?.startedAt
            let end = timing?.completedAt
            let context = fact.context
            let taskID = context?.taskID
            let turnKey = taskID.flatMap { taskID in
                context?.turnID.map { "\(taskID)|\($0)" }
            }
            let root = taskID.flatMap {
                rootTaskID(
                    for: $0,
                    projections: projectionsByTask,
                    knownRoots: knownRoots
                )
            }
            guard fact.availability == .available,
                  let start,
                  let end,
                  start < end,
                  let context,
                  let root else {
                let issueDate = start
                    ?? end
                    ?? fact.eventTimestamp.flatMap(timestampParser.date)
                if let issueDate {
                    let affectedBounds = affectedBounds(
                        start: start,
                        end: end
                    )
                    pendingIssues.append(
                        (
                            turnKey,
                            ActivityTimelineSnapshot.BoundaryIssue(
                                date: issueDate,
                                affectedStart: affectedBounds.start,
                                affectedEnd: affectedBounds.end,
                                reason: root == nil && taskID != nil
                                    ? "Task Tree metadata is missing"
                                    : "Some Active Turn boundaries are missing or invalid",
                                rootTaskID: root,
                                projectLabel: root.flatMap {
                                    projectionsByTask[$0]?.projectLabel
                                },
                                context: context
                            )
                        )
                    )
                }
                continue
            }
            turns.append(
                ActivityTimelineSnapshot.TurnInterval(
                    start: start,
                    end: end,
                    rootTaskID: root,
                    projectLabel: projectionsByTask[root]?.projectLabel,
                    context: context
                )
            )
            if let turnKey {
                completedTurnKeys.insert(turnKey)
            }
        }
        let boundaryIssues = pendingIssues.compactMap {
            $0.turnKey.map(completedTurnKeys.contains) == true
                ? nil
                : $0.issue
        }
        return ActivityTimelineSnapshot(
            turns: turns,
            boundaryIssues: boundaryIssues,
            observation: observation,
            interval: interval
        )
    }

    private static func affectedBounds(
        start: Date?,
        end: Date?
    ) -> (start: Date?, end: Date?) {
        guard let start, let end else {
            return (start, end)
        }
        return start <= end
            ? (start, end)
            : (end, start)
    }

    private static func rootTaskID(
        for taskID: String,
        projections: [String: ThreadProjection],
        knownRoots: Set<String>
    ) -> String? {
        var current = taskID
        var visited = Set<String>()
        while visited.insert(current).inserted {
            guard let projection = projections[current] else {
                return knownRoots.contains(current) ? current : nil
            }
            guard let parent = projection.parentTaskID else { return current }
            current = parent
        }
        return nil
    }
}
