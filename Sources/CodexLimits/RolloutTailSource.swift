import Foundation

enum RolloutTailSourceError: Error, Equatable {
    case missingFileMetadata
}

struct RolloutFileIdentity: Codable, Equatable, Hashable, Sendable {
    let systemNumber: UInt64
    let fileNumber: UInt64
}

struct RolloutCheckpoint: Codable, Equatable, Sendable {
    let byteOffset: UInt64
    let byteLength: UInt64
    let threadID: String?
    let fingerprint: UInt64
}

struct RolloutCursor: Codable, Equatable, Sendable {
    let fileIdentity: RolloutFileIdentity
    let sourceGeneration: UInt64
    let byteOffset: UInt64
    let fileSize: UInt64
    let modificationTime: Date
    let lastOrdinal: UInt64?
    let threadID: String?
    let processedPrefixFingerprint: UInt64?
    let checkpoint: RolloutCheckpoint?
}

enum LocalTokenComponent: String, Codable, CaseIterable, Sendable {
    case input
    case cachedInput
    case cacheWriteInput
    case output
    case reasoningOutput
    case total
}

struct LocalTokenUsage: Codable, Equatable, Sendable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
    var observedComponents: Set<LocalTokenComponent> = Set(
        LocalTokenComponent.allCases
    )

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case cachedInputTokens
        case cacheWriteInputTokens
        case outputTokens
        case reasoningOutputTokens
        case totalTokens
        case observedComponents
    }

    init(
        inputTokens: Int64,
        cachedInputTokens: Int64,
        cacheWriteInputTokens: Int64,
        outputTokens: Int64,
        reasoningOutputTokens: Int64,
        totalTokens: Int64,
        observedComponents: Set<LocalTokenComponent> = Set(
            LocalTokenComponent.allCases
        )
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.observedComponents = observedComponents
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try values.decode(Int64.self, forKey: .inputTokens)
        cachedInputTokens = try values.decode(
            Int64.self,
            forKey: .cachedInputTokens
        )
        cacheWriteInputTokens = try values.decode(
            Int64.self,
            forKey: .cacheWriteInputTokens
        )
        outputTokens = try values.decode(Int64.self, forKey: .outputTokens)
        reasoningOutputTokens = try values.decode(
            Int64.self,
            forKey: .reasoningOutputTokens
        )
        totalTokens = try values.decode(Int64.self, forKey: .totalTokens)
        observedComponents = try values.decodeIfPresent(
            [LocalTokenComponent].self,
            forKey: .observedComponents
        ).map(Set.init) ?? [.total]
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(inputTokens, forKey: .inputTokens)
        try values.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try values.encode(
            cacheWriteInputTokens,
            forKey: .cacheWriteInputTokens
        )
        try values.encode(outputTokens, forKey: .outputTokens)
        try values.encode(
            reasoningOutputTokens,
            forKey: .reasoningOutputTokens
        )
        try values.encode(totalTokens, forKey: .totalTokens)
        try values.encode(
            observedComponents.sorted { $0.rawValue < $1.rawValue },
            forKey: .observedComponents
        )
    }
}

struct RolloutRecord: Equatable, Sendable {
    let eventID: String
    let ordinal: UInt64?
    let timestamp: String?
    let type: String
    let eventType: String?
    let threadID: String?
    let parentThreadID: String?
    let cliVersion: String?
    let historyMode: String?
    let agentRole: String?
    let agentNickname: String?
    let turnID: String?
    let model: String?
    let reasoning: String?
    let tokenUsage: LocalTokenUsage?
    let contextTokenUsage: LocalTokenUsage?
    let modelContextWindow: Int64?
    let startedAt: Int64?
    let completedAt: Int64?
    let durationMilliseconds: Int64?
    let timeToFirstTokenMilliseconds: Int64?
    let toolClass: String?

    var totalTokens: Int64? { tokenUsage?.totalTokens }
}

struct RolloutTailBatch: Equatable, Sendable {
    let records: [RolloutRecord]
    let cursor: RolloutCursor
    let bytesRead: UInt64
    let unsupportedRecordCount: Int
    let malformedRecordCount: Int
    let requiresRebuild: Bool
}

struct IncrementalRolloutTailSource {
    private static let fingerprintOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fingerprintPrime: UInt64 = 1_099_511_628_211

    func read(
        fileURL: URL,
        cursor: RolloutCursor?,
        observedAt: Date
    ) throws -> RolloutTailBatch {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard
            let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
            let modificationTime = attributes[.modificationDate] as? Date
        else {
            throw RolloutTailSourceError.missingFileMetadata
        }
        let identity = RolloutFileIdentity(
            systemNumber: systemNumber,
            fileNumber: fileNumber
        )
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let sameFileIdentity = cursor?.fileIdentity == identity
        let metadataUnchanged = cursor.map {
            sameFileIdentity
                && fileSize == $0.fileSize
                && modificationTime == $0.modificationTime
        } ?? false
        let continuationVerification: (matches: Bool, bytesRead: Int)
        if metadataUnchanged {
            continuationVerification = (true, 0)
        } else if sameFileIdentity {
            continuationVerification = try verifiedCheckpoint(
                handle: handle,
                fileSize: fileSize,
                cursor: cursor
            )
        } else {
            continuationVerification = try verifiedPrefix(
                handle: handle,
                fileSize: fileSize,
                cursor: cursor
            )
        }
        let continuesSource = continuationVerification.matches
        let startOffset = continuesSource ? cursor?.byteOffset ?? 0 : 0
        let requiresRebuild = cursor != nil && !continuesSource
        let sourceGeneration: UInt64
        if let cursor {
            sourceGeneration = sameFileIdentity && continuesSource
                ? cursor.sourceGeneration
                : cursor.sourceGeneration + 1
        } else {
            sourceGeneration = 0
        }

        try handle.seek(toOffset: startOffset)
        let data = try handle.readToEnd() ?? Data()
        let bytesRead = UInt64(continuationVerification.bytesRead + data.count)

        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return RolloutTailBatch(
                records: [],
                cursor: RolloutCursor(
                    fileIdentity: identity,
                    sourceGeneration: sourceGeneration,
                    byteOffset: startOffset,
                    fileSize: fileSize,
                    modificationTime: modificationTime,
                    lastOrdinal: continuesSource ? cursor?.lastOrdinal : nil,
                    threadID: continuesSource ? cursor?.threadID : nil,
                    processedPrefixFingerprint: continuesSource
                        ? cursor?.processedPrefixFingerprint
                        : nil,
                    checkpoint: continuesSource ? cursor?.checkpoint : nil
                ),
                bytesRead: bytesRead,
                unsupportedRecordCount: 0,
                malformedRecordCount: 0,
                requiresRebuild: requiresRebuild
            )
        }

        let completeData = data[...lastNewline]
        var threadID = continuesSource ? cursor?.threadID : nil
        var seenEventKeys = Set<String>()
        var records: [RolloutRecord] = []
        var lastObservedOrdinal = continuesSource ? cursor?.lastOrdinal : nil
        var unsupportedRecordCount = 0
        var malformedRecordCount = 0
        var processedPrefixFingerprint = startOffset == 0
            ? Self.fingerprintOffsetBasis
            : cursor?.processedPrefixFingerprint
        var checkpoint = continuesSource ? cursor?.checkpoint : nil
        var checkpointCandidate: (
            byteOffset: UInt64,
            byteLength: UInt64,
            threadID: String?,
            identity: String
        )?
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for line in completeData.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let relativeLineOffset = completeData.distance(
                from: completeData.startIndex,
                to: line.startIndex
            )
            let absoluteLineOffset = startOffset + UInt64(relativeLineOffset)
            guard let wire = try? decoder.decode(RolloutWire.self, from: Data(line)) else {
                unsupportedRecordCount += 1
                malformedRecordCount += 1
                continue
            }
            let type = wire.type
            let payload = wire.payload
            if type == "session_meta", let observedThreadID = payload.id {
                threadID = observedThreadID
            }
            let nonContentIdentity = replayIdentity(
                wire: wire,
                threadID: threadID,
                absoluteLineOffset: absoluteLineOffset
            )
            if let currentFingerprint = processedPrefixFingerprint {
                processedPrefixFingerprint = Self.fingerprint(
                    nonContentIdentity.utf8,
                    seed: currentFingerprint
                )
            }
            let ordinal = wire.ordinal
            let timestamp = wire.timestamp
            let eventType = payload.type
            let turnID = payload.turnId
            let totalUsage = payload.info?.totalTokenUsage
            let tokenUsage = localTokenUsage(totalUsage)
            let contextTokenUsage = localTokenUsage(
                payload.info?.lastTokenUsage
            )
            let eventKey: String
            if let ordinal {
                eventKey = "\(threadID ?? "unknown")|ordinal|\(ordinal)"
                let isReplay = continuesSource
                    && cursor?.lastOrdinal.map { ordinal <= $0 } == true
                if isReplay { continue }
                lastObservedOrdinal = max(lastObservedOrdinal ?? 0, ordinal)
            } else {
                eventKey = [
                    "\(identity.systemNumber):\(identity.fileNumber)",
                    String(absoluteLineOffset),
                    timestamp ?? "unknown",
                    type,
                    eventType ?? "none",
                    turnID ?? "none"
                ].joined(separator: "|")
            }
            guard seenEventKeys.insert(eventKey).inserted else { continue }
            guard isSupported(
                type: type,
                eventType: eventType,
                toolClass: payload.item?.type
            ) else {
                unsupportedRecordCount += 1
                continue
            }
            if line.count <= 4_096 {
                checkpointCandidate = (
                    byteOffset: absoluteLineOffset,
                    byteLength: UInt64(line.count),
                    threadID: threadID,
                    identity: nonContentIdentity
                )
            } else {
                checkpointCandidate = nil
                checkpoint = nil
            }
            records.append(
                RolloutRecord(
                    eventID: eventKey,
                    ordinal: ordinal,
                    timestamp: timestamp,
                    type: type,
                    eventType: eventType,
                    threadID: threadID,
                    parentThreadID: payload.parentThreadId,
                    cliVersion: payload.cliVersion,
                    historyMode: payload.historyMode,
                    agentRole: payload.agentRole,
                    agentNickname: payload.agentNickname,
                    turnID: turnID,
                    model: payload.model,
                    reasoning: payload.effort,
                    tokenUsage: tokenUsage,
                    contextTokenUsage: contextTokenUsage,
                    modelContextWindow: payload.modelContextWindow
                        ?? payload.info?.modelContextWindow,
                    startedAt: payload.startedAt,
                    completedAt: payload.completedAt,
                    durationMilliseconds: payload.durationMs,
                    timeToFirstTokenMilliseconds: payload.timeToFirstTokenMs,
                    toolClass: eventType == "item_completed"
                        ? normalizedToolClass(payload.item?.type)
                        : nil
                )
            )
        }
        let byteOffset = startOffset + UInt64(completeData.count)
        if let candidate = checkpointCandidate {
            checkpoint = RolloutCheckpoint(
                byteOffset: candidate.byteOffset,
                byteLength: candidate.byteLength,
                threadID: candidate.threadID,
                fingerprint: Self.fingerprint(candidate.identity.utf8)
            )
        }

        return RolloutTailBatch(
            records: records,
            cursor: RolloutCursor(
                fileIdentity: identity,
                sourceGeneration: sourceGeneration,
                byteOffset: byteOffset,
                fileSize: fileSize,
                modificationTime: modificationTime,
                lastOrdinal: lastObservedOrdinal,
                threadID: threadID,
                processedPrefixFingerprint: processedPrefixFingerprint,
                checkpoint: checkpoint
            ),
            bytesRead: bytesRead,
            unsupportedRecordCount: unsupportedRecordCount,
            malformedRecordCount: malformedRecordCount,
            requiresRebuild: requiresRebuild
        )
    }

    private func verifiedPrefix(
        handle: FileHandle,
        fileSize: UInt64,
        cursor: RolloutCursor?
    ) throws -> (matches: Bool, bytesRead: Int) {
        guard
            let cursor,
            cursor.byteOffset <= fileSize,
            cursor.byteOffset <= UInt64(Int.max),
            let expectedFingerprint = cursor.processedPrefixFingerprint
        else {
            return (false, 0)
        }
        try handle.seek(toOffset: 0)
        let prefix = try handle.read(upToCount: Int(cursor.byteOffset)) ?? Data()
        return (
            prefix.count == Int(cursor.byteOffset)
                && replayFingerprint(prefix) == expectedFingerprint,
            prefix.count
        )
    }

    private func verifiedCheckpoint(
        handle: FileHandle,
        fileSize: UInt64,
        cursor: RolloutCursor?
    ) throws -> (matches: Bool, bytesRead: Int) {
        guard let cursor else { return (true, 0) }
        guard cursor.byteOffset > 0 else { return (true, 0) }
        guard
            let checkpoint = cursor.checkpoint,
            checkpoint.byteLength <= 4_096,
            checkpoint.byteOffset + checkpoint.byteLength <= fileSize
        else {
            return (false, 0)
        }
        try handle.seek(toOffset: checkpoint.byteOffset)
        let data = try handle.read(
            upToCount: Int(checkpoint.byteLength)
        ) ?? Data()
        guard data.count == Int(checkpoint.byteLength) else {
            return (false, data.count)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let wire = try? decoder.decode(RolloutWire.self, from: data) else {
            return (false, data.count)
        }
        let threadID = wire.type == "session_meta"
            ? wire.payload.id
            : checkpoint.threadID
        let identity = replayIdentity(
            wire: wire,
            threadID: threadID,
            absoluteLineOffset: checkpoint.byteOffset
        )
        return (
            Self.fingerprint(identity.utf8) == checkpoint.fingerprint,
            data.count
        )
    }

    private func replayFingerprint(_ data: Data) -> UInt64 {
        var fingerprint = Self.fingerprintOffsetBasis
        var threadID: String?
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let wire = try? decoder.decode(RolloutWire.self, from: Data(line)) else {
                continue
            }
            if wire.type == "session_meta", let observedThreadID = wire.payload.id {
                threadID = observedThreadID
            }
            let absoluteLineOffset = UInt64(
                data.distance(from: data.startIndex, to: line.startIndex)
            )
            fingerprint = Self.fingerprint(
                replayIdentity(
                    wire: wire,
                    threadID: threadID,
                    absoluteLineOffset: absoluteLineOffset
                ).utf8,
                seed: fingerprint
            )
        }
        return fingerprint
    }

    private func replayIdentity(
        wire: RolloutWire,
        threadID: String?,
        absoluteLineOffset: UInt64
    ) -> String {
        let payload = wire.payload
        let tokenUsage = payload.info?.totalTokenUsage
        var components: [String] = []
        components.reserveCapacity(28)
        components.append(String(absoluteLineOffset))
        components.append(threadID ?? "unknown")
        components.append(wire.ordinal.map(String.init) ?? "no-ordinal")
        components.append(wire.timestamp ?? "unknown")
        components.append(wire.type)
        components.append(payload.type ?? "none")
        components.append(payload.id ?? "none")
        components.append(payload.parentThreadId ?? "none")
        components.append(payload.cliVersion ?? "none")
        components.append(payload.historyMode ?? "none")
        components.append(payload.agentRole ?? "none")
        components.append(payload.agentNickname ?? "none")
        components.append(payload.turnId ?? "none")
        components.append(payload.model ?? "none")
        components.append(payload.effort ?? "none")
        components.append(
            integerString(
                payload.modelContextWindow
                    ?? payload.info?.modelContextWindow
            )
        )
        components.append(contentsOf: [
            integerString(payload.startedAt),
            integerString(payload.completedAt),
            integerString(payload.durationMs),
            integerString(payload.timeToFirstTokenMs)
        ])
        components.append(contentsOf: [
            integerString(tokenUsage?.inputTokens),
            integerString(tokenUsage?.cachedInputTokens),
            integerString(tokenUsage?.cacheWriteInputTokens),
            integerString(tokenUsage?.outputTokens),
            integerString(tokenUsage?.reasoningOutputTokens),
            integerString(tokenUsage?.totalTokens)
        ])
        let contextTokenUsage = payload.info?.lastTokenUsage
        components.append(contentsOf: [
            integerString(contextTokenUsage?.inputTokens),
            integerString(contextTokenUsage?.cachedInputTokens),
            integerString(contextTokenUsage?.cacheWriteInputTokens),
            integerString(contextTokenUsage?.outputTokens),
            integerString(contextTokenUsage?.reasoningOutputTokens),
            integerString(contextTokenUsage?.totalTokens)
        ])
        components.append(payload.item?.type ?? "none")
        return components.joined(separator: "|")
    }

    private func localTokenUsage(
        _ usage: RolloutWire.TokenUsage?
    ) -> LocalTokenUsage? {
        usage?.totalTokens.map {
            var observed: Set<LocalTokenComponent> = [.total]
            if usage?.inputTokens != nil { observed.insert(.input) }
            if usage?.cachedInputTokens != nil {
                observed.insert(.cachedInput)
            }
            if usage?.cacheWriteInputTokens != nil {
                observed.insert(.cacheWriteInput)
            }
            if usage?.outputTokens != nil { observed.insert(.output) }
            if usage?.reasoningOutputTokens != nil {
                observed.insert(.reasoningOutput)
            }
            return LocalTokenUsage(
                inputTokens: usage?.inputTokens ?? 0,
                cachedInputTokens: usage?.cachedInputTokens ?? 0,
                cacheWriteInputTokens: usage?.cacheWriteInputTokens ?? 0,
                outputTokens: usage?.outputTokens ?? 0,
                reasoningOutputTokens: usage?.reasoningOutputTokens ?? 0,
                totalTokens: $0,
                observedComponents: observed
            )
        }
    }

    private func integerString(_ value: Int64?) -> String {
        value.map(String.init) ?? "none"
    }

    private static func fingerprint<Bytes: Sequence>(
        _ bytes: Bytes,
        seed: UInt64 = fingerprintOffsetBasis
    ) -> UInt64 where Bytes.Element == UInt8 {
        bytes.reduce(seed) { partial, byte in
            (partial ^ UInt64(byte)) &* fingerprintPrime
        }
    }

    private func isSupported(
        type: String,
        eventType: String?,
        toolClass: String?
    ) -> Bool {
        if ["session_meta", "turn_context", "compacted"].contains(type) {
            return true
        }
        guard type == "event_msg", let eventType else { return false }
        if [
            "task_started",
            "task_complete",
            "turn_started",
            "turn_complete",
            "turn_aborted",
            "token_count",
            "thread_settings_applied"
        ].contains(eventType) {
            return true
        }
        guard eventType == "item_completed", let toolClass else { return false }
        return normalizedToolClass(toolClass) != nil
    }

    private func normalizedToolClass(_ wireValue: String?) -> String? {
        switch wireValue {
        case "CommandExecution":
            "command_execution"
        case "DynamicToolCall":
            "dynamic_tool_call"
        case "CollabAgentToolCall":
            "collab_agent_tool_call"
        case "WebSearch":
            "web_search"
        case "ImageView":
            "image_view"
        case "Extension":
            "extension"
        case "ImageGeneration":
            "image_generation"
        case "FileChange":
            "file_change"
        case "McpToolCall":
            "mcp_tool_call"
        default:
            nil
        }
    }
}

private struct RolloutWire: Decodable {
    let timestamp: String?
    let ordinal: UInt64?
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String?
        let id: String?
        let parentThreadId: String?
        let cliVersion: String?
        let historyMode: String?
        let agentRole: String?
        let agentNickname: String?
        let turnId: String?
        let model: String?
        let effort: String?
        let modelContextWindow: Int64?
        let startedAt: Int64?
        let completedAt: Int64?
        let durationMs: Int64?
        let timeToFirstTokenMs: Int64?
        let info: TokenInfo?
        let item: CompletedItem?
    }

    struct TokenInfo: Decodable {
        let totalTokenUsage: TokenUsage?
        let lastTokenUsage: TokenUsage?
        let modelContextWindow: Int64?
    }

    struct TokenUsage: Decodable {
        let inputTokens: Int64?
        let cachedInputTokens: Int64?
        let cacheWriteInputTokens: Int64?
        let outputTokens: Int64?
        let reasoningOutputTokens: Int64?
        let totalTokens: Int64?
    }

    struct CompletedItem: Decodable {
        let type: String?
    }
}
