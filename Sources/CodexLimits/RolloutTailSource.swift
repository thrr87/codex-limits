import Foundation

enum RolloutTailSourceError: Error, Equatable {
    case missingFileMetadata
    case counterOverflow
}

struct BoundedJSONLReadResult {
    let completeByteOffset: UInt64
    let resumeByteOffset: UInt64
    let bytesRead: UInt64
    let oversizedRecordCount: Int
    let processedLineCount: Int
    let stoppedEarly: Bool
    let discardingOversizedRecord: Bool
}

struct BoundedJSONLReader {
    static let maximumRecordBytes = 16 * 1_024 * 1_024
    private static let chunkBytes = 65_536

    static func read(
        handle: FileHandle,
        from startOffset: UInt64,
        through endOffset: UInt64? = nil,
        maximumLines: Int = .max,
        maximumBytes: UInt64 = .max,
        maximumRecordBytes: Int = Self.maximumRecordBytes,
        startsByDiscardingOversizedRecord: Bool = false,
        discardsPartialRecordAtByteLimit: Bool = true,
        onLine: (Data, UInt64) throws -> Bool
    ) throws -> BoundedJSONLReadResult {
        let lineLimit = max(maximumLines, 1)
        let byteLimit = max(maximumBytes, 1)
        try handle.seek(toOffset: startOffset)
        var line = Data()
        var lineStart = startOffset
        var completeByteOffset = startOffset
        var bytesRead: UInt64 = 0
        var oversizedRecordCount =
            startsByDiscardingOversizedRecord ? 1 : 0
        var processedLineCount = 0
        var processedBytes: UInt64 = 0
        var skipsCurrentLine = startsByDiscardingOversizedRecord
        var countedCurrentOversizedLine = startsByDiscardingOversizedRecord

        while true {
            let (currentOffset, currentOffsetOverflowed) =
                startOffset.addingReportingOverflow(bytesRead)
            guard !currentOffsetOverflowed else {
                throw RolloutTailSourceError.counterOverflow
            }
            let remaining = endOffset.map {
                $0 >= currentOffset ? $0 - currentOffset : 0
            }
            if remaining == 0 { break }
            let budgetRemaining = byteLimit > bytesRead
                ? byteLimit - bytesRead
                : 0
            if budgetRemaining == 0 {
                let discardsPartial = discardsPartialRecordAtByteLimit
                    && !line.isEmpty
                if discardsPartial, !countedCurrentOversizedLine {
                    oversizedRecordCount += 1
                }
                return BoundedJSONLReadResult(
                    completeByteOffset: completeByteOffset,
                    resumeByteOffset: discardsPartial || skipsCurrentLine
                        ? currentOffset
                        : completeByteOffset,
                    bytesRead: bytesRead,
                    oversizedRecordCount: oversizedRecordCount,
                    processedLineCount: processedLineCount,
                    stoppedEarly: true,
                    discardingOversizedRecord: skipsCurrentLine
                        || discardsPartial
                )
            }
            let count = min(
                Self.chunkBytes,
                remaining.map { Int(min($0, UInt64(Self.chunkBytes))) }
                    ?? Self.chunkBytes,
                Int(min(budgetRemaining, UInt64(Self.chunkBytes)))
            )
            guard count > 0,
                  let chunk = try handle.read(upToCount: count),
                  !chunk.isEmpty else {
                break
            }
            let chunkStart = currentOffset
            let (nextBytesRead, overflowed) = bytesRead.addingReportingOverflow(
                UInt64(chunk.count)
            )
            guard !overflowed else {
                throw RolloutTailSourceError.counterOverflow
            }
            bytesRead = nextBytesRead
            var pieceStart = chunk.startIndex
            while let newline = chunk[pieceStart...].firstIndex(of: 0x0A) {
                let piece = chunk[pieceStart..<newline]
                if !skipsCurrentLine {
                    if line.count + piece.count > maximumRecordBytes {
                        line.removeAll(keepingCapacity: false)
                        skipsCurrentLine = true
                        if !countedCurrentOversizedLine {
                            oversizedRecordCount += 1
                            countedCurrentOversizedLine = true
                        }
                    } else {
                        line.append(contentsOf: piece)
                    }
                }
                let distance = chunk.distance(
                    from: chunk.startIndex,
                    to: newline
                ) + 1
                let (lineEnd, offsetOverflowed) =
                    chunkStart.addingReportingOverflow(UInt64(distance))
                guard !offsetOverflowed else {
                    throw RolloutTailSourceError.counterOverflow
                }
                let shouldContinue: Bool
                if skipsCurrentLine {
                    shouldContinue = true
                } else if !line.isEmpty {
                    shouldContinue = try onLine(line, lineStart)
                } else {
                    shouldContinue = true
                }
                let (lineBytes, lineBytesOverflowed) =
                    lineEnd.subtractingReportingOverflow(lineStart)
                guard !lineBytesOverflowed else {
                    throw RolloutTailSourceError.counterOverflow
                }
                let (nextProcessedBytes, processedBytesOverflowed) =
                    processedBytes.addingReportingOverflow(lineBytes)
                guard !processedBytesOverflowed else {
                    throw RolloutTailSourceError.counterOverflow
                }
                processedBytes = nextProcessedBytes
                processedLineCount += 1
                line.removeAll(keepingCapacity: true)
                skipsCurrentLine = false
                countedCurrentOversizedLine = false
                completeByteOffset = lineEnd
                lineStart = lineEnd
                pieceStart = chunk.index(after: newline)
                if !shouldContinue
                    || processedLineCount >= lineLimit
                    || processedBytes >= byteLimit {
                    return BoundedJSONLReadResult(
                        completeByteOffset: completeByteOffset,
                        resumeByteOffset: completeByteOffset,
                        bytesRead: bytesRead,
                        oversizedRecordCount: oversizedRecordCount,
                        processedLineCount: processedLineCount,
                        stoppedEarly: true,
                        discardingOversizedRecord: false
                    )
                }
            }
            let remainder = chunk[pieceStart...]
            if !skipsCurrentLine {
                if line.count + remainder.count > maximumRecordBytes {
                    line.removeAll(keepingCapacity: false)
                    skipsCurrentLine = true
                    if !countedCurrentOversizedLine {
                        oversizedRecordCount += 1
                        countedCurrentOversizedLine = true
                    }
                } else {
                    line.append(contentsOf: remainder)
                }
            }
            if bytesRead >= byteLimit, skipsCurrentLine || !line.isEmpty {
                let discardsPartial = discardsPartialRecordAtByteLimit
                    && !line.isEmpty
                if discardsPartial,
                   !skipsCurrentLine,
                   !countedCurrentOversizedLine {
                    oversizedRecordCount += 1
                }
                let (resumeByteOffset, offsetOverflowed) =
                    startOffset.addingReportingOverflow(bytesRead)
                guard !offsetOverflowed else {
                    throw RolloutTailSourceError.counterOverflow
                }
                return BoundedJSONLReadResult(
                    completeByteOffset: completeByteOffset,
                    resumeByteOffset: discardsPartial || skipsCurrentLine
                        ? resumeByteOffset
                        : completeByteOffset,
                    bytesRead: bytesRead,
                    oversizedRecordCount: oversizedRecordCount,
                    processedLineCount: processedLineCount,
                    stoppedEarly: true,
                    discardingOversizedRecord: skipsCurrentLine
                        || discardsPartial
                )
            }
        }
        let resumeByteOffset: UInt64
        if skipsCurrentLine {
            let (offset, overflowed) =
                startOffset.addingReportingOverflow(bytesRead)
            guard !overflowed else {
                throw RolloutTailSourceError.counterOverflow
            }
            resumeByteOffset = offset
        } else {
            resumeByteOffset = completeByteOffset
        }
        return BoundedJSONLReadResult(
            completeByteOffset: completeByteOffset,
            resumeByteOffset: resumeByteOffset,
            bytesRead: bytesRead,
            oversizedRecordCount: oversizedRecordCount,
            processedLineCount: processedLineCount,
            stoppedEarly: false,
            discardingOversizedRecord: skipsCurrentLine
        )
    }
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
    let rawSuffixFingerprint: UInt64?
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
    let discardingOversizedRecord: Bool?
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
    private let observedComponentMask: UInt8
    var observedComponents: Set<LocalTokenComponent> {
        Set(LocalTokenComponent.allCases.filter(observes))
    }

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
        observedComponentMask = Self.mask(for: observedComponents)
    }

    init(
        inputTokens: Int64,
        cachedInputTokens: Int64,
        cacheWriteInputTokens: Int64,
        outputTokens: Int64,
        reasoningOutputTokens: Int64,
        totalTokens: Int64,
        observedComponentMask: UInt8
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.observedComponentMask = observedComponentMask
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
        observedComponentMask = Self.mask(
            for: try values.decodeIfPresent(
            [LocalTokenComponent].self,
            forKey: .observedComponents
            ).map(Set.init) ?? [.total]
        )
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

    func observes(_ component: LocalTokenComponent) -> Bool {
        observedComponentMask & Self.bit(for: component) != 0
    }

    func sharedObservedComponentMask(with other: LocalTokenUsage) -> UInt8 {
        observedComponentMask & other.observedComponentMask
    }

    private static func mask(
        for components: Set<LocalTokenComponent>
    ) -> UInt8 {
        components.reduce(0) { $0 | bit(for: $1) }
    }

    private static func bit(for component: LocalTokenComponent) -> UInt8 {
        switch component {
        case .input: 1 << 0
        case .cachedInput: 1 << 1
        case .cacheWriteInput: 1 << 2
        case .output: 1 << 3
        case .reasoningOutput: 1 << 4
        case .total: 1 << 5
        }
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
    let continuityChanged: Bool
    let hasMoreRecords: Bool
    let processedLineCount: Int
}

struct IncrementalRolloutTailSource {
    private static let fingerprintOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fingerprintPrime: UInt64 = 1_099_511_628_211
    private static let payloadMarker = Data(#","payload":"#.utf8)
    private static let compactedTypeMarker = Data(#""type":"compacted""#.utf8)
    private static let emptyPayloadSuffix = Data(#","payload":{}}"#.utf8)
    // ponytail: bound one batch; stream normalization if one-pass import matters.
    static let maximumLinesPerBatch = 100_000
    static let maximumBytesPerBatch: UInt64 = 64 * 1_024 * 1_024

    func read(
        fileURL: URL,
        cursor: RolloutCursor?,
        observedAt: Date,
        maximumLines: Int = Self.maximumLinesPerBatch,
        maximumBytes: UInt64 = Self.maximumBytesPerBatch,
        maximumRecordBytes: Int = BoundedJSONLReader.maximumRecordBytes
    ) throws -> RolloutTailBatch {
        let byteBudget = max(maximumBytes, 1)
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
        let continuationVerification: (matches: Bool?, bytesRead: UInt64)
        if metadataUnchanged {
            continuationVerification = (true, 0)
        } else if sameFileIdentity,
                  let cursor,
                  fileSize > cursor.fileSize {
            // Codex owns rollout files and appends to them. Verify the last
            // complete record so live growth stays proportional to the delta.
            continuationVerification =
                cursor.discardingOversizedRecord == true
                    ? (true, 0)
                    : try verifiedCheckpoint(
                        handle: handle,
                        fileSize: fileSize,
                        cursor: cursor,
                        maximumBytes: byteBudget
                    )
        } else {
            continuationVerification = try verifiedPrefix(
                handle: handle,
                fileSize: fileSize,
                cursor: cursor,
                maximumBytes: byteBudget
            )
        }
        if continuationVerification.matches == nil,
           sameFileIdentity,
           cursor.map({ fileSize > $0.fileSize }) == true,
           let cursor,
           cursor.checkpoint != nil {
            return RolloutTailBatch(
                records: [],
                cursor: cursor,
                bytesRead: 0,
                unsupportedRecordCount: 0,
                malformedRecordCount: 0,
                requiresRebuild: false,
                continuityChanged: false,
                hasMoreRecords: true,
                processedLineCount: 0
            )
        }
        let continuesSource = continuationVerification.matches == true
        let startOffset = continuesSource ? cursor?.byteOffset ?? 0 : 0
        let requiresRebuild = cursor != nil && !continuesSource
        let continuityChanged = cursor != nil
            && continuationVerification.matches == false
        let sourceGeneration: UInt64
        if let cursor {
            if sameFileIdentity && continuesSource {
                sourceGeneration = cursor.sourceGeneration
            } else {
                let (next, overflowed) =
                    cursor.sourceGeneration.addingReportingOverflow(1)
                guard !overflowed else {
                    throw RolloutTailSourceError.counterOverflow
                }
                sourceGeneration = next
            }
        } else {
            sourceGeneration = 0
        }
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
            fingerprint: UInt64,
            rawSuffixFingerprint: UInt64?
        )?
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let readByteBudget = continuationVerification.bytesRead < byteBudget
            ? byteBudget - continuationVerification.bytesRead
            : 1

        let readResult = try BoundedJSONLReader.read(
            handle: handle,
            from: startOffset,
            maximumLines: maximumLines,
            maximumBytes: readByteBudget,
            maximumRecordBytes: maximumRecordBytes,
            startsByDiscardingOversizedRecord:
                continuesSource
                    && cursor?.discardingOversizedRecord == true,
            discardsPartialRecordAtByteLimit: false
        ) { line, absoluteLineOffset in
            guard let wire = decodeWire(line, decoder: decoder) else {
                unsupportedRecordCount += 1
                malformedRecordCount += 1
                return true
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
            if totalUsage?.totalTokens != nil, tokenUsage == nil {
                malformedRecordCount += 1
            }
            if payload.info?.lastTokenUsage?.totalTokens != nil,
               contextTokenUsage == nil {
                malformedRecordCount += 1
            }
            let eventKey: String
            if let ordinal {
                eventKey = "\(threadID ?? "unknown")|ordinal|\(ordinal)"
                let isReplay = continuesSource
                    && cursor?.lastOrdinal.map { ordinal <= $0 } == true
                if isReplay { return true }
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
            guard seenEventKeys.insert(eventKey).inserted else { return true }
            guard isSupported(
                type: type,
                eventType: eventType,
                toolClass: payload.item?.type
            ) else {
                unsupportedRecordCount += 1
                return true
            }
            if line.count <= 4_096 {
                checkpointCandidate = (
                    byteOffset: absoluteLineOffset,
                    byteLength: UInt64(line.count),
                    threadID: threadID,
                    fingerprint: Self.fingerprint(
                        nonContentIdentity.utf8
                    ),
                    rawSuffixFingerprint: nil
                )
            } else {
                checkpointCandidate = (
                    byteOffset: absoluteLineOffset,
                    byteLength: UInt64(line.count),
                    threadID: threadID,
                    fingerprint: Self.fingerprint(line.prefix(2_048)),
                    rawSuffixFingerprint: Self.fingerprint(line.suffix(2_048))
                )
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
            return true
        }
        unsupportedRecordCount += readResult.oversizedRecordCount
        malformedRecordCount += readResult.oversizedRecordCount
        let (bytesRead, bytesReadOverflowed) =
            continuationVerification.bytesRead.addingReportingOverflow(
                readResult.bytesRead
            )
        guard !bytesReadOverflowed else {
            throw RolloutTailSourceError.counterOverflow
        }
        let byteOffset = readResult.resumeByteOffset
        let hasMoreRecords = readResult.stoppedEarly && byteOffset < fileSize
        if byteOffset == startOffset, !continuesSource {
            processedPrefixFingerprint = nil
        }
        if let candidate = checkpointCandidate {
            checkpoint = RolloutCheckpoint(
                byteOffset: candidate.byteOffset,
                byteLength: candidate.byteLength,
                threadID: candidate.threadID,
                fingerprint: candidate.fingerprint,
                rawSuffixFingerprint: candidate.rawSuffixFingerprint
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
                checkpoint: checkpoint,
                discardingOversizedRecord:
                    readResult.discardingOversizedRecord ? true : nil
            ),
            bytesRead: bytesRead,
            unsupportedRecordCount: unsupportedRecordCount,
            malformedRecordCount: malformedRecordCount,
            requiresRebuild: requiresRebuild,
            continuityChanged: continuityChanged,
            hasMoreRecords: hasMoreRecords,
            processedLineCount: readResult.processedLineCount
        )
    }

    private func verifiedPrefix(
        handle: FileHandle,
        fileSize: UInt64,
        cursor: RolloutCursor?,
        maximumBytes: UInt64
    ) throws -> (matches: Bool?, bytesRead: UInt64) {
        guard
            let cursor,
            cursor.byteOffset <= fileSize,
            let expectedFingerprint = cursor.processedPrefixFingerprint
        else {
            return (false, 0)
        }
        guard cursor.byteOffset <= maximumBytes else {
            return (nil, 0)
        }
        var fingerprint = Self.fingerprintOffsetBasis
        var threadID: String?
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try BoundedJSONLReader.read(
            handle: handle,
            from: 0,
            through: cursor.byteOffset
        ) { line, absoluteLineOffset in
            guard let wire = decodeWire(line, decoder: decoder) else {
                return true
            }
            if wire.type == "session_meta",
               let observedThreadID = wire.payload.id {
                threadID = observedThreadID
            }
            fingerprint = Self.fingerprint(
                replayIdentity(
                    wire: wire,
                    threadID: threadID,
                    absoluteLineOffset: absoluteLineOffset
                ).utf8,
                seed: fingerprint
            )
            return true
        }
        return (
            result.completeByteOffset == cursor.byteOffset
                && fingerprint == expectedFingerprint,
            result.bytesRead
        )
    }

    private func verifiedCheckpoint(
        handle: FileHandle,
        fileSize: UInt64,
        cursor: RolloutCursor?,
        maximumBytes: UInt64
    ) throws -> (matches: Bool?, bytesRead: UInt64) {
        guard let cursor else { return (true, 0) }
        guard cursor.byteOffset > 0 else { return (true, 0) }
        let checkpointEnd = cursor.checkpoint.map {
            $0.byteOffset.addingReportingOverflow($0.byteLength)
        }
        guard
            let checkpoint = cursor.checkpoint,
            let checkpointEnd,
            !checkpointEnd.overflow,
            checkpointEnd.partialValue <= fileSize
        else {
            return (false, 0)
        }
        if let expectedSuffix = checkpoint.rawSuffixFingerprint {
            guard checkpoint.byteLength <= UInt64(
                BoundedJSONLReader.maximumRecordBytes
            ) else {
                return (false, 0)
            }
            let sliceLength = min(checkpoint.byteLength, 2_048)
            guard sliceLength * 2 <= maximumBytes else {
                return (nil, 0)
            }
            try handle.seek(toOffset: checkpoint.byteOffset)
            let prefix = try handle.read(
                upToCount: Int(sliceLength)
            ) ?? Data()
            let suffixOffset = checkpointEnd.partialValue - sliceLength
            try handle.seek(toOffset: suffixOffset)
            let suffix = try handle.read(
                upToCount: Int(sliceLength)
            ) ?? Data()
            let bytesRead = UInt64(prefix.count + suffix.count)
            guard prefix.count == Int(sliceLength),
                  suffix.count == Int(sliceLength) else {
                return (false, bytesRead)
            }
            return (
                Self.fingerprint(prefix) == checkpoint.fingerprint
                    && Self.fingerprint(suffix) == expectedSuffix,
                bytesRead
            )
        }
        guard checkpoint.byteLength <= 4_096 else {
            return (false, 0)
        }
        guard checkpoint.byteLength <= maximumBytes else {
            return (nil, 0)
        }
        try handle.seek(toOffset: checkpoint.byteOffset)
        let data = try handle.read(
            upToCount: Int(checkpoint.byteLength)
        ) ?? Data()
        guard data.count == Int(checkpoint.byteLength) else {
            return (false, UInt64(data.count))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let wire = decodeWire(data, decoder: decoder) else {
            return (false, UInt64(data.count))
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
            UInt64(data.count)
        )
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

    private func decodeWire(
        _ data: Data,
        decoder: JSONDecoder
    ) -> RolloutWire? {
        if let payload = data.range(of: Self.payloadMarker),
           data.range(
               of: Self.compactedTypeMarker,
               in: data.startIndex..<payload.lowerBound
           ) != nil {
            var header = data.subdata(in: data.startIndex..<payload.lowerBound)
            header.append(Self.emptyPayloadSuffix)
            if let wire = try? decoder.decode(RolloutWire.self, from: header),
               wire.type == "compacted" {
                return wire
            }
        }
        return try? decoder.decode(RolloutWire.self, from: data)
    }

    private func localTokenUsage(
        _ usage: RolloutWire.TokenUsage?
    ) -> LocalTokenUsage? {
        usage?.totalTokens.flatMap {
            let counters = [
                usage?.inputTokens,
                usage?.cachedInputTokens,
                usage?.cacheWriteInputTokens,
                usage?.outputTokens,
                usage?.reasoningOutputTokens,
                usage?.totalTokens
            ].compactMap { $0 }
            guard counters.allSatisfy({ $0 >= 0 }) else { return nil }
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
