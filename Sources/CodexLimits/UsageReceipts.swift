import Foundation

struct UsageReceiptBreakdown: Equatable, Identifiable, Sendable {
    let label: String
    let tokens: Int64

    var id: String { label }
}

struct UsageReceipt: Equatable, Identifiable, Sendable {
    let rootTaskID: String
    let projectLabel: String?
    let tokens: Int64
    let interval: DateInterval
    let taskCount: Int
    let agents: [UsageReceiptBreakdown]
    let turns: [UsageReceiptBreakdown]
    let models: [UsageReceiptBreakdown]
    let reasoningLevels: [UsageReceiptBreakdown]
    let coverage: CoverageLevel
    let reason: String?

    var id: String { rootTaskID }

    var displayTaskID: String {
        String(rootTaskID.prefix(8))
    }

    var intervalText: String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(Locale(identifier: "en_US"))
        return "\(interval.start.formatted(style))–\(interval.end.formatted(style))"
    }

    var accessibilityValue: String {
        var parts = [
            "Task \(displayTaskID)",
            "\(tokens) local tokens",
            "\(taskCount) \(taskCount == 1 ? "task" : "tasks") in the tree"
        ]
        if let projectLabel {
            parts.insert("Project \(projectLabel)", at: 0)
        }
        parts.append("\(coverage.displayName) coverage")
        if let reason {
            parts.append(reason)
        }
        return parts.joined(separator: ", ")
    }
}

struct UsageReceiptSlice: Equatable, Sendable {
    let receipts: [UsageReceipt]
    let totalTokens: Int64
    let unattributedTokens: Int64
    let points: [LocalTokenActivityPoint]
    let coverage: CoverageLevel
    let reason: String?
}

struct UsageReceiptFilterOptions: Equatable, Sendable {
    let projects: [String]
    let taskTrees: [String]
    let models: [String]
    let reasoningLevels: [String]
}

struct UsageReceiptSnapshot: Equatable, Sendable {
    fileprivate let contributions: [Contribution]
    fileprivate let observation: LocalActivityObservation
    let interval: DateInterval

    func slice(
        in selectedInterval: DateInterval,
        filters: WorkspaceFilters
    ) -> UsageReceiptSlice {
        let inRange = contributions.filter {
            Self.contains($0.date, in: selectedInterval)
        }
        let filterGapReason = Self.filterGapReason(
            in: inRange,
            filters: filters
        )
        let selected = inRange.filter {
            Self.matches($0, filters: filters)
        }
        let tokenContributions = selected.filter { $0.tokens > 0 }
        let hasUnboundedCounter = selected.contains {
            $0.hasUnboundedCounter
        }
        guard let total = Self.sum(selected.map(\.tokens)) else {
            return UsageReceiptSlice(
                receipts: [],
                totalTokens: 0,
                unattributedTokens: 0,
                points: [],
                coverage: .unavailable,
                reason: "Local token total is invalid"
            )
        }
        let grouped = Dictionary(
            grouping: tokenContributions.compactMap { contribution in
                contribution.rootTaskID.map { ($0, contribution) }
            },
            by: \.0
        )
        let receipts = grouped.map { rootTaskID, values in
            let contributions = values.map(\.1)
            let project = contributions.compactMap(\.projectLabel).first
            let hasMissingProject = contributions.contains {
                $0.projectLabel == nil
            }
            let receiptHasUnboundedCounter = selected.contains {
                $0.rootTaskID == rootTaskID && $0.hasUnboundedCounter
            }
            let receiptEvidence: (CoverageLevel, String)
            switch observation {
            case let .unavailable(message):
                receiptEvidence = (.unavailable, message)
            case let .gap(_, _, message):
                receiptEvidence = (.low, message)
            case .continuous:
                if receiptHasUnboundedCounter {
                    receiptEvidence = (
                        .low,
                        "Local token activity starts from an unbounded counter"
                    )
                } else if let filterGapReason {
                    receiptEvidence = (.partial, filterGapReason)
                } else {
                    receiptEvidence = hasMissingProject
                    ? (.partial, "Project metadata is missing")
                    : (.high, "Only local activity on this Mac is observed")
                }
            }
            return UsageReceipt(
                rootTaskID: rootTaskID,
                projectLabel: project,
                tokens: contributions.reduce(0) { $0 + $1.tokens },
                interval: selectedInterval,
                taskCount: Set(
                    contributions.compactMap { $0.context?.taskID }
                ).count,
                agents: Self.breakdown(contributions) {
                    guard let agent = $0.context?.agent else { return nil }
                    return agent.nickname ?? agent.role
                },
                turns: Self.breakdown(contributions) {
                    $0.context?.turnID
                },
                models: Self.breakdown(contributions) {
                    $0.context?.effectiveModel
                },
                reasoningLevels: Self.breakdown(contributions) {
                    $0.context?.reasoning
                },
                coverage: receiptEvidence.0,
                reason: receiptEvidence.1
            )
        }
        .sorted {
            ($0.projectLabel ?? "", $0.rootTaskID)
                < ($1.projectLabel ?? "", $1.rootTaskID)
        }
        let unattributed = tokenContributions
            .filter { $0.rootTaskID == nil }
            .reduce(0) { $0 + $1.tokens }
        let coverage: CoverageLevel
        let reason: String?
        switch observation {
        case .unavailable(let message):
            coverage = .unavailable
            reason = message
        case .gap(_, _, let message):
            coverage = .low
            reason = message
        case .continuous:
            if hasUnboundedCounter {
                coverage = .low
                reason = "Local token activity starts from an unbounded counter"
            } else if let filterGapReason {
                coverage = tokenContributions.isEmpty ? .low : .partial
                reason = filterGapReason
            } else if tokenContributions.isEmpty {
                coverage = .notApplicable
                reason = "No local token activity was observed"
            } else if unattributed > 0 || tokenContributions.contains(
                where: { $0.projectLabel == nil }
            ) {
                coverage = receipts.isEmpty ? .low : .partial
                reason = unattributed > 0
                    ? "Task metadata is missing"
                    : "Project metadata is missing"
            } else {
                coverage = .high
                reason = "Only local activity on this Mac is observed"
            }
        }
        return UsageReceiptSlice(
            receipts: receipts,
            totalTokens: total,
            unattributedTokens: unattributed,
            points: cumulativePoints(tokenContributions),
            coverage: coverage,
            reason: reason
        )
    }

    func filterOptions(
        in selectedInterval: DateInterval
    ) -> UsageReceiptFilterOptions {
        let selected = contributions.filter {
            Self.contains($0.date, in: selectedInterval) && $0.tokens > 0
        }
        return UsageReceiptFilterOptions(
            projects: Set(selected.compactMap(\.projectLabel)).sorted(),
            taskTrees: Set(selected.compactMap(\.rootTaskID)).sorted(),
            models: Set(
                selected.compactMap { $0.context?.effectiveModel }
            ).sorted(),
            reasoningLevels: Set(
                selected.compactMap { $0.context?.reasoning }
            ).sorted()
        )
    }

    fileprivate struct Contribution: Equatable, Sendable {
        let date: Date
        let tokens: Int64
        let rootTaskID: String?
        let projectLabel: String?
        let context: LocalActivityContext?
        let hasUnboundedCounter: Bool
    }

    private static func matches(
        _ contribution: Contribution,
        filters: WorkspaceFilters
    ) -> Bool {
        if let projectID = filters.projectID,
           contribution.projectLabel != projectID {
            return false
        }
        if let taskTreeID = filters.taskTreeID,
           contribution.rootTaskID != taskTreeID {
            return false
        }
        if let model = filters.model,
           contribution.context?.effectiveModel != model {
            return false
        }
        if let reasoning = filters.reasoning,
           contribution.context?.reasoning != reasoning {
            return false
        }
        return true
    }

    private static func contains(
        _ date: Date,
        in interval: DateInterval
    ) -> Bool {
        date >= interval.start && date < interval.end
    }

    private static func filterGapReason(
        in contributions: [Contribution],
        filters: WorkspaceFilters
    ) -> String? {
        if filters.projectID != nil,
           contributions.contains(where: { $0.projectLabel == nil }) {
            return "Some local activity has no Project metadata"
        }
        if filters.taskTreeID != nil,
           contributions.contains(where: { $0.rootTaskID == nil }) {
            return "Some local activity has no Task metadata"
        }
        if filters.model != nil,
           contributions.contains(where: {
               $0.context?.effectiveModel == nil
           }) {
            return "Some local activity has no model metadata"
        }
        if filters.reasoning != nil,
           contributions.contains(where: { $0.context?.reasoning == nil }) {
            return "Some local activity has no reasoning metadata"
        }
        return nil
    }

    private static func breakdown(
        _ contributions: [Contribution],
        label: (Contribution) -> String?
    ) -> [UsageReceiptBreakdown] {
        Dictionary(
            grouping: contributions.compactMap { contribution in
                label(contribution).map { ($0, contribution.tokens) }
            },
            by: \.0
        )
        .map { label, values in
            UsageReceiptBreakdown(
                label: label,
                tokens: values.reduce(0) { $0 + $1.1 }
            )
        }
        .sorted { $0.tokens == $1.tokens
            ? $0.label < $1.label
            : $0.tokens > $1.tokens
        }
    }

    private static func sum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private func cumulativePoints(
        _ contributions: [Contribution]
    ) -> [LocalTokenActivityPoint] {
        var total: Int64 = 0
        var points: [LocalTokenActivityPoint] = []
        for contribution in contributions.sorted(by: { $0.date < $1.date }) {
            total += contribution.tokens
            let point = LocalTokenActivityPoint(
                date: contribution.date,
                tokens: total
            )
            if points.last?.date == contribution.date {
                points[points.count - 1] = point
            } else {
                points.append(point)
            }
        }
        return points
    }
}

enum UsageReceiptAggregator {
    static func evaluate(
        facts: [LocalActivityFact],
        projections: [ThreadProjection],
        interval: DateInterval,
        observation: LocalActivityObservation
    ) -> UsageReceiptSnapshot {
        let projectionByTask = projections.reduce(
            into: [String: ThreadProjection]()
        ) {
            $0[$1.taskID] = $1
        }
        let rootTasks = Set(
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
        var contributions: [UsageReceiptSnapshot.Contribution] = []
        for fact in facts {
            guard fact.key == .token,
                  fact.availability == .available,
                  let eventID = fact.eventID,
                  seen.insert(eventID).inserted,
                  let timestamp = fact.eventTimestamp,
                  let date = timestampParser.date(from: timestamp),
                  date >= interval.start,
                  date < interval.end else {
                continue
            }
            let unboundedReasons = [
                "segment-baseline",
                "source-discontinuity",
                "cumulative-counter-decreased"
            ]
            let tokens: Int64
            let hasUnboundedCounter: Bool
            if let delta = fact.numericDelta, delta >= 0 {
                tokens = delta
                hasUnboundedCounter = false
            } else if let reason = fact.reason,
                      unboundedReasons.contains(reason) {
                tokens = 0
                hasUnboundedCounter = true
            } else {
                continue
            }
            let taskID = fact.context?.taskID
            let rootID = taskID.flatMap {
                Self.rootTaskID(
                    for: $0,
                    projections: projectionByTask,
                    knownRoots: rootTasks
                )
            }
            let projectLabel = rootID.flatMap {
                projectionByTask[$0]?.projectLabel
            }
            contributions.append(
                UsageReceiptSnapshot.Contribution(
                    date: date,
                    tokens: tokens,
                    rootTaskID: rootID,
                    projectLabel: projectLabel,
                    context: fact.context,
                    hasUnboundedCounter: hasUnboundedCounter
                )
            )
        }
        return UsageReceiptSnapshot(
            contributions: contributions,
            observation: observation,
            interval: interval
        )
    }

    private static func rootTaskID(
        for taskID: String,
        projections: [String: ThreadProjection],
        knownRoots: Set<String>
    ) -> String? {
        var current = taskID
        var visited = Set<String>()
        while visited.insert(current).inserted {
            if let projection = projections[current] {
                guard let parent = projection.parentTaskID else {
                    return current
                }
                current = parent
            } else {
                return knownRoots.contains(current) ? current : nil
            }
        }
        return nil
    }

}
