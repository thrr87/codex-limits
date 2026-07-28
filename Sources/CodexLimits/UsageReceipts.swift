import Foundation

struct UsageReceiptBreakdown: Equatable, Identifiable, Sendable {
    let label: String
    let tokens: Int64

    var id: String { label }
}

struct UsageReceiptTurn: Equatable, Identifiable, Sendable {
    let turnID: String
    let tokens: Int64
    let effectiveModels: [UsageReceiptBreakdown]
    let reasoningLevels: [UsageReceiptBreakdown]
    let tokenSources: [LocalActivitySourceKind]
    let coverage: CoverageLevel
    let reason: String?

    var id: String { turnID }

    var displayTurnID: String {
        String(turnID.prefix(8))
    }

    var effectiveModel: String? {
        effectiveModels.count == 1 ? effectiveModels[0].label : nil
    }

    var reasoning: String? {
        reasoningLevels.count == 1 ? reasoningLevels[0].label : nil
    }

    var accessibilityValue: String {
        var parts = [
            "Turn \(displayTurnID)",
            "\(tokens) local tokens"
        ]
        if let effectiveModel {
            parts.append("Effective model \(effectiveModel)")
        }
        if let reasoning {
            parts.append("Reasoning \(reasoning)")
        }
        parts.append("\(coverage.displayName) coverage")
        return parts.joined(separator: ", ")
    }
}

struct UsageReceiptTaskNode: Equatable, Identifiable, Sendable {
    let taskID: String
    let agent: LocalAgentIdentity?
    let directTokens: Int64
    let subtreeTokens: Int64
    let unattributedTurnTokens: Int64
    let turns: [UsageReceiptTurn]
    let children: [UsageReceiptTaskNode]
    let relationshipSource: LocalActivitySourceKind?
    let tokenSources: [LocalActivitySourceKind]
    let coverage: CoverageLevel
    let reason: String?

    var id: String { taskID }

    var displayTaskID: String {
        String(taskID.prefix(8))
    }

    var agentLabel: String? {
        agent?.nickname ?? agent?.role
    }

    var taskCount: Int {
        1 + children.reduce(0) { $0 + $1.taskCount }
    }

    var accessibilityValue: String {
        var parts = [
            agentLabel.map { "Agent \($0)" } ?? "Task \(displayTaskID)",
            "\(directTokens) direct local tokens",
            "\(subtreeTokens) local tokens in subtree",
            "\(children.count) child \(children.count == 1 ? "Task" : "Tasks")",
            "\(coverage.displayName) coverage"
        ]
        if let reason {
            parts.append(reason)
        }
        return parts.joined(separator: ", ")
    }
}

struct UsageReceipt: Equatable, Identifiable, Sendable {
    let rootTaskID: String
    let projectLabel: String?
    let tokens: Int64
    let interval: DateInterval
    let taskCount: Int
    let taskTree: UsageReceiptTaskNode
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
    let receiptCoverage: CoverageLevel
    let receiptReason: String?
}

struct UsageReceiptFilterOptions: Equatable, Sendable {
    let projects: [String]
    let taskTrees: [String]
    let models: [String]
    let reasoningLevels: [String]
}

struct UsageReceiptSnapshot: Equatable, Sendable {
    fileprivate let contributions: [Contribution]
    fileprivate let projections: [String: ThreadProjection]
    fileprivate let taskIDsByRoot: [String: Set<String>]
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
                reason: "Local token total is invalid",
                receiptCoverage: .unavailable,
                receiptReason: "Local token total is invalid"
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
                    : (
                        .partial,
                        "Task Tree may omit Review and Guardian Tasks"
                    )
                }
            }
            let taskTree = Self.taskTree(
                rootTaskID: rootTaskID,
                contributions: contributions,
                projections: projections,
                taskIDs: taskIDsByRoot[rootTaskID] ?? [],
                coverage: receiptEvidence.0,
                reason: receiptEvidence.1
            )
            return UsageReceipt(
                rootTaskID: rootTaskID,
                projectLabel: project,
                tokens: contributions.reduce(0) { $0 + $1.tokens },
                interval: selectedInterval,
                taskCount: taskTree.taskCount,
                taskTree: taskTree,
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
        let combinedReceiptEvidence = Self.receiptEvidence(receipts)
        return UsageReceiptSlice(
            receipts: receipts,
            totalTokens: total,
            unattributedTokens: unattributed,
            points: cumulativePoints(tokenContributions),
            coverage: coverage,
            reason: reason,
            receiptCoverage: combinedReceiptEvidence.0,
            receiptReason: combinedReceiptEvidence.1
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
        let tokenSource: LocalActivitySourceKind
        let hasUnboundedCounter: Bool
    }

    private static func taskTree(
        rootTaskID: String,
        contributions: [Contribution],
        projections: [String: ThreadProjection],
        taskIDs: Set<String>,
        coverage: CoverageLevel,
        reason: String?
    ) -> UsageReceiptTaskNode {
        let contributingTaskIDs = Set(
            contributions.compactMap { $0.context?.taskID }
        )
        let contributionsByTask = Dictionary(
            grouping: contributions.compactMap { contribution in
                contribution.context?.taskID.map {
                    ($0, contribution)
                }
            },
            by: \.0
        )
        var includedTaskIDs = taskIDs
        includedTaskIDs.insert(rootTaskID)
        for taskID in contributingTaskIDs {
            var current: String? = taskID
            var visited = Set<String>()
            while let value = current,
                  visited.insert(value).inserted {
                includedTaskIDs.insert(value)
                if value == rootTaskID { break }
                current = projections[value]?.parentTaskID
            }
        }
        let childLinks: [(parent: String, task: String)] =
            includedTaskIDs.compactMap { taskID in
                guard taskID != rootTaskID,
                      let parent = projections[taskID]?.parentTaskID,
                      includedTaskIDs.contains(parent) else {
                    return nil
                }
                return (parent, taskID)
            }
        let childrenByParent = Dictionary(
            grouping: childLinks,
            by: \.parent
        )

        func node(_ taskID: String) -> UsageReceiptTaskNode {
            let direct = (contributionsByTask[taskID] ?? []).map(\.1)
            let children = (childrenByParent[taskID] ?? [])
                .map(\.task)
                .sorted()
                .map(node)
            let directTokens = direct.reduce(0) { $0 + $1.tokens }
            let subtreeTokens = directTokens + children.reduce(0) {
                $0 + $1.subtreeTokens
            }
            let unattributedTurnTokens = direct
                .filter { $0.context?.turnID == nil }
                .reduce(0) { $0 + $1.tokens }
            let taskEvidence = Self.taskEvidence(
                contributions: direct,
                coverage: coverage,
                reason: reason
            )
            let turns = Dictionary(
                grouping: direct.compactMap { contribution in
                    contribution.context?.turnID.map {
                        ($0, contribution)
                    }
                },
                by: \.0
            )
            .map { turnID, values in
                let turnContributions = values.map(\.1)
                let turnEvidence = Self.turnEvidence(
                    contributions: turnContributions,
                    coverage: taskEvidence.0,
                    reason: taskEvidence.1
                )
                return UsageReceiptTurn(
                    turnID: turnID,
                    tokens: turnContributions.reduce(0) {
                        $0 + $1.tokens
                    },
                    effectiveModels: breakdown(turnContributions) {
                        $0.context?.effectiveModel
                    },
                    reasoningLevels: breakdown(turnContributions) {
                        $0.context?.reasoning
                    },
                    tokenSources: Array(
                        Set(turnContributions.map(\.tokenSource))
                    ).sorted { $0.rawValue < $1.rawValue },
                    coverage: turnEvidence.0,
                    reason: turnEvidence.1
                )
            }
            .sorted { $0.turnID < $1.turnID }
            let agent = direct.compactMap { $0.context?.agent }.first
            return UsageReceiptTaskNode(
                taskID: taskID,
                agent: agent,
                directTokens: directTokens,
                subtreeTokens: subtreeTokens,
                unattributedTurnTokens: unattributedTurnTokens,
                turns: turns,
                children: children,
                relationshipSource: projections[taskID]?.source.source,
                tokenSources: Array(Set(direct.map(\.tokenSource)))
                    .sorted { $0.rawValue < $1.rawValue },
                coverage: taskEvidence.0,
                reason: taskEvidence.1
            )
        }

        return node(rootTaskID)
    }

    private static func taskEvidence(
        contributions: [Contribution],
        coverage: CoverageLevel,
        reason: String?
    ) -> (CoverageLevel, String?) {
        guard coverage != .unavailable, coverage != .low else {
            return (coverage, reason)
        }
        if contributions.contains(where: {
            $0.tokens > 0 && $0.context?.turnID == nil
        }) {
            return (
                .partial,
                "Some local token activity has no Turn metadata"
            )
        }
        return (coverage, reason)
    }

    private static func turnEvidence(
        contributions: [Contribution],
        coverage: CoverageLevel,
        reason: String?
    ) -> (CoverageLevel, String?) {
        guard coverage != .unavailable, coverage != .low else {
            return (coverage, reason)
        }
        if contributions.contains(where: {
            $0.context?.effectiveModel == nil
        }) {
            return (.partial, "Effective model metadata is missing")
        }
        if contributions.contains(where: {
            $0.context?.reasoning == nil
        }) {
            return (.partial, "Reasoning metadata is missing")
        }
        return (coverage, reason)
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

    private static func receiptEvidence(
        _ receipts: [UsageReceipt]
    ) -> (CoverageLevel, String?) {
        for level in [
            CoverageLevel.unavailable,
            .low,
            .partial,
            .high,
            .complete,
            .notApplicable
        ] {
            if let receipt = receipts.first(where: {
                $0.coverage == level
            }) {
                return (level, receipt.reason)
            }
        }
        return (.notApplicable, "No Usage Receipts are available")
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
        var taskIDsByRoot: [String: Set<String>] = [:]
        for taskID in projectionByTask.keys {
            if let rootTaskID = Self.rootTaskID(
                for: taskID,
                projections: projectionByTask,
                knownRoots: rootTasks
            ) {
                taskIDsByRoot[rootTaskID, default: []].insert(taskID)
            }
        }
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
                    tokenSource: fact.source.source,
                    hasUnboundedCounter: hasUnboundedCounter
                )
            )
        }
        return UsageReceiptSnapshot(
            contributions: contributions,
            projections: projectionByTask,
            taskIDsByRoot: taskIDsByRoot,
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
