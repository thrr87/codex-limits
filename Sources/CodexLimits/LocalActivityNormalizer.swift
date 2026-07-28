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
    case time
    case effectiveModel
    case reasoning
    case tool
    case wait
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
}

struct LocalActivityNormalizationState: Codable, Equatable, Sendable {
    var sourceGeneration: UInt64
    var sourceVersion: String
    var historyMode: String?
    var lastTotalTokens: Int64?
    var tokenSegment: UInt64
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
            tokenSegment: 0
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
            state.tokenSegment += 1
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

        for record in records {
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
                        source: source
                    )
                )
                state.lastTotalTokens = totalTokens
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
                let isComplete = timing.completedAt != nil
                    && (timing.startedAt != nil || timing.durationMilliseconds != nil)
                facts.append(
                    LocalActivityFact(
                        key: .time,
                        availability: isComplete ? .available : .partial,
                        value: .turnTiming(timing),
                        numericDelta: nil,
                        tokenSegment: nil,
                        reason: isComplete ? nil : "turn-end-not-observed",
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source
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
                        source: source
                    )
                )
            }
            if record.type == "compacted" {
                facts.append(
                    available(
                        .compaction,
                        .count(1),
                        eventID: record.eventID,
                        eventTimestamp: record.timestamp,
                        source: source
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

    private func unavailableFacts(
        source: LocalActivitySourceMetadata
    ) -> [LocalActivityFact] {
        LocalActivityFactKey.allCases.map { key in
            unavailable(key, reason: unavailableReason(for: key), source: source)
        }
    }

    private func unavailableReason(for key: LocalActivityFactKey) -> String {
        switch key {
        case .wait:
            "no-universal-durable-wait-pair"
        case .tool:
            "durable-tool-events-are-incomplete"
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
