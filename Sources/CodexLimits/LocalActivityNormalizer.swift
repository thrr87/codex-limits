import Foundation

enum LocalActivitySourceKind: String, Codable, Equatable, Sendable {
    case rolloutJSONL = "codex-rollout-jsonl"
    case appServerThreadList = "codex-app-server-thread-list"
}

struct LocalActivitySourceMetadata: Codable, Equatable, Sendable {
    let source: LocalActivitySourceKind
    let sourceVersion: String
    let schemaVersion: String
    let sourceGeneration: UInt64
    let historyMode: String?
    let observedAt: Date
}

enum LocalActivityFactKey: String, Codable, CaseIterable, Equatable, Sendable {
    case task
    case root
    case parent
    case turn
    case agent
    case token
    case context
    case time
    case effectiveModel
    case reasoning
    case tool
    case execution
    case toolTime
    case wait
    case poll
    case compaction
}

enum LocalActivityAvailability: String, Codable, Equatable, Sendable {
    case available
    case partial
    case unavailable
}

enum LocalActivityFactValue: Codable, Equatable, Sendable {
    case identifier(String)
    case text(String)
    case count(Int64)
    case tokens(LocalTokenUsage)
    case agent(LocalAgentIdentity)
    case turnTiming(LocalTurnTiming)
    case duration(LocalActivityDuration)
}

struct LocalAgentIdentity: Codable, Equatable, Sendable {
    let nickname: String?
    let role: String?
}

struct LocalTurnTiming: Codable, Equatable, Sendable {
    let startedAt: Date?
    let completedAt: Date?
    let durationMilliseconds: Int64?
    let timeToFirstTokenMilliseconds: Int64?
}

struct LocalActivityDuration: Codable, Equatable, Sendable {
    let startedAt: Date
    let completedAt: Date
}

struct LocalActivityContext: Codable, Equatable, Sendable {
    let taskID: String?
    let turnID: String?
    let agent: LocalAgentIdentity?
    let effectiveModel: String?
    let reasoning: String?
    var modelContextWindow: Int64? = nil
}

struct LocalActivityFact: Codable, Equatable, Sendable {
    let key: LocalActivityFactKey
    let availability: LocalActivityAvailability
    let value: LocalActivityFactValue?
    let numericDelta: Int64?
    let tokenSegment: UInt64?
    let reason: String?
    let eventID: String?
    let eventTimestamp: String?
    let source: LocalActivitySourceMetadata
    var context: LocalActivityContext? = nil
    var tokenDelta: LocalTokenUsage? = nil
}

struct LocalActivityNormalizationState: Codable, Equatable, Sendable {
    var sourceGeneration: UInt64
    var sourceVersion: String
    var historyMode: String?
    var lastTotalTokens: Int64?
    var lastTokenUsage: LocalTokenUsage? = nil
    var tokenSegment: UInt64
    var context: LocalActivityContext? = nil
}

struct LocalActivityNormalizationResult: Equatable, Sendable {
    let source: LocalActivitySourceMetadata
    let facts: [LocalActivityFact]
    let state: LocalActivityNormalizationState

    func fact(_ key: LocalActivityFactKey) -> LocalActivityFact? {
        facts.last { $0.key == key }
    }

    func facts(_ key: LocalActivityFactKey) -> [LocalActivityFact] {
        facts.filter { $0.key == key }
    }
}

struct LocalActivityNormalizer {
    func normalize(
        records: [RolloutRecord],
        sourceGeneration: UInt64,
        observedAt: Date,
        previousState: LocalActivityNormalizationState? = nil
    ) -> LocalActivityNormalizationResult {
        var state = previousState ?? LocalActivityNormalizationState(
            sourceGeneration: sourceGeneration,
            sourceVersion: "unknown",
            historyMode: nil,
            lastTotalTokens: nil,
            tokenSegment: 0,
            context: nil
        )
        let observedVersion = records.lazy.compactMap(\.cliVersion).first
        let sourceChanged = previousState.map {
            $0.sourceGeneration != sourceGeneration
                || (observedVersion != nil
                    && $0.sourceVersion != "unknown"
                    && $0.sourceVersion != observedVersion)
        } ?? false
        if sourceChanged {
            state.lastTotalTokens = nil
            state.lastTokenUsage = nil
            state.tokenSegment += 1
            state.context = nil
        }
        state.sourceGeneration = sourceGeneration
        if let observedVersion {
            state.sourceVersion = observedVersion
        }
        if let historyMode = records.lazy.compactMap(\.historyMode).first {
            state.historyMode = historyMode
        }
        let source = LocalActivitySourceMetadata(
            source: .rolloutJSONL,
            sourceVersion: state.sourceVersion,
            schemaVersion: "rollout-v1",
            sourceGeneration: sourceGeneration,
            historyMode: state.historyMode,
            observedAt: observedAt
        )
        var facts = unavailableFacts(source: source)
        var currentTaskID = state.context?.taskID
        var currentTurnID = state.context?.turnID
        var currentAgent = state.context?.agent
        var currentModel = state.context?.effectiveModel
        var currentReasoning = state.context?.reasoning
        var currentModelContextWindow = state.context?.modelContextWindow

        for record in records {
            if let taskID = record.threadID {
                currentTaskID = taskID
            }
            if let turnID = record.turnID {
                currentTurnID = turnID
            }
            if record.agentNickname != nil || record.agentRole != nil {
                currentAgent = LocalAgentIdentity(
                    nickname: record.agentNickname,
                    role: record.agentRole
                )
            }
            if let model = record.model {
                currentModel = model
            }
            if let reasoning = record.reasoning {
                currentReasoning = reasoning
            }
            if let modelContextWindow = record.modelContextWindow {
                currentModelContextWindow = modelContextWindow
            }
            let context = LocalActivityContext(
                taskID: currentTaskID,
                turnID: currentTurnID,
                agent: currentAgent,
                effectiveModel: currentModel,
                reasoning: currentReasoning,
                modelContextWindow: currentModelContextWindow
            )
            state.context = context

            if record.type == "session_meta", let threadID = record.threadID {
                facts.append(
                    available(
                        .task,
                        .identifier(threadID),
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source
                    )
                )
                if let parentThreadID = record.parentThreadID {
                    facts.append(
                        available(
                            .parent,
                            .identifier(parentThreadID),
                            eventID: record.eventID,
                            eventTimestamp: record.timestamp,
                            source: source
                        )
                    )
                } else {
                    facts.append(
                        unavailable(.parent, reason: "root-task", source: source)
                    )
                    facts.append(
                        available(
                            .root,
                            .identifier(threadID),
                            eventID: record.eventID,
                            eventTimestamp: record.timestamp,
                            source: source
                        )
                    )
                }
                if record.agentNickname != nil || record.agentRole != nil {
                    facts.append(
                        available(
                            .agent,
                            .agent(
                                LocalAgentIdentity(
                                    nickname: record.agentNickname,
                                    role: record.agentRole
                                )
                            ),
                            eventID: record.eventID,
                            eventTimestamp: record.timestamp,
                            source: source
                        )
                    )
                }
            }

            if let turnID = record.turnID {
                facts.append(
                    available(
                        .turn,
                        .identifier(turnID),
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source
                    )
                )
            }
            if let model = record.model {
                facts.append(
                    available(
                        .effectiveModel,
                        .text(model),
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source
                    )
                )
            }
            if let reasoning = record.reasoning {
                facts.append(
                    available(
                        .reasoning,
                        .text(reasoning),
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source
                    )
                )
            }
            if let tokenUsage = record.tokenUsage {
                let totalTokens = tokenUsage.totalTokens
                let delta = state.lastTotalTokens.flatMap { previous in
                    totalTokens >= previous ? totalTokens - previous : nil
                }
                let reason: String?
                if state.lastTotalTokens == nil {
                    reason = sourceChanged ? "source-discontinuity" : "segment-baseline"
                } else if delta == nil {
                    reason = "cumulative-counter-decreased"
                    state.tokenSegment += 1
                } else {
                    reason = nil
                }
                facts.append(
                    LocalActivityFact(
                        key: .token,
                        availability: .available,
                        value: .tokens(tokenUsage),
                        numericDelta: delta,
                        tokenSegment: state.tokenSegment,
                        reason: reason,
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source,
                        context: context,
                        tokenDelta: state.lastTokenUsage.flatMap {
                            tokenDelta(from: $0, to: tokenUsage)
                        }
                    )
                )
                state.lastTotalTokens = totalTokens
                state.lastTokenUsage = tokenUsage
            }
            if let contextTokenUsage = record.contextTokenUsage {
                facts.append(
                    LocalActivityFact(
                        key: .context,
                        availability: .available,
                        value: .tokens(contextTokenUsage),
                        numericDelta: nil,
                        tokenSegment: nil,
                        reason: nil,
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source,
                        context: context
                    )
                )
            }
            if record.startedAt != nil
                || record.completedAt != nil
                || record.durationMilliseconds != nil
                || record.timeToFirstTokenMilliseconds != nil {
                let timing = LocalTurnTiming(
                    startedAt: record.startedAt.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    },
                    completedAt: record.completedAt.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    },
                    durationMilliseconds: record.durationMilliseconds,
                    timeToFirstTokenMilliseconds: record.timeToFirstTokenMilliseconds
                )
                let isComplete = timing.startedAt != nil
                    && timing.completedAt != nil
                let reason = timing.startedAt == nil
                    ? "turn-start-not-observed"
                    : timing.completedAt == nil
                        ? "turn-end-not-observed"
                        : nil
                facts.append(
                    LocalActivityFact(
                        key: .time,
                        availability: isComplete ? .available : .partial,
                        value: .turnTiming(timing),
                        numericDelta: nil,
                        tokenSegment: nil,
                        reason: reason,
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source,
                        context: context
                    )
                )
            }
            if let toolClass = record.toolClass {
                facts.append(
                    LocalActivityFact(
                        key: .tool,
                        availability: .partial,
                        value: .text(toolClass),
                        numericDelta: nil,
                        tokenSegment: nil,
                        reason: "durable-tool-events-are-incomplete",
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source,
                        context: context
                    )
                )
            }
            if record.type == "compacted" {
                facts.append(
                    LocalActivityFact(
                        key: .compaction,
                        availability: .available,
                        value: .count(1),
                        numericDelta: nil,
                        tokenSegment: nil,
                        reason: nil,
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source,
                        context: context
                    )
                )
            }
        }

        return LocalActivityNormalizationResult(
            source: source,
            facts: facts,
            state: state
        )
    }

    private func tokenDelta(
        from previous: LocalTokenUsage,
        to current: LocalTokenUsage
    ) -> LocalTokenUsage? {
        let observed = previous.observedComponents.intersection(
            current.observedComponents
        )
        guard observed.contains(.total),
              let total = difference(
                  current.totalTokens,
                  previous.totalTokens
              ) else {
            return nil
        }
        func component(
            _ key: LocalTokenComponent,
            _ currentValue: Int64,
            _ previousValue: Int64
        ) -> Int64? {
            guard observed.contains(key) else { return 0 }
            return difference(currentValue, previousValue)
        }
        guard
            let input = component(
                .input,
                current.inputTokens,
                previous.inputTokens
            ),
            let cached = component(
                .cachedInput,
                current.cachedInputTokens,
                previous.cachedInputTokens
            ),
            let cacheWrite = component(
                .cacheWriteInput,
                current.cacheWriteInputTokens,
                previous.cacheWriteInputTokens
            ),
            let output = component(
                .output,
                current.outputTokens,
                previous.outputTokens
            ),
            let reasoning = component(
                .reasoningOutput,
                current.reasoningOutputTokens,
                previous.reasoningOutputTokens
            )
        else {
            return nil
        }
        return LocalTokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total,
            observedComponents: observed
        )
    }

    private func difference(_ current: Int64, _ previous: Int64) -> Int64? {
        let result = current.subtractingReportingOverflow(previous)
        return result.overflow || result.partialValue < 0
            ? nil
            : result.partialValue
    }

    private func unavailableFacts(
        source: LocalActivitySourceMetadata
    ) -> [LocalActivityFact] {
        LocalActivityFactKey.allCases.map { key in
            unavailable(key, reason: unavailableReason(for: key), source: source)
        }
    }

    private func unavailableReason(for key: LocalActivityFactKey) -> String {
        switch key {
        case .wait, .poll:
            "no-universal-durable-wait-pair"
        case .tool, .toolTime:
            "durable-tool-events-are-incomplete"
        case .execution:
            "no-universal-durable-execution-pair"
        default:
            "not-observed"
        }
    }

    private func available(
        _ key: LocalActivityFactKey,
        _ value: LocalActivityFactValue,
        eventID: String,
        eventTimestamp: String?,
        source: LocalActivitySourceMetadata
    ) -> LocalActivityFact {
        LocalActivityFact(
            key: key,
            availability: .available,
            value: value,
            numericDelta: nil,
            tokenSegment: nil,
            reason: nil,
            eventID: eventID,
            eventTimestamp: eventTimestamp,
            source: source
        )
    }

    private func unavailable(
        _ key: LocalActivityFactKey,
        reason: String,
        source: LocalActivitySourceMetadata
    ) -> LocalActivityFact {
        LocalActivityFact(
            key: key,
            availability: .unavailable,
            value: nil,
            numericDelta: nil,
            tokenSegment: nil,
            reason: reason,
            eventID: nil,
            eventTimestamp: nil,
            source: source
        )
    }
}
