import Foundation

struct UsageReceiptBreakdown: Equatable, Identifiable, Sendable {
    let label: String
    let tokens: Int64

    var id: String { label }
}

struct UsageReceiptTokenDiagnostics: Equatable, Sendable {
    let inputTokens: Int64?
    let cachedInputTokens: Int64?
    let cacheWriteInputTokens: Int64?
    let outputTokens: Int64?
    let reasoningOutputTokens: Int64?
    let totalTokens: Int64

    var reconciles: Bool? {
        guard let inputTokens, let outputTokens else { return nil }
        let sum = inputTokens.addingReportingOverflow(outputTokens)
        return !sum.overflow && sum.partialValue == totalTokens
    }
}

struct UsageReceiptContextDiagnostics: Equatable, Sendable {
    let usedTokens: Int64
    let windowTokens: Int64?
    let observedAt: Date
    let peakTokens: Int64
    let changeTokens: Int64?
    let sampleCount: Int
}

struct UsageReceiptToolSummary: Equatable, Identifiable, Sendable {
    let toolClass: String
    let count: Int

    var id: String { toolClass }
}

struct UsageReceiptCompactionEvent: Equatable, Identifiable, Sendable {
    let eventID: String
    let date: Date

    var id: String { eventID }
}

struct UsageReceiptDurationDiagnostics: Equatable, Sendable {
    let elapsedMilliseconds: Int64?
    let executionMilliseconds: Int64?
    let toolMilliseconds: Int64?
    let waitingMilliseconds: Int64?
    let pollingMilliseconds: Int64?
    let unclassifiedMilliseconds: Int64?
    let reconciles: Bool?
}

struct UsageReceiptDiagnostics: Equatable, Sendable {
    let tokens: UsageReceiptTokenDiagnostics?
    let context: UsageReceiptContextDiagnostics?
    let tools: [UsageReceiptToolSummary]
    let compactions: [UsageReceiptCompactionEvent]
    let duration: UsageReceiptDurationDiagnostics
    let sources: [LocalActivitySourceKind]
    let coverage: CoverageLevel
    let reason: String?
}

struct UsageReceiptTurn: Equatable, Identifiable, Sendable {
    let turnID: String
    let tokens: Int64
    let effectiveModels: [UsageReceiptBreakdown]
    let reasoningLevels: [UsageReceiptBreakdown]
    let tokenSources: [LocalActivitySourceKind]
    let diagnostics: UsageReceiptDiagnostics
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
    let diagnostics: UsageReceiptDiagnostics
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

struct UsageReceiptSummary: Equatable, Identifiable, Sendable {
    let rootTaskID: String
    let projectLabel: String?
    let tokens: Int64
    let taskCount: Int
    let coverage: CoverageLevel
    let reason: String?

    var id: String { rootTaskID }

    var displayTaskID: String {
        String(rootTaskID.prefix(8))
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

struct UsageReceiptOverview: Equatable, Sendable {
    let receipts: [UsageReceiptSummary]
    let totalTokens: Int64
    let unattributedTokens: Int64
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
    fileprivate let diagnostics: [DiagnosticContribution]
    fileprivate let projections: [String: ThreadProjection]
    fileprivate let taskIDsByRoot: [String: Set<String>]
    fileprivate let observation: LocalActivityObservation
    let interval: DateInterval

    func updating(
        interval: DateInterval,
        observation: LocalActivityObservation
    ) -> UsageReceiptSnapshot {
        UsageReceiptSnapshot(
            contributions: contributions,
            diagnostics: diagnostics,
            projections: projections,
            taskIDsByRoot: taskIDsByRoot,
            observation: observation,
            interval: interval
        )
    }

    func overview(
        in selectedInterval: DateInterval,
        filters: WorkspaceFilters
    ) -> UsageReceiptOverview {
        var accumulators: [String: SummaryAccumulator] = [:]
        var totalTokens: Int64 = 0
        var unattributedTokens: Int64 = 0
        var totalOverflow = false
        var unattributedOverflow = false
        var hasUnboundedCounter = false
        var hasMissingProject = false
        var hasTokenContribution = false
        var contributionGaps = FilterGaps()
        var diagnosticGaps = FilterGaps()

        for contribution in contributions
        where Self.contains(contribution.date, in: selectedInterval) {
            contributionGaps.observe(
                Self.metadata(for: contribution),
                filters: filters
            )
            guard Self.matches(contribution, filters: filters) else {
                continue
            }
            hasUnboundedCounter =
                hasUnboundedCounter || contribution.hasUnboundedCounter
            guard !totalOverflow else { continue }
            let total = totalTokens.addingReportingOverflow(
                contribution.tokens
            )
            totalOverflow = total.overflow
            totalTokens = total.partialValue
            if let rootTaskID = contribution.rootTaskID {
                var accumulator = accumulators[rootTaskID]
                    ?? SummaryAccumulator()
                accumulator.hasUnboundedCounter =
                    accumulator.hasUnboundedCounter
                        || contribution.hasUnboundedCounter
                if contribution.tokens > 0 {
                    accumulator.add(contribution)
                }
                accumulators[rootTaskID] = accumulator
            }
            guard contribution.tokens > 0 else { continue }
            hasTokenContribution = true
            hasMissingProject =
                hasMissingProject || contribution.projectLabel == nil
            guard contribution.rootTaskID == nil else {
                continue
            }
            let unattributed = unattributedTokens.addingReportingOverflow(
                contribution.tokens
            )
            unattributedOverflow =
                unattributedOverflow || unattributed.overflow
            unattributedTokens = unattributed.partialValue
        }

        for diagnostic in diagnostics
        where diagnostic.intersects(selectedInterval) {
            diagnosticGaps.observe(
                Self.metadata(for: diagnostic),
                filters: filters
            )
            guard Self.matches(diagnostic, filters: filters),
                  let rootTaskID = diagnostic.rootTaskID else {
                continue
            }
            var accumulator = accumulators[rootTaskID]
                ?? SummaryAccumulator()
            accumulator.add(diagnostic)
            accumulators[rootTaskID] = accumulator
        }

        guard !totalOverflow, !unattributedOverflow,
              !accumulators.values.contains(where: \.tokensOverflow) else {
            return UsageReceiptOverview(
                receipts: [],
                totalTokens: 0,
                unattributedTokens: 0,
                coverage: .unavailable,
                reason: "Local token total is invalid",
                receiptCoverage: .unavailable,
                receiptReason: "Local token total is invalid"
            )
        }

        let filterGapReason = contributionGaps.reason(
            subject: "Some local activity",
            verb: "has"
        ) ?? diagnosticGaps.reason(
            subject: "Some local diagnostics",
            verb: "have"
        )
        let summaries: [UsageReceiptSummary] = accumulators.compactMap {
            rootTaskID, accumulator -> UsageReceiptSummary? in
            guard accumulator.hasReceiptEvidence else { return nil }
            let evidence = receiptEvidence(
                hasMissingProject: accumulator.hasMissingProject,
                hasUnboundedCounter: accumulator.hasUnboundedCounter,
                filterGapReason: filterGapReason
            )
            return UsageReceiptSummary(
                rootTaskID: rootTaskID,
                projectLabel: accumulator.projectLabel,
                tokens: accumulator.tokens,
                taskCount: max(
                    taskIDsByRoot[rootTaskID]?.count ?? 0,
                    1
                ),
                coverage: evidence.0,
                reason: evidence.1
            )
        }
        .sorted {
            ($0.projectLabel ?? "", $0.rootTaskID)
                < ($1.projectLabel ?? "", $1.rootTaskID)
        }
        let coverage = sliceEvidence(
            hasTokenContribution: hasTokenContribution,
            hasUnboundedCounter: hasUnboundedCounter,
            hasMissingProject: hasMissingProject,
            hasUnattributedTokens: unattributedTokens > 0,
            hasReceipts: !summaries.isEmpty,
            filterGapReason: filterGapReason
        )
        let combinedReceiptEvidence = Self.receiptEvidence(summaries)
        return UsageReceiptOverview(
            receipts: summaries,
            totalTokens: totalTokens,
            unattributedTokens: unattributedTokens,
            coverage: coverage.0,
            reason: coverage.1,
            receiptCoverage: combinedReceiptEvidence.0,
            receiptReason: combinedReceiptEvidence.1
        )
    }

    func receipt(
        rootTaskID: String,
        in selectedInterval: DateInterval,
        filters: WorkspaceFilters
    ) -> UsageReceipt? {
        return slice(
            in: selectedInterval,
            filters: filters,
            onlyRootTaskID: rootTaskID
        ).receipts.first
    }

    func localTokenSlice(
        in selectedInterval: DateInterval,
        filters: WorkspaceFilters
    ) -> LocalTokenActivitySlice {
        let overview = overview(
            in: selectedInterval,
            filters: filters
        )
        let selected = contributions.filter {
            Self.contains($0.date, in: selectedInterval)
                && $0.tokens > 0
                && Self.matches($0, filters: filters)
        }
        return LocalTokenActivitySlice(
            tokens: overview.totalTokens,
            points: cumulativePoints(selected),
            coverage: overview.coverage,
            reason: overview.reason
        )
    }

    func slice(
        in selectedInterval: DateInterval,
        filters: WorkspaceFilters
    ) -> UsageReceiptSlice {
        slice(
            in: selectedInterval,
            filters: filters,
            onlyRootTaskID: nil
        )
    }

    private func slice(
        in selectedInterval: DateInterval,
        filters: WorkspaceFilters,
        onlyRootTaskID: String?
    ) -> UsageReceiptSlice {
        var groupedContributions: [String: [Contribution]] = [:]
        var groupedDiagnostics: [String: [DiagnosticContribution]] = [:]
        var tokenContributions: [Contribution] = []
        var unboundedRoots = Set<String>()
        var totalTokens: Int64 = 0
        var unattributedTokens: Int64 = 0
        var totalOverflow = false
        var unattributedOverflow = false
        var hasUnboundedCounter = false
        var hasMissingProject = false
        var contributionGaps = FilterGaps()
        var diagnosticGaps = FilterGaps()

        for contribution in contributions
        where Self.contains(contribution.date, in: selectedInterval) {
            contributionGaps.observe(
                Self.metadata(for: contribution),
                filters: filters
            )
            guard Self.matches(contribution, filters: filters),
                  onlyRootTaskID == nil
                    || contribution.rootTaskID == onlyRootTaskID else {
                continue
            }
            let total = totalTokens.addingReportingOverflow(
                contribution.tokens
            )
            totalOverflow = totalOverflow || total.overflow
            totalTokens = total.partialValue
            hasUnboundedCounter =
                hasUnboundedCounter || contribution.hasUnboundedCounter
            if contribution.hasUnboundedCounter,
               let rootTaskID = contribution.rootTaskID {
                unboundedRoots.insert(rootTaskID)
            }
            guard contribution.tokens > 0 else { continue }
            tokenContributions.append(contribution)
            hasMissingProject =
                hasMissingProject || contribution.projectLabel == nil
            if let rootTaskID = contribution.rootTaskID {
                groupedContributions[rootTaskID, default: []]
                    .append(contribution)
            } else {
                let unattributed = unattributedTokens.addingReportingOverflow(
                    contribution.tokens
                )
                unattributedOverflow =
                    unattributedOverflow || unattributed.overflow
                unattributedTokens = unattributed.partialValue
            }
        }

        for diagnostic in diagnostics
        where diagnostic.intersects(selectedInterval) {
            diagnosticGaps.observe(
                Self.metadata(for: diagnostic),
                filters: filters
            )
            guard Self.matches(diagnostic, filters: filters),
                  onlyRootTaskID == nil
                    || diagnostic.rootTaskID == onlyRootTaskID,
                  let rootTaskID = diagnostic.rootTaskID else {
                continue
            }
            groupedDiagnostics[rootTaskID, default: []].append(diagnostic)
        }

        guard !totalOverflow, !unattributedOverflow,
              groupedContributions.values.allSatisfy({
                  Self.sum($0.lazy.map(\.tokens)) != nil
              }) else {
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
        let filterGapReason = contributionGaps.reason(
            subject: "Some local activity",
            verb: "has"
        ) ?? diagnosticGaps.reason(
            subject: "Some local diagnostics",
            verb: "have"
        )
        let rootTaskIDs = Set(groupedContributions.keys)
            .union(groupedDiagnostics.keys)
        let receipts = rootTaskIDs.map { rootTaskID in
            let contributions = groupedContributions[rootTaskID] ?? []
            let receiptDiagnostics = groupedDiagnostics[rootTaskID] ?? []
            let project = contributions.compactMap(\.projectLabel).first
                ?? receiptDiagnostics.compactMap(\.projectLabel).first
            let hasMissingProject = contributions.contains {
                $0.projectLabel == nil
            } || receiptDiagnostics.contains {
                $0.projectLabel == nil
            }
            let receiptEvidence = receiptEvidence(
                hasMissingProject: hasMissingProject,
                hasUnboundedCounter: unboundedRoots.contains(rootTaskID),
                filterGapReason: filterGapReason
            )
            let taskTree = Self.taskTree(
                rootTaskID: rootTaskID,
                contributions: contributions,
                projections: projections,
                taskIDs: taskIDsByRoot[rootTaskID] ?? [],
                diagnostics: receiptDiagnostics,
                selectedInterval: selectedInterval,
                observation: observation,
                coverage: receiptEvidence.0,
                reason: receiptEvidence.1
            )
            return UsageReceipt(
                rootTaskID: rootTaskID,
                projectLabel: project,
                tokens: Self.sum(
                    contributions.lazy.map(\.tokens)
                ) ?? 0,
                interval: selectedInterval,
                taskCount: taskTree.taskCount,
                taskTree: taskTree,
                models: Self.breakdown(contributions) {
                    $0.context?.effectiveModel
                },
                reasoningLevels: Self.breakdown(contributions) {
                    $0.context?.reasoning
                },
                diagnostics: Self.diagnosticSummary(
                    contributions,
                    receiptDiagnostics,
                    selectedInterval: selectedInterval,
                    observation: observation
                ),
                coverage: receiptEvidence.0,
                reason: receiptEvidence.1
            )
        }
        .sorted {
            ($0.projectLabel ?? "", $0.rootTaskID)
                < ($1.projectLabel ?? "", $1.rootTaskID)
        }
        let coverage = sliceEvidence(
            hasTokenContribution: !tokenContributions.isEmpty,
            hasUnboundedCounter: hasUnboundedCounter,
            hasMissingProject: hasMissingProject,
            hasUnattributedTokens: unattributedTokens > 0,
            hasReceipts: !receipts.isEmpty,
            filterGapReason: filterGapReason
        )
        let combinedReceiptEvidence = Self.receiptEvidence(receipts)
        return UsageReceiptSlice(
            receipts: receipts,
            totalTokens: totalTokens,
            unattributedTokens: unattributedTokens,
            points: cumulativePoints(tokenContributions),
            coverage: coverage.0,
            reason: coverage.1,
            receiptCoverage: combinedReceiptEvidence.0,
            receiptReason: combinedReceiptEvidence.1
        )
    }

    func filterOptions(
        in selectedInterval: DateInterval
    ) -> UsageReceiptFilterOptions {
        var projects = Set<String>()
        var taskTrees = Set<String>()
        var models = Set<String>()
        var reasoningLevels = Set<String>()
        for contribution in contributions
        where Self.contains(contribution.date, in: selectedInterval)
            && contribution.tokens > 0 {
            if let project = contribution.projectLabel {
                projects.insert(project)
            }
            if let taskTree = contribution.rootTaskID {
                taskTrees.insert(taskTree)
            }
            if let model = contribution.context?.effectiveModel {
                models.insert(model)
            }
            if let reasoning = contribution.context?.reasoning {
                reasoningLevels.insert(reasoning)
            }
        }
        for diagnostic in diagnostics
        where diagnostic.intersects(selectedInterval) {
            if let project = diagnostic.projectLabel {
                projects.insert(project)
            }
            if let taskTree = diagnostic.rootTaskID {
                taskTrees.insert(taskTree)
            }
            if let model = diagnostic.context?.effectiveModel {
                models.insert(model)
            }
            if let reasoning = diagnostic.context?.reasoning {
                reasoningLevels.insert(reasoning)
            }
        }
        return UsageReceiptFilterOptions(
            projects: projects.sorted(),
            taskTrees: taskTrees.sorted(),
            models: models.sorted(),
            reasoningLevels: reasoningLevels.sorted()
        )
    }

    fileprivate struct Contribution: Equatable, Sendable {
        let date: Date
        let tokens: Int64
        let rootTaskID: String?
        let projectLabel: String?
        let sharedContext: SharedContext?
        let tokenSource: LocalActivitySourceKind
        let hasUnboundedCounter: Bool
        let tokenDelta: LocalTokenUsage?
        let contextUsage: LocalTokenUsage?

        var context: LocalActivityContext? { sharedContext?.value }
    }

    fileprivate struct DiagnosticContribution: Equatable, Sendable {
        let date: Date
        let rootTaskID: String?
        let projectLabel: String?
        let sharedContext: SharedContext?
        let payload: DiagnosticPayload
        let eventID: String
        let source: LocalActivitySourceKind

        var context: LocalActivityContext? { sharedContext?.value }
        var key: LocalActivityFactKey { payload.key }
        var value: LocalActivityFactValue? { payload.value }
        func intersects(_ interval: DateInterval) -> Bool {
            if let durationInterval {
                return durationInterval.start < interval.end
                    && durationInterval.end > interval.start
            }
            if case let .turnTiming(timing) = value,
               let start = timing.startedAt,
               let end = timing.completedAt {
                return start < interval.end && end > interval.start
            }
            return UsageReceiptSnapshot.contains(date, in: interval)
        }

        var durationInterval: DateInterval? {
            guard let duration = payload.duration,
                  duration.completedAt > duration.startedAt else {
                return nil
            }
            return DateInterval(
                start: duration.startedAt,
                end: duration.completedAt
            )
        }
    }

    fileprivate final class SharedContext: Sendable, Equatable {
        let value: LocalActivityContext

        init(_ value: LocalActivityContext) {
            self.value = value
        }

        static func == (lhs: SharedContext, rhs: SharedContext) -> Bool {
            lhs.value == rhs.value
        }
    }

    fileprivate enum DiagnosticPayload: Equatable, Sendable {
        case context(LocalTokenUsage?)
        case time(LocalTurnTiming?)
        case tool(String?)
        case duration(LocalActivityFactKey, LocalActivityDuration?)
        case compaction

        var key: LocalActivityFactKey {
            switch self {
            case .context: .context
            case .time: .time
            case .tool: .tool
            case let .duration(key, _): key
            case .compaction: .compaction
            }
        }

        var value: LocalActivityFactValue? {
            switch self {
            case let .context(value):
                value.map(LocalActivityFactValue.tokens)
            case let .time(value):
                value.map(LocalActivityFactValue.turnTiming)
            case let .tool(value):
                value.map(LocalActivityFactValue.text)
            case let .duration(_, value):
                value.map(LocalActivityFactValue.duration)
            case .compaction:
                .count(1)
            }
        }

        var duration: LocalActivityDuration? {
            guard case let .duration(_, value) = self else { return nil }
            return value
        }
    }

    private struct FilterMetadata {
        let projectID: String?
        let taskTreeID: String?
        let model: String?
        let reasoning: String?
    }

    private enum FilterDimension: Equatable {
        case project
        case taskTree
        case model
        case reasoning
    }

    private struct FilterGaps {
        var project = false
        var taskTree = false
        var model = false
        var reasoning = false

        mutating func observe(
            _ metadata: FilterMetadata,
            filters: WorkspaceFilters
        ) {
            if filters.projectID != nil,
               metadata.projectID == nil,
               UsageReceiptSnapshot.couldMatch(
                   metadata,
                   filters: filters,
                   ignoring: .project
               ) {
                project = true
            }
            if filters.taskTreeID != nil,
               metadata.taskTreeID == nil,
               UsageReceiptSnapshot.couldMatch(
                   metadata,
                   filters: filters,
                   ignoring: .taskTree
               ) {
                taskTree = true
            }
            if filters.model != nil,
               metadata.model == nil,
               UsageReceiptSnapshot.couldMatch(
                   metadata,
                   filters: filters,
                   ignoring: .model
               ) {
                model = true
            }
            if filters.reasoning != nil,
               metadata.reasoning == nil,
               UsageReceiptSnapshot.couldMatch(
                   metadata,
                   filters: filters,
                   ignoring: .reasoning
               ) {
                reasoning = true
            }
        }

        func reason(subject: String, verb: String) -> String? {
            if project {
                return "\(subject) \(verb) no Project metadata"
            }
            if taskTree {
                return "\(subject) \(verb) no Task metadata"
            }
            if model {
                return "\(subject) \(verb) no model metadata"
            }
            if reasoning {
                return "\(subject) \(verb) no reasoning metadata"
            }
            return nil
        }
    }

    private struct SummaryAccumulator {
        var projectLabel: String?
        var tokens: Int64 = 0
        var tokensOverflow = false
        var hasMissingProject = false
        var hasUnboundedCounter = false
        var hasReceiptEvidence = false

        mutating func add(_ contribution: Contribution) {
            hasReceiptEvidence = true
            projectLabel = projectLabel ?? contribution.projectLabel
            hasMissingProject =
                hasMissingProject || contribution.projectLabel == nil
            let result = tokens.addingReportingOverflow(contribution.tokens)
            tokensOverflow = tokensOverflow || result.overflow
            tokens = result.partialValue
        }

        mutating func add(_ diagnostic: DiagnosticContribution) {
            hasReceiptEvidence = true
            projectLabel = projectLabel ?? diagnostic.projectLabel
            hasMissingProject =
                hasMissingProject || diagnostic.projectLabel == nil
        }
    }

    private static func metadata(
        for contribution: Contribution
    ) -> FilterMetadata {
        FilterMetadata(
            projectID: contribution.projectLabel,
            taskTreeID: contribution.rootTaskID,
            model: contribution.context?.effectiveModel,
            reasoning: contribution.context?.reasoning
        )
    }

    private static func metadata(
        for diagnostic: DiagnosticContribution
    ) -> FilterMetadata {
        FilterMetadata(
            projectID: diagnostic.projectLabel,
            taskTreeID: diagnostic.rootTaskID,
            model: diagnostic.context?.effectiveModel,
            reasoning: diagnostic.context?.reasoning
        )
    }

    private func receiptEvidence(
        hasMissingProject: Bool,
        hasUnboundedCounter: Bool,
        filterGapReason: String?
    ) -> (CoverageLevel, String) {
        switch observation {
        case let .unavailable(message):
            return (.unavailable, message)
        case let .gap(_, _, message):
            return (.low, message)
        case .continuous:
            if hasUnboundedCounter {
                return (
                    .low,
                    "Local token activity starts from an unbounded counter"
                )
            }
            if let filterGapReason {
                return (.partial, filterGapReason)
            }
            if hasMissingProject {
                return (.partial, "Project metadata is missing")
            }
            return (
                .partial,
                "Task Tree may omit Review and Guardian Tasks"
            )
        }
    }

    private func sliceEvidence(
        hasTokenContribution: Bool,
        hasUnboundedCounter: Bool,
        hasMissingProject: Bool,
        hasUnattributedTokens: Bool,
        hasReceipts: Bool,
        filterGapReason: String?
    ) -> (CoverageLevel, String?) {
        switch observation {
        case let .unavailable(message):
            return (.unavailable, message)
        case let .gap(_, _, message):
            return (.low, message)
        case .continuous:
            if hasUnboundedCounter {
                return (
                    .low,
                    "Local token activity starts from an unbounded counter"
                )
            }
            if let filterGapReason {
                return (
                    hasTokenContribution ? .partial : .low,
                    filterGapReason
                )
            }
            if !hasTokenContribution {
                return (
                    .notApplicable,
                    "No local token activity was observed"
                )
            }
            if hasUnattributedTokens || hasMissingProject {
                return (
                    hasReceipts ? .partial : .low,
                    hasUnattributedTokens
                        ? "Task metadata is missing"
                        : "Project metadata is missing"
                )
            }
            return (.high, "Only local activity on this Mac is observed")
        }
    }

    private static func taskTree(
        rootTaskID: String,
        contributions: [Contribution],
        projections: [String: ThreadProjection],
        taskIDs: Set<String>,
        diagnostics: [DiagnosticContribution],
        selectedInterval: DateInterval,
        observation: LocalActivityObservation,
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
            let directDiagnostics = diagnostics.filter {
                $0.context?.taskID == taskID
            }
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
            let turnContributions = Dictionary(
                grouping: direct.compactMap { contribution in
                    contribution.context?.turnID.map {
                        ($0, contribution)
                    }
                },
                by: \.0
            )
            let turnDiagnostics = Dictionary(
                grouping: directDiagnostics.compactMap { diagnostic in
                    diagnostic.context?.turnID.map { ($0, diagnostic) }
                },
                by: \.0
            )
            let turnIDs = Set(turnContributions.keys)
                .union(turnDiagnostics.keys)
            let turns = turnIDs.map { turnID in
                let turnContributions = (turnContributions[turnID] ?? [])
                    .map(\.1)
                let diagnostics = (turnDiagnostics[turnID] ?? []).map(\.1)
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
                    diagnostics: diagnosticSummary(
                        turnContributions,
                        diagnostics,
                        selectedInterval: selectedInterval,
                        observation: observation
                    ),
                    coverage: turnEvidence.0,
                    reason: turnEvidence.1
                )
            }
            .sorted { $0.turnID < $1.turnID }
            let agent = direct.compactMap { $0.context?.agent }.first
                ?? directDiagnostics.compactMap { $0.context?.agent }.first
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

    private static func matches(
        _ diagnostic: DiagnosticContribution,
        filters: WorkspaceFilters
    ) -> Bool {
        if let projectID = filters.projectID,
           diagnostic.projectLabel != projectID {
            return false
        }
        if let taskTreeID = filters.taskTreeID,
           diagnostic.rootTaskID != taskTreeID {
            return false
        }
        if let model = filters.model,
           diagnostic.context?.effectiveModel != model {
            return false
        }
        if let reasoning = filters.reasoning,
           diagnostic.context?.reasoning != reasoning {
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
        filterGapReason(
            in: contributions.map {
                FilterMetadata(
                    projectID: $0.projectLabel,
                    taskTreeID: $0.rootTaskID,
                    model: $0.context?.effectiveModel,
                    reasoning: $0.context?.reasoning
                )
            },
            filters: filters,
            subject: "Some local activity",
            verb: "has"
        )
    }

    private static func filterGapReason(
        in diagnostics: [DiagnosticContribution],
        filters: WorkspaceFilters
    ) -> String? {
        filterGapReason(
            in: diagnostics.map {
                FilterMetadata(
                    projectID: $0.projectLabel,
                    taskTreeID: $0.rootTaskID,
                    model: $0.context?.effectiveModel,
                    reasoning: $0.context?.reasoning
                )
            },
            filters: filters,
            subject: "Some local diagnostics",
            verb: "have"
        )
    }

    private static func filterGapReason(
        in metadata: [FilterMetadata],
        filters: WorkspaceFilters,
        subject: String,
        verb: String
    ) -> String? {
        if filters.projectID != nil,
           metadata.contains(where: {
               $0.projectID == nil
                   && couldMatch(
                       $0,
                       filters: filters,
                       ignoring: .project
                   )
           }) {
            return "\(subject) \(verb) no Project metadata"
        }
        if filters.taskTreeID != nil,
           metadata.contains(where: {
               $0.taskTreeID == nil
                   && couldMatch(
                       $0,
                       filters: filters,
                       ignoring: .taskTree
                   )
           }) {
            return "\(subject) \(verb) no Task metadata"
        }
        if filters.model != nil,
           metadata.contains(where: {
               $0.model == nil
                   && couldMatch(
                       $0,
                       filters: filters,
                       ignoring: .model
                   )
           }) {
            return "\(subject) \(verb) no model metadata"
        }
        if filters.reasoning != nil,
           metadata.contains(where: {
               $0.reasoning == nil
                   && couldMatch(
                       $0,
                       filters: filters,
                       ignoring: .reasoning
                   )
           }) {
            return "\(subject) \(verb) no reasoning metadata"
        }
        return nil
    }

    private static func couldMatch(
        _ metadata: FilterMetadata,
        filters: WorkspaceFilters,
        ignoring dimension: FilterDimension
    ) -> Bool {
        if dimension != .project,
           let selected = filters.projectID,
           let observed = metadata.projectID,
           selected != observed {
            return false
        }
        if dimension != .taskTree,
           let selected = filters.taskTreeID,
           let observed = metadata.taskTreeID,
           selected != observed {
            return false
        }
        if dimension != .model,
           let selected = filters.model,
           let observed = metadata.model,
           selected != observed {
            return false
        }
        if dimension != .reasoning,
           let selected = filters.reasoning,
           let observed = metadata.reasoning,
           selected != observed {
            return false
        }
        return true
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

    private static func diagnosticSummary(
        _ contributions: [Contribution],
        _ diagnostics: [DiagnosticContribution],
        selectedInterval: DateInterval,
        observation: LocalActivityObservation
    ) -> UsageReceiptDiagnostics {
        let tokenDeltas = contributions.compactMap(\.tokenDelta)
        let tokenTotals = tokenDeltas.isEmpty
            ? nil
            : tokenDiagnostics(tokenDeltas)
        let contextSamples = (
            contributions.compactMap { contribution in
                contribution.contextUsage.map {
                    (
                        contribution.date,
                        $0.totalTokens,
                        contribution.context?.modelContextWindow
                    )
                }
            }
            + diagnostics
            .filter { $0.key == .context }
            .compactMap { diagnostic -> (Date, Int64, Int64?)? in
                guard case let .tokens(usage) = diagnostic.value else {
                    return nil
                }
                return (
                    diagnostic.date,
                    usage.totalTokens,
                    diagnostic.context?.modelContextWindow
                )
            }
        )
        .sorted { $0.0 < $1.0 }
        let context = contextSamples.last.map { last in
            UsageReceiptContextDiagnostics(
                usedTokens: last.1,
                windowTokens: last.2,
                observedAt: last.0,
                peakTokens: contextSamples.map(\.1).max() ?? last.1,
                changeTokens: contextSamples.count > 1
                    ? safeDifference(last.1, contextSamples[0].1)
                    : nil,
                sampleCount: contextSamples.count
            )
        }
        let toolCounts = Dictionary(
            grouping: diagnostics.compactMap { diagnostic -> String? in
                guard diagnostic.key == .tool,
                      case let .text(toolClass) = diagnostic.value else {
                    return nil
                }
                return toolClass
            },
            by: { $0 }
        )
        let tools = toolCounts.map {
            UsageReceiptToolSummary(
                toolClass: $0.key,
                count: $0.value.count
            )
        }
        .sorted {
            $0.count == $1.count
                ? $0.toolClass < $1.toolClass
                : $0.count > $1.count
        }
        let compactions: [UsageReceiptCompactionEvent] = diagnostics.compactMap {
            guard $0.key == .compaction else { return nil }
            return UsageReceiptCompactionEvent(
                eventID: $0.eventID,
                date: $0.date
            )
        }
        .sorted { $0.date < $1.date }
        let duration = durationDiagnostics(
            diagnostics,
            selectedInterval: selectedInterval
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
            if duration.reconciles == false {
                coverage = .low
                reason = "Recorded activity exceeds observed Turn time"
            } else if tokenTotals?.reconciles == false {
                coverage = .low
                reason = "Token components do not match total"
            } else if diagnostics.isEmpty && contributions.isEmpty {
                coverage = .unavailable
                reason = "No local diagnostics were observed"
            } else {
                coverage = .partial
                reason = "Some local diagnostics are not recorded by this Codex version"
            }
        }
        return UsageReceiptDiagnostics(
            tokens: tokenTotals,
            context: context,
            tools: tools,
            compactions: compactions,
            duration: duration,
            sources: Array(
                Set(diagnostics.map(\.source))
                    .union(contributions.map(\.tokenSource))
            )
                .sorted { $0.rawValue < $1.rawValue },
            coverage: coverage,
            reason: reason
        )
    }

    private static func tokenDiagnostics(
        _ values: [LocalTokenUsage]
    ) -> UsageReceiptTokenDiagnostics? {
        guard let total = sum(values.map(\.totalTokens)) else { return nil }
        func component(
            _ component: LocalTokenComponent,
            _ value: KeyPath<LocalTokenUsage, Int64>
        ) -> Int64? {
            guard values.allSatisfy({
                $0.observes(component)
            }) else {
                return nil
            }
            return sum(values.map { $0[keyPath: value] })
        }
        return UsageReceiptTokenDiagnostics(
            inputTokens: component(.input, \.inputTokens),
            cachedInputTokens: component(
                .cachedInput,
                \.cachedInputTokens
            ),
            cacheWriteInputTokens: component(
                .cacheWriteInput,
                \.cacheWriteInputTokens
            ),
            outputTokens: component(.output, \.outputTokens),
            reasoningOutputTokens: component(
                .reasoningOutput,
                \.reasoningOutputTokens
            ),
            totalTokens: total
        )
    }

    private static func safeDifference(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64? {
        let result = lhs.subtractingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func durationDiagnostics(
        _ diagnostics: [DiagnosticContribution],
        selectedInterval: DateInterval
    ) -> UsageReceiptDurationDiagnostics {
        let elapsedIntervals = diagnostics.compactMap {
            diagnostic -> DateInterval? in
                guard diagnostic.key == .time,
                      case let .turnTiming(timing) = diagnostic.value,
                      let start = timing.startedAt,
                      let end = timing.completedAt,
                      end > start else {
                    return nil
                }
                return DateInterval(start: start, end: end)
            }
        let elapsed = intervalMilliseconds(
            elapsedIntervals,
            clippedTo: selectedInterval
        )
        func categoryIntervals(
            _ key: LocalActivityFactKey
        ) -> [DateInterval] {
            diagnostics.filter { $0.key == key }
                .compactMap(\.durationInterval)
        }
        func category(_ intervals: [DateInterval]) -> Int64? {
            guard !intervals.isEmpty else { return nil }
            return intervalMilliseconds(
                intervals,
                clippedTo: selectedInterval
            )
        }
        let executionIntervals = categoryIntervals(.execution)
        let toolIntervals = categoryIntervals(.toolTime)
        let waitingIntervals = categoryIntervals(.wait)
        let pollingIntervals = categoryIntervals(.poll)
        let execution = category(executionIntervals)
        let tool = category(toolIntervals)
        let waiting = category(waitingIntervals)
        let polling = category(pollingIntervals)
        let allCategoryIntervals = executionIntervals
            + toolIntervals
            + waitingIntervals
            + pollingIntervals
        let covered = intervalMilliseconds(
            allCategoryIntervals,
            clippedTo: selectedInterval
        )
        let coveredInsideElapsed = intervalMilliseconds(
            allCategoryIntervals.flatMap { category in
                elapsedIntervals.compactMap { elapsed -> DateInterval? in
                    let start = max(category.start, elapsed.start)
                    let end = min(category.end, elapsed.end)
                    return end > start
                        ? DateInterval(start: start, end: end)
                        : nil
                }
            },
            clippedTo: selectedInterval
        )
        let reconciliation: (unclassified: Int64?, reconciles: Bool?)
        if let elapsed, let covered {
            if covered <= elapsed,
               coveredInsideElapsed == covered {
                reconciliation = (elapsed - covered, true)
            } else {
                reconciliation = (nil, false)
            }
        } else {
            reconciliation = (nil, nil)
        }
        return UsageReceiptDurationDiagnostics(
            elapsedMilliseconds: elapsed,
            executionMilliseconds: execution,
            toolMilliseconds: tool,
            waitingMilliseconds: waiting,
            pollingMilliseconds: polling,
            unclassifiedMilliseconds: reconciliation.unclassified,
            reconciles: reconciliation.reconciles
        )
    }

    private static func intervalMilliseconds(
        _ intervals: [DateInterval],
        clippedTo bounds: DateInterval
    ) -> Int64? {
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.start, bounds.start)
            let end = min(interval.end, bounds.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }
        .sorted { $0.start < $1.start }
        guard var current = clipped.first else { return nil }
        var seconds: TimeInterval = 0
        for interval in clipped.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(
                    start: current.start,
                    end: max(current.end, interval.end)
                )
            } else {
                seconds += current.duration
                current = interval
            }
        }
        seconds += current.duration
        let milliseconds = seconds * 1_000
        guard milliseconds.isFinite,
              milliseconds <= Double(Int64.max) else {
            return nil
        }
        return Int64(milliseconds.rounded())
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

    private static func receiptEvidence(
        _ receipts: [UsageReceiptSummary]
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
            let addition = total.addingReportingOverflow(
                contribution.tokens
            )
            guard !addition.overflow else { return [] }
            total = addition.partialValue
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
        var sharedContexts: [
            LocalActivityContext: UsageReceiptSnapshot.SharedContext
        ] = [:]
        func sharedContext(
            _ context: LocalActivityContext?
        ) -> UsageReceiptSnapshot.SharedContext? {
            guard let context else { return nil }
            if let existing = sharedContexts[context] {
                return existing
            }
            let shared = UsageReceiptSnapshot.SharedContext(context)
            sharedContexts[context] = shared
            return shared
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
                  date >= interval.start else {
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
                    sharedContext: sharedContext(fact.context),
                    tokenSource: fact.source.source,
                    hasUnboundedCounter: hasUnboundedCounter,
                    tokenDelta: fact.tokenDelta,
                    contextUsage: fact.contextUsage
                )
            )
        }
        var seenDiagnostics = Set<String>()
        var diagnostics: [UsageReceiptSnapshot.DiagnosticContribution] = []
        let diagnosticKeys: Set<LocalActivityFactKey> = [
            .context,
            .time,
            .tool,
            .execution,
            .toolTime,
            .wait,
            .poll,
            .compaction
        ]
        for fact in facts {
            guard diagnosticKeys.contains(fact.key),
                  fact.availability != .unavailable,
                  let eventID = fact.eventID,
                  seenDiagnostics.insert("\(fact.key.rawValue)|\(eventID)").inserted,
                  let timestamp = fact.eventTimestamp,
                  let date = timestampParser.date(from: timestamp) else {
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
            guard let payload = diagnosticPayload(for: fact) else {
                continue
            }
            let diagnostic = UsageReceiptSnapshot.DiagnosticContribution(
                date: date,
                rootTaskID: rootID,
                projectLabel: projectLabel,
                sharedContext: sharedContext(fact.context),
                payload: payload,
                eventID: eventID,
                source: fact.source.source
            )
            guard diagnostic.intersects(
                DateInterval(start: interval.start, end: .distantFuture)
            ) else {
                continue
            }
            diagnostics.append(diagnostic)
        }
        return UsageReceiptSnapshot(
            contributions: contributions,
            diagnostics: diagnostics,
            projections: projectionByTask,
            taskIDsByRoot: taskIDsByRoot,
            observation: observation,
            interval: interval
        )
    }

    private static func diagnosticPayload(
        for fact: LocalActivityFact
    ) -> UsageReceiptSnapshot.DiagnosticPayload? {
        switch fact.key {
        case .context:
            guard case let .tokens(usage) = fact.value else {
                return .context(nil)
            }
            return .context(usage)
        case .time:
            guard case let .turnTiming(timing) = fact.value else {
                return .time(nil)
            }
            return .time(timing)
        case .tool:
            guard case let .text(toolClass) = fact.value else {
                return .tool(nil)
            }
            return .tool(toolClass)
        case .execution, .toolTime, .wait, .poll:
            guard case let .duration(duration) = fact.value else {
                return .duration(fact.key, nil)
            }
            return .duration(fact.key, duration)
        case .compaction:
            return .compaction
        default:
            return nil
        }
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
