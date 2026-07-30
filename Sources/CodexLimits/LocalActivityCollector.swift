import CryptoKit
import Foundation

private func nextRevision(after revision: UInt64) -> UInt64 {
    revision == .max ? 1 : revision + 1
}

struct LocalActivityCollection: Equatable, Sendable {
    let facts: [LocalActivityFact]
    let projections: [ThreadProjection]
    let observation: LocalActivityObservation
    let bytesRead: UInt64
    let contentRevision: UInt64

    static func unavailable(
        _ reason: String,
        facts: [LocalActivityFact] = [],
        projections: [ThreadProjection] = [],
        contentRevision: UInt64 = 0
    ) -> LocalActivityCollection {
        LocalActivityCollection(
            facts: facts,
            projections: projections,
            observation: .unavailable(reason),
            bytesRead: 0,
            contentRevision: contentRevision
        )
    }

    func loweringCoverage(_ reason: String) -> LocalActivityCollection {
        switch observation {
        case let .continuous(sourceVersion, observedAt),
             let .gap(sourceVersion, observedAt, _):
            return LocalActivityCollection(
                facts: facts,
                projections: projections,
                observation: .gap(
                    sourceVersion: sourceVersion,
                    observedAt: observedAt,
                    reason: reason
                ),
                bytesRead: bytesRead,
                contentRevision: contentRevision
            )
        case .unavailable:
            return self
        }
    }
}

struct LocalStoredTokenActivityCollection: Equatable, Sendable {
    let snapshot: LocalTokenActivitySnapshot
    let filterOptions: UsageReceiptFilterOptions
    let observation: LocalActivityObservation
    let bytesRead: UInt64
    let importPending: Bool
}

actor LocalActivityCollector {
    private static let maximumMetadataBytes = 1_048_576
    private static let maximumRefreshLines = 10_000
    private static let maximumRefreshBytes: UInt64 = 8 * 1_024 * 1_024
    private static let maximumStoredRefreshLines = 10_000
    private static let maximumRolloutRecordBytes = 7 * 1_024 * 1_024
    private static let maximumStoredRolloutRecordBytes = 256 * 1_024
    private static let maximumStoredRefreshBytes: UInt64 = 64 * 1_024 * 1_024

    private struct ObservationSignature: Equatable {
        let sourceVersion: String?
        let reason: String?
        let coverage: CoverageLevel
    }

    private struct FileState {
        var cursor: RolloutCursor
        var normalization: LocalActivityNormalizationState
        var facts: [LocalActivityFact]
        var eventIDs: Set<String>
        var activityStart: Date?
        var activityEnd: Date?
        var discontinuityAt: Date?
        var hasMalformedRecords: Bool
        var storageFingerprint: String?
        var factsLoaded: Bool
        var requiresContextRebuild: Bool
        var factRestoreOffset: UInt64
        var factRestoreFileSize: UInt64?
        var restoredFactIdentities: Set<FactIdentity>
    }

    private struct FactIdentity: Hashable {
        let eventID: String
        let key: String
    }

    private enum FactLoadOutcome {
        case ready(linesRead: Int, bytesRead: UInt64)
        case partial(linesRead: Int, bytesRead: UInt64)
        case invalid
    }

    private struct PersistedFile: Codable {
        let version: Int
        let path: String?
        let pathFingerprint: String?
        let cursor: RolloutCursor
        let normalization: LocalActivityNormalizationState
        let activityStart: Date?
        let activityEnd: Date?
        let discontinuityAt: Date?
        let hasMalformedRecords: Bool?
        let projection: ThreadProjection?
        let ancestorProjections: [ThreadProjection]?
    }

    private struct FactWrite {
        var rewritesFile: Bool
        var facts: [LocalActivityFact]
    }

    private struct StoredTokenImportCheckpoint: Codable {
        var retainedTokenAfterCutoff: Bool
    }

    private struct StoredTokenCacheKey: Equatable {
        let interval: DateInterval
        let filters: WorkspaceFilters
    }

    private struct StoredTokenCache {
        let key: StoredTokenCacheKey
        let snapshot: LocalTokenActivitySnapshot
        let filterOptions: UsageReceiptFilterOptions
    }

    private struct StoredFilterOptionsCache {
        let interval: DateInterval
        let options: UsageReceiptFilterOptions
    }

    private struct StoredTokenFactProjection: Decodable {
        struct Source: Decodable {
            let sourceGeneration: UInt64
        }

        let key: LocalActivityFactKey
        let availability: LocalActivityAvailability
        let numericDelta: Int64?
        let reason: String?
        let eventID: String?
        let eventTimestamp: String?
        let source: Source
        let context: LocalActivityContext?
    }

    private struct DeletionMarker: Codable {
        let version: Int
        let cutoff: Date
        let cleanupPending: Bool
    }

    private enum DeletionMarkerRestore {
        case missing
        case valid(DeletionMarker)
        case invalid
    }

    private let rootDirectory: URL
    private let stateDirectory: URL?
    private let projectionSource: ReadOnlyThreadProjectionSource?
    private let installedCLIVersion: (@Sendable () async -> String?)?
    private let tail = IncrementalRolloutTailSource()
    private let normalizer = LocalActivityNormalizer()
    private let timestampParser = LocalEventTimestampParser()
    private var files: [String: FileState] = [:]
    private var restoredFilesByFingerprint: [String: FileState] = [:]
    private var restoredFingerprintByIdentity: [RolloutFileIdentity: String] = [:]
    private var projections: [String: ThreadProjection] = [:]
    private var partitionID: String?
    private var changedPaths = Set<String>()
    private var pendingFactWrites: [String: FactWrite] = [:]
    private var nextProjectionListCursor: String?
    private var hasStartedProjectionList = false
    private var hasCompleteProjectionList = false
    private var lastProjectionListSucceeded: Bool?
    private var attemptedProjectionTaskIDs = Set<String>()
    private var stateGeneration: UInt64 = 0
    private var historyCutoff: Date?
    private var historyDeletionPending = false
    private var deletionMarkerInvalid = false
    private var restoreWarning: String?
    private var cachedFacts: [LocalActivityFact]?
    private var cachedFactPaths = Set<String>()
    private var cachedFactsIntervalStart: Date?
    private var lastPublishedProjectionIdentities: [ProjectionIdentity]?
    private var lastObservationSignature: ObservationSignature?
    private var contentRevision: UInt64 = 0
    private var importContinuationPending = false
    private var pendingFactRestorePaths = Set<String>()
    private var publishedFactPaths = Set<String>()
    private var refreshGeneration: UInt64 = 0
    private var didReadInstalledCLIVersion = false
    private var cachedInstalledCLIVersion: String?
    private var storedTokenStore: LocalActivityStore?
    private var storedTokenCache: StoredTokenCache?
    private var storedFilterOptionsCache: StoredFilterOptionsCache?

    init(
        rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        stateDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Codex Limits", isDirectory: true)
            .appendingPathComponent("local-activity", isDirectory: true),
        projectionSource: ReadOnlyThreadProjectionSource? = nil,
        installedCLIVersion: (@Sendable () async -> String?)? = nil
    ) {
        self.rootDirectory = rootDirectory.resolvingSymlinksInPath()
        self.stateDirectory = stateDirectory
        self.projectionSource = projectionSource
        self.installedCLIVersion = installedCLIVersion
        if let stateDirectory {
            switch Self.restoreDeletionMarker(for: stateDirectory) {
            case let .valid(marker):
                historyCutoff = marker.cutoff
                historyDeletionPending = marker.cleanupPending
            case .invalid:
                historyCutoff = .distantFuture
                historyDeletionPending = true
                deletionMarkerInvalid = true
                restoreWarning = "Saved deletion state could not be read"
            case .missing:
                historyCutoff = Self.restoreLegacyHistoryCutoff(
                    from: stateDirectory
                )
            }
        }
    }

    func selectPartition(_ id: String) {
        guard partitionID != id else { return }
        stateGeneration = nextRevision(after: stateGeneration)
        persist()
        closeStoredTokenStore()
        partitionID = id
        files.removeAll()
        restoredFilesByFingerprint.removeAll()
        restoredFingerprintByIdentity.removeAll()
        projections.removeAll()
        changedPaths.removeAll()
        pendingFactWrites.removeAll()
        nextProjectionListCursor = nil
        hasStartedProjectionList = false
        hasCompleteProjectionList = false
        restoreWarning = nil
        clearPublishedContent()
        restore()
    }

    func refresh(
        interval: DateInterval,
        observedAt: Date = Date(),
        refreshMetadata: Bool = true
    ) async -> LocalActivityCollection {
        refreshGeneration = nextRevision(after: refreshGeneration)
        let currentRefreshGeneration = refreshGeneration
        let currentStateGeneration = stateGeneration
        if historyDeletionPending {
            return .unavailable(
                deletionMarkerInvalid
                    ? "Saved deletion state could not be read"
                    : "Analytics history deletion is pending"
            )
        }
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return .unavailable(
                "Codex local records are unavailable",
                facts: cachedFacts ?? files.values.flatMap(\.facts)
            )
        }

        let projectionsBeforeRefresh = projections
        let listSucceeded: Bool?
        if refreshMetadata {
            listSucceeded = await refreshProjectionList(
                generation: currentStateGeneration,
                refreshGeneration: currentRefreshGeneration
            )
        } else {
            listSucceeded = lastProjectionListSucceeded
        }
        guard !Task.isCancelled else {
            return .unavailable("Local activity read was cancelled")
        }
        guard currentStateGeneration == stateGeneration,
              currentRefreshGeneration == refreshGeneration else {
            return .unavailable("Account changed during local activity read")
        }
        if refreshMetadata {
            lastProjectionListSucceeded = listSucceeded
        }
        let currentProjections = activeProjections(in: interval)
        let candidatePaths: Set<String>
        if !refreshMetadata,
           cachedFactsIntervalStart == interval.start,
           !cachedFactPaths.isEmpty {
            candidatePaths = cachedFactPaths
        } else {
            let calendarFiles = rolloutFiles(in: interval)
            let projectedFiles = Set(
                currentProjections.compactMap(validProjectionFile)
            )
            let trackedFiles = Set(files.compactMap { path, state in
                stateHasActivity(state, in: interval) ? fileURL(path) : nil
            })
            candidatePaths = Set(
                calendarFiles
                    .union(projectedFiles)
                    .union(trackedFiles)
                    .compactMap(fileKey)
            )
        }
        for path in candidatePaths {
            bindRestoredStateIfNeeded(to: path)
        }
        if cachedFactsIntervalStart != interval.start {
            restartPartialFactRestores()
        }
        let reusesPublishedFacts = cachedFacts != nil
            && cachedFactsIntervalStart == interval.start
            && cachedFactPaths.isSubset(of: candidatePaths)
        if !reusesPublishedFacts {
            pendingFactRestorePaths = Set(candidatePaths.filter {
                files[$0]?.factsLoaded == false
            })
            publishedFactPaths.removeAll()
        } else {
            pendingFactRestorePaths.formIntersection(candidatePaths)
            for path in candidatePaths.subtracting(cachedFactPaths)
            where files[path]?.factsLoaded == false {
                pendingFactRestorePaths.insert(path)
            }
        }
        var bytesRead: UInt64 = 0
        var factsChanged = false
        var rewroteFacts = false
        var appendedFacts: [LocalActivityFact] = []
        var remainingLineBudget = Self.maximumRefreshLines
        var remainingByteBudget = Self.maximumRefreshBytes
        var importStillInProgress = false
        var gapReason = restoreWarning ?? (listSucceeded == false
            ? "Local task discovery is incomplete"
            : currentProjections.contains {
            validProjectionFile($0) == nil
        } ? "Local rollout path is unavailable" : nil)

        for path in candidatePaths.sorted(by: >) {
            guard !Task.isCancelled else {
                return .unavailable("Local activity read was cancelled")
            }
            if remainingLineBudget == 0 || remainingByteBudget == 0 {
                importStillInProgress = true
                gapReason = gapReason
                    ?? "Local task import is still in progress"
                break
            }
            let file = fileURL(path)
            let pathWasPublished = publishedFactPaths.contains(path)
            if !reusesPublishedFacts
                || pendingFactRestorePaths.contains(path) {
                let factsBeforeRestore = files[path]?.facts.count ?? 0
                let factLoad = loadFactsIfNeeded(
                    for: path,
                    interval: interval,
                    maximumLines: remainingLineBudget,
                    maximumBytes: remainingByteBudget
                )
                switch factLoad {
                case let .ready(linesRead, factBytesRead):
                    pendingFactRestorePaths.remove(path)
                    remainingLineBudget = max(
                        remainingLineBudget - linesRead,
                        0
                    )
                    remainingByteBudget = factBytesRead
                        >= remainingByteBudget
                        ? 0
                        : remainingByteBudget - factBytesRead
                case let .partial(linesRead, factBytesRead):
                    importStillInProgress = true
                    remainingLineBudget = max(
                        remainingLineBudget - linesRead,
                        0
                    )
                    remainingByteBudget = factBytesRead
                        >= remainingByteBudget
                        ? 0
                        : remainingByteBudget - factBytesRead
                    gapReason = gapReason
                        ?? "Local task import is still in progress"
                    if reusesPublishedFacts,
                       let facts = files[path]?.facts,
                       facts.count > factsBeforeRestore {
                        appendedFacts.append(
                            contentsOf: facts[factsBeforeRestore...]
                        )
                    }
                    publishedFactPaths.insert(path)
                    continue
                case .invalid:
                    pendingFactRestorePaths.remove(path)
                    break
                }
                if reusesPublishedFacts,
                   let facts = files[path]?.facts,
                   facts.count > factsBeforeRestore {
                    appendedFacts.append(
                        contentsOf: facts[factsBeforeRestore...]
                    )
                }
                if files[path] != nil {
                    publishedFactPaths.insert(path)
                }
                if remainingLineBudget == 0 || remainingByteBudget == 0 {
                    importStillInProgress = true
                    gapReason = gapReason
                        ?? "Local task import is still in progress"
                    continue
                }
            }
            guard FileManager.default.fileExists(atPath: file.path) else {
                gapReason = gapReason ?? "Local task records are missing"
                continue
            }
            var previous = files.removeValue(forKey: path)
            do {
                if previous?.hasMalformedRecords == true {
                    gapReason = gapReason
                        ?? "Some local diagnostic records could not be read"
                }
                let requiresContextRebuild =
                    previous?.requiresContextRebuild == true
                let batch = try tail.read(
                    fileURL: file,
                    cursor: requiresContextRebuild
                        ? nil
                        : previous?.cursor,
                    observedAt: observedAt,
                    maximumLines: remainingLineBudget,
                    maximumBytes: remainingByteBudget,
                    maximumRecordBytes: Self.maximumRolloutRecordBytes
                )
                remainingLineBudget = max(
                    remainingLineBudget - batch.processedLineCount,
                    0
                )
                remainingByteBudget = batch.bytesRead
                    >= remainingByteBudget
                    ? 0
                    : remainingByteBudget - batch.bytesRead
                let (totalBytesRead, bytesOverflowed) =
                    bytesRead.addingReportingOverflow(batch.bytesRead)
                if bytesOverflowed {
                    bytesRead = .max
                    gapReason = gapReason
                        ?? "Local task record size is invalid"
                } else {
                    bytesRead = totalBytesRead
                }
                if batch.malformedRecordCount > 0 {
                    gapReason = gapReason
                        ?? "Some local diagnostic records could not be read"
                }
                if batch.hasMoreRecords {
                    importStillInProgress = true
                    gapReason = gapReason
                        ?? "Local task import is still in progress"
                }
                if batch.continuityChanged, previous != nil {
                    gapReason = gapReason
                        ?? "Local task record continuity changed"
                }
                if batch.records.isEmpty,
                   !batch.requiresRebuild,
                   previous != nil,
                   !requiresContextRebuild {
                    if batch.malformedRecordCount > 0 {
                        previous?.hasMalformedRecords = true
                    }
                    if previous?.cursor != batch.cursor {
                        previous?.cursor = batch.cursor
                        changedPaths.insert(path)
                    } else if batch.malformedRecordCount > 0 {
                        changedPaths.insert(path)
                    }
                    files[path] = previous
                    continue
                }
                let normalized = normalizer.normalize(
                    records: recordsAfterHistoryCutoff(batch.records),
                    sourceGeneration: batch.cursor.sourceGeneration,
                    observedAt: observedAt,
                    previousState: batch.requiresRebuild
                        || requiresContextRebuild
                        ? nil
                        : previous?.normalization
                )
                let rewritesFacts = batch.requiresRebuild
                    || requiresContextRebuild
                    || previous == nil
                let rewritesPublishedFacts = rewritesFacts
                    && pathWasPublished
                let newFacts: [LocalActivityFact]
                if rewritesFacts {
                    newFacts = factsAfterHistoryCutoff(normalized.facts)
                } else {
                    let existingEventIDs = previous?.eventIDs ?? []
                    newFacts = factsAfterHistoryCutoff(
                        normalized.facts
                    ).filter { fact in
                        guard let eventID = fact.eventID else { return false }
                        return !existingEventIDs.contains(eventID)
                    }
                }
                let discontinuityAt = batch.continuityChanged
                    && previous != nil
                    && !requiresContextRebuild
                    ? observedAt
                    : previous?.discontinuityAt
                let hasMalformedRecords = batch.requiresRebuild
                    ? batch.malformedRecordCount > 0
                    : previous?.hasMalformedRecords == true
                        || batch.malformedRecordCount > 0
                if rewritesFacts {
                    let activityBounds = tokenActivityBounds(newFacts)
                    previous = FileState(
                        cursor: batch.cursor,
                        normalization: normalized.state,
                        facts: newFacts,
                        eventIDs: Set(newFacts.compactMap(\.eventID)),
                        activityStart: activityBounds?.start,
                        activityEnd: activityBounds?.end,
                        discontinuityAt: discontinuityAt,
                        hasMalformedRecords: hasMalformedRecords,
                        storageFingerprint: previous?.storageFingerprint,
                        factsLoaded: true,
                        requiresContextRebuild: false,
                        factRestoreOffset: 0,
                        factRestoreFileSize: nil,
                        restoredFactIdentities: []
                    )
                } else {
                    let hadAllFacts = previous?.factsLoaded == true
                    previous?.cursor = batch.cursor
                    previous?.normalization = normalized.state
                    if hadAllFacts {
                        previous?.facts.append(contentsOf: newFacts)
                    }
                    previous?.eventIDs.formUnion(
                        newFacts.compactMap(\.eventID)
                    )
                    if let bounds = tokenActivityBounds(newFacts) {
                        let activityStart = previous?.activityStart
                        let activityEnd = previous?.activityEnd
                        previous?.activityStart = activityStart
                            .map { min($0, bounds.start) }
                            ?? bounds.start
                        previous?.activityEnd = activityEnd
                            .map { max($0, bounds.end) }
                            ?? bounds.end
                    }
                    previous?.discontinuityAt = discontinuityAt
                    previous?.hasMalformedRecords = hasMalformedRecords
                    previous?.factsLoaded = hadAllFacts
                    previous?.requiresContextRebuild = false
                }
                files[path] = previous
                publishedFactPaths.insert(path)
                factsChanged = factsChanged
                    || rewritesFacts
                    || !newFacts.isEmpty
                rewroteFacts = rewroteFacts || rewritesPublishedFacts
                if !rewritesPublishedFacts {
                    appendedFacts.append(contentsOf: newFacts)
                }
                changedPaths.insert(path)
                scheduleFactWrite(
                    path: path,
                    facts: newFacts,
                    rewritesFile: rewritesFacts
                )
            } catch {
                files[path] = previous
                gapReason = gapReason ?? "Local task records are missing"
            }
        }

        let activeStates = candidatePaths.compactMap { files[$0] }
        if activeStates.contains(where: {
            guard let discontinuityAt = $0.discontinuityAt else {
                return false
            }
            return discontinuityAt >= interval.start
                && discontinuityAt <= interval.end
        }) {
            gapReason = "Local task record continuity changed"
        }
        let activeTaskIDs = taskIDs(in: activeStates)
        let projectionChainsBefore = projectionChainIdentities(
            for: activeTaskIDs,
            using: projectionsBeforeRefresh
        )
        if await completeProjections(
            for: activeTaskIDs,
            listSucceeded: refreshMetadata ? listSucceeded : true,
            generation: currentStateGeneration,
            refreshGeneration: currentRefreshGeneration,
            retriesMissingProjections: refreshMetadata
        ) == false {
            gapReason = gapReason ?? "Local task metadata is incomplete"
        }
        guard !Task.isCancelled else {
            return .unavailable("Local activity read was cancelled")
        }
        if projectionChainsBefore != projectionChainIdentities(
            for: activeTaskIDs
        ) {
            markFilesChanged(for: activeTaskIDs)
        }
        guard currentStateGeneration == stateGeneration,
              currentRefreshGeneration == refreshGeneration else {
            return .unavailable("Account changed during local activity read")
        }
        if activeStates.contains(where: {
            $0.activityStart != nil && taskID(in: $0) == nil
        }) {
            gapReason = gapReason ?? "Local task identity is missing"
        }
        let versions = Set(
            activeStates
                .map(\.normalization.sourceVersion)
                .filter { $0 != "unknown" }
        )
        let hasTokenFacts = activeStates.contains { $0.activityStart != nil }
        if hasTokenFacts {
            let installedVersion: String?
            if refreshMetadata || !didReadInstalledCLIVersion {
                installedVersion = await installedCLIVersion?()
                guard !Task.isCancelled else {
                    return .unavailable("Local activity read was cancelled")
                }
                guard currentStateGeneration == stateGeneration,
                      currentRefreshGeneration == refreshGeneration else {
                    return .unavailable(
                        "Account changed during local activity read"
                    )
                }
                cachedInstalledCLIVersion = installedVersion
                didReadInstalledCLIVersion = true
            } else {
                installedVersion = cachedInstalledCLIVersion
            }
            guard currentStateGeneration == stateGeneration,
                  currentRefreshGeneration == refreshGeneration else {
                return .unavailable("Account changed during local activity read")
            }
            if versions.isEmpty {
                gapReason = gapReason ?? "Codex CLI version is unavailable"
            } else if installedCLIVersion != nil,
                      installedVersion == nil {
                gapReason = gapReason
                    ?? "Installed Codex CLI version is unavailable"
            } else if let installedVersion,
                      installedVersion != "0.145.0"
                        || versions != Set([installedVersion]) {
                gapReason = gapReason
                    ?? "This Codex CLI version has not been checked"
            } else if versions != Set(["0.145.0"]) {
                gapReason = gapReason
                    ?? "This Codex CLI version has not been checked"
            }
        }
        let version = versions.sorted().first ?? "unknown"
        var activeProjectionIDs = activeTaskIDs.reduce(
            into: Set<String>()
        ) { result, taskID in
            result.formUnion(projectionChainIDs(for: taskID))
        }
        let activeRootIDs = Set(
            activeTaskIDs.compactMap(projectionRootID)
        )
        for projection in currentProjections
        where projectionRootID(for: projection.taskID).map(
            activeRootIDs.contains
        ) == true {
            activeProjectionIDs.formUnion(
                projectionChainIDs(for: projection.taskID)
            )
        }
        let activeProjections = activeProjectionIDs.compactMap {
            projections[$0]
        }.sorted {
            $0.taskID < $1.taskID
        }.map(\.withoutRolloutFileURL)
        let activeProjectionIdentities = activeProjections.map {
            ProjectionIdentity(
                taskID: $0.taskID,
                parentTaskID: $0.parentTaskID,
                projectLabel: $0.projectLabel,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }
        guard currentStateGeneration == stateGeneration,
              currentRefreshGeneration == refreshGeneration else {
            return .unavailable("Account changed during local activity read")
        }
        guard !Task.isCancelled else {
            return .unavailable("Local activity read was cancelled")
        }
        let persisted = persist()
        projections = projections.filter {
            activeProjectionIDs.contains($0.key)
        }
        attemptedProjectionTaskIDs.formIntersection(activeProjectionIDs)
        if !persisted {
            gapReason = gapReason ?? "Local activity could not be saved"
        }
        let factsWereRebuilt: Bool
        let mergedFacts: [LocalActivityFact]
        if reusesPublishedFacts, !rewroteFacts {
            var currentFacts = cachedFacts ?? []
            cachedFacts = nil
            if !appendedFacts.isEmpty {
                currentFacts.append(
                    contentsOf: factsForActiveInterval(
                        appendedFacts,
                        interval: interval
                    )
                )
            }
            cachedFacts = currentFacts
            mergedFacts = currentFacts
            factsWereRebuilt = false
        } else {
            if rewroteFacts {
                pendingFactRestorePaths.formUnion(
                    candidatePaths.filter {
                        files[$0]?.factsLoaded == false
                    }
                )
                for path in candidatePaths.sorted(by: >)
                where files[path]?.factsLoaded == false {
                    guard !Task.isCancelled else {
                        return .unavailable(
                            "Local activity read was cancelled"
                        )
                    }
                    guard remainingLineBudget > 0,
                          remainingByteBudget > 0 else {
                        importStillInProgress = true
                        gapReason = gapReason
                            ?? "Local task import is still in progress"
                        continue
                    }
                    let outcome = loadFactsIfNeeded(
                        for: path,
                        interval: interval,
                        maximumLines: remainingLineBudget,
                        maximumBytes: remainingByteBudget
                    )
                    let read: (Int, UInt64)
                    switch outcome {
                    case let .ready(linesRead, factBytesRead),
                         let .partial(linesRead, factBytesRead):
                        read = (linesRead, factBytesRead)
                    case .invalid:
                        pendingFactRestorePaths.remove(path)
                        gapReason = gapReason
                            ?? "Saved local activity could not be read"
                        continue
                    }
                    remainingLineBudget = max(
                        remainingLineBudget - read.0,
                        0
                    )
                    remainingByteBudget = read.1 >= remainingByteBudget
                        ? 0
                        : remainingByteBudget - read.1
                    if case .partial = outcome {
                        importStillInProgress = true
                        gapReason = gapReason
                            ?? "Local task import is still in progress"
                    } else {
                        pendingFactRestorePaths.remove(path)
                    }
                }
            }
            var rebuiltFacts: [LocalActivityFact] = []
            for path in candidatePaths.sorted() {
                guard let facts = files[path]?.facts else { continue }
                rebuiltFacts.append(
                    contentsOf: facts.lazy.filter {
                        self.isFactActive($0, in: interval)
                    }
                )
            }
            mergedFacts = rebuiltFacts
            cachedFacts = mergedFacts
            publishedFactPaths = Set(candidatePaths.filter {
                guard let state = files[$0] else { return false }
                return state.factsLoaded || state.factRestoreOffset > 0
            })
            cachedFactPaths = candidatePaths
            cachedFactsIntervalStart = interval.start
            factsWereRebuilt = true
        }
        if reusesPublishedFacts, !rewroteFacts {
            cachedFactPaths = candidatePaths
            cachedFactsIntervalStart = interval.start
        }
        let observation: LocalActivityObservation = gapReason.map {
            .gap(
                sourceVersion: version,
                observedAt: observedAt,
                reason: $0
            )
        } ?? .continuous(
            sourceVersion: version,
            observedAt: observedAt
        )
        let observationSignature = ObservationSignature(
            sourceVersion: version == "unknown" ? nil : version,
            reason: observation.reason,
            coverage: observation.coverage
        )
        if factsWereRebuilt
            || factsChanged
            || !appendedFacts.isEmpty
            || lastPublishedProjectionIdentities != activeProjectionIdentities
            || lastObservationSignature != observationSignature {
            advanceContentRevision()
        }
        lastPublishedProjectionIdentities = activeProjectionIdentities
        lastObservationSignature = observationSignature
        if persisted {
            unloadPersistedFacts(activePaths: candidatePaths)
        }
        importContinuationPending = importStillInProgress
        return LocalActivityCollection(
            facts: mergedFacts,
            projections: activeProjections,
            observation: observation,
            bytesRead: bytesRead,
            contentRevision: contentRevision
        )
    }

    func refreshStoredTokenActivity(
        interval: DateInterval,
        filters: WorkspaceFilters = .all,
        observedAt: Date = Date()
    ) async -> LocalStoredTokenActivityCollection {
        autoreleasepool {
            refreshStoredTokenActivitySync(
                interval: interval,
                filters: filters,
                observedAt: observedAt
            )
        }
    }

    private func refreshStoredTokenActivitySync(
        interval: DateInterval,
        filters: WorkspaceFilters,
        observedAt: Date
    ) -> LocalStoredTokenActivityCollection {
        guard !historyDeletionPending else {
            return unavailableStoredTokenActivity(
                deletionMarkerInvalid
                    ? "Saved deletion state could not be read"
                    : "Analytics history deletion is pending",
                interval: interval
            )
        }
        guard interval.start < interval.end else {
            return unavailableStoredTokenActivity(
                "Weekly token interval is unavailable",
                interval: interval
            )
        }
        do {
            let store = try openStoredTokenStore()
            var result = try importStoredTokenFacts(
                into: store,
                interval: interval
            )
            if result.bytesRead > 0, !result.importPending {
                result.importPending = true
                result.gapReason = result.gapReason
                    ?? "Local task import is still in progress"
            } else if !result.importPending {
                result.merge(
                    try refreshStoredTokenRolloutTail(
                        in: interval,
                        observedAt: observedAt,
                        store: store
                    )
                )
            }
            guard result.hasSources else {
                return unavailableStoredTokenActivity(
                    "No saved local activity is available",
                    interval: interval
                )
            }
            if result.importPending {
                let reason = "Local task import is still in progress"
                let version = result.sourceVersions.sorted().first ?? "unknown"
                return LocalStoredTokenActivityCollection(
                    snapshot: .unavailable(reason, interval: interval),
                    filterOptions: UsageReceiptFilterOptions(
                        projects: [],
                        taskTrees: [],
                        models: [],
                        reasoningLevels: []
                    ),
                    observation: .gap(
                        sourceVersion: version,
                        observedAt: observedAt,
                        reason: reason
                    ),
                    bytesRead: result.bytesRead,
                    importPending: true
                )
            }
            if !result.importPending, result.gapReason == nil {
                if result.sourceVersions.isEmpty {
                    result.gapReason = "Codex CLI version is unavailable"
                } else if result.sourceVersions != Set(["0.145.0"]) {
                    result.gapReason =
                        "This Codex CLI version has not been checked"
                } else {
                    result.gapReason = "Local task discovery is incomplete"
                }
            }
            let version = result.sourceVersions.sorted().first ?? "unknown"
            let observation: LocalActivityObservation
            if let reason = result.gapReason {
                observation = .gap(
                    sourceVersion: version,
                    observedAt: observedAt,
                    reason: reason
                )
            } else {
                observation = .continuous(
                    sourceVersion: version,
                    observedAt: observedAt
                )
            }
            let cacheKey = StoredTokenCacheKey(
                interval: interval,
                filters: filters
            )
            if result.bytesRead == 0,
               let cached = storedTokenCache,
               cached.key == cacheKey {
                return LocalStoredTokenActivityCollection(
                    snapshot: cached.snapshot.updating(
                        interval: interval,
                        observation: observation
                    ),
                    filterOptions: cached.filterOptions,
                    observation: observation,
                    bytesRead: 0,
                    importPending: false
                )
            }
            let snapshot = try store.tokenActivity(
                in: interval,
                filters: filters,
                observation: observation
            )
            let filterOptions: UsageReceiptFilterOptions
            if result.bytesRead == 0,
               let cached = storedFilterOptionsCache,
               cached.interval.start <= interval.start,
               cached.interval.end >= interval.end {
                filterOptions = cached.options
            } else {
                filterOptions = try store.filterOptions(in: interval)
                storedFilterOptionsCache = StoredFilterOptionsCache(
                    interval: interval,
                    options: filterOptions
                )
            }
            storedTokenCache = StoredTokenCache(
                key: cacheKey,
                snapshot: snapshot,
                filterOptions: filterOptions
            )
            return LocalStoredTokenActivityCollection(
                snapshot: snapshot,
                filterOptions: filterOptions,
                observation: observation,
                bytesRead: result.bytesRead,
                importPending: result.importPending
            )
        } catch is CancellationError {
            return unavailableStoredTokenActivity(
                "Local activity read was cancelled",
                interval: interval
            )
        } catch {
            return unavailableStoredTokenActivity(
                "Saved local activity could not be read",
                interval: interval
            )
        }
    }

    private struct StoredTokenImportResult {
        var bytesRead: UInt64 = 0
        var importPending = false
        var hasSources = false
        var sourceVersions = Set<String>()
        var gapReason: String?

        mutating func merge(_ other: StoredTokenImportResult) {
            bytesRead += other.bytesRead
            importPending = importPending || other.importPending
            hasSources = hasSources || other.hasSources
            sourceVersions.formUnion(other.sourceVersions)
            if let reason = other.gapReason {
                recordGap(reason)
            }
        }

        mutating func recordGap(_ reason: String) {
            guard Self.gapPriority(reason) > Self.gapPriority(gapReason)
            else {
                return
            }
            gapReason = reason
        }

        private static func gapPriority(_ reason: String?) -> Int {
            switch reason {
            case "Local task record continuity changed":
                3
            case "Some local diagnostic records could not be read":
                2
            case nil:
                0
            default:
                1
            }
        }
    }

    private func importStoredTokenFacts(
        into store: LocalActivityStore,
        interval: DateInterval
    ) throws -> StoredTokenImportResult {
        guard let directory = stateURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return StoredTokenImportResult()
        }
        var result = StoredTokenImportResult()
        var remainingLines = Self.maximumStoredRefreshLines
        var remainingBytes = Self.maximumStoredRefreshBytes
        for entry in entries.sorted(by: { $0.path < $1.path })
        where entry.pathExtension == "json" {
            guard let data = Self.readMetadata(at: entry),
                  let persisted = try? JSONDecoder().decode(
                      PersistedFile.self,
                      from: data
                  ),
                  [4, 5, 6, 7].contains(persisted.version) else {
                result.recordGap("Saved local activity could not be read")
                continue
            }
            if let activityStart = persisted.activityStart,
               let activityEnd = persisted.activityEnd,
               activityStart >= interval.end || activityEnd < interval.start {
                continue
            }
            if let discontinuityAt = persisted.discontinuityAt,
               discontinuityAt >= interval.start,
               discontinuityAt <= interval.end {
                result.recordGap("Local task record continuity changed")
            } else if persisted.hasMalformedRecords == true,
                      persisted.activityStart.map({ $0 < interval.end })
                        ?? false,
                      persisted.activityEnd.map({ $0 >= interval.start })
                        ?? false {
                result.recordGap(
                    "Some local diagnostic records could not be read"
                )
            }
            if persisted.normalization.sourceVersion != "unknown" {
                result.sourceVersions.insert(
                    persisted.normalization.sourceVersion
                )
            }
            let fingerprint = entry.deletingPathExtension().lastPathComponent
            let factsFile = factsURL(
                forFingerprint: fingerprint,
                in: directory
            )
            guard var source = try storedSource(
                key: fingerprint,
                persisted: persisted,
                factsFile: factsFile
            ) else {
                result.recordGap("Saved local activity could not be read")
                continue
            }
            result.hasSources = true
            if try store.hasActiveSource(matching: source) {
                continue
            }
            guard remainingLines > 0, remainingBytes > 0 else {
                result.importPending = true
                break
            }
            let replacement: Int64
            if let resumed = try store.resumableReplacement(matching: source) {
                replacement = resumed.storeGeneration
                source = resumed.source
            } else {
                replacement = try store.beginReplacement(for: source)
            }
            let storedProjections = (
                [persisted.projection].compactMap { $0 }
                    + (persisted.ancestorProjections ?? [])
            ).map(\.withoutRolloutFileURL)
            do {
                let step = try readStoredTokenFacts(
                    from: factsFile,
                    source: source,
                    maximumLines: remainingLines,
                    maximumBytes: remainingBytes
                )
                source = step.source
                try store.appendReplacementTokenFacts(
                    step.facts,
                    to: source,
                    storeGeneration: replacement,
                    projections: storedProjections
                )
                remainingLines = max(
                    remainingLines - step.linesRead,
                    0
                )
                remainingBytes = step.bytesRead >= remainingBytes
                    ? 0
                    : remainingBytes - step.bytesRead
                let total = result.bytesRead.addingReportingOverflow(
                    step.bytesRead
                )
                result.bytesRead = total.overflow ? .max : total.partialValue
                if step.complete {
                    try store.activateReplacement(
                        sourceKey: source.key,
                        storeGeneration: replacement
                    )
                } else {
                    result.importPending = true
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? store.rollbackReplacement(
                    sourceKey: source.key,
                    storeGeneration: replacement
                )
                result.recordGap("Saved local activity could not be read")
            }
        }
        return result
    }

    private func refreshStoredTokenRolloutTail(
        in interval: DateInterval,
        observedAt: Date,
        store: LocalActivityStore
    ) throws -> StoredTokenImportResult {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return StoredTokenImportResult(
                gapReason: "Codex local records are unavailable"
            )
        }
        let discoveryInterval = DateInterval(
            start: interval.start.addingTimeInterval(-86_400),
            end: interval.end
        )
        let paths = Set(
            storedRolloutFiles(in: discoveryInterval).compactMap(fileKey)
        )
        guard !paths.isEmpty else {
            return StoredTokenImportResult()
        }
        var result = StoredTokenImportResult(hasSources: true)
        var remainingLines = Self.maximumStoredRefreshLines
        var remainingBytes = Self.maximumStoredRefreshBytes

        for path in paths.sorted(by: >) {
            try Task.checkCancellation()
            guard remainingLines > 0, remainingBytes > 0 else {
                result.importPending = true
                result.recordGap("Local task import is still in progress")
                break
            }
            let file = fileURL(path)
            let sourceKey = stateFileName(for: path)
            let previousSource = try store.activeSource(key: sourceKey)
            let previousCursor: RolloutCursor?
            let previousNormalization: LocalActivityNormalizationState?
            if let previousSource {
                guard let cursorData = previousSource.cursorJSON,
                      let normalizationData =
                          previousSource.normalizationJSON,
                      let cursor = try? JSONDecoder().decode(
                          RolloutCursor.self,
                          from: cursorData
                      ),
                      let normalization = try? JSONDecoder().decode(
                          LocalActivityNormalizationState.self,
                          from: normalizationData
                      ) else {
                    result.recordGap("Saved local activity could not be read")
                    continue
                }
                previousCursor = cursor
                previousNormalization = normalization
            } else {
                previousCursor = nil
                previousNormalization = nil
            }
            if previousSource?.discontinuityAt != nil {
                if let version = previousNormalization?.sourceVersion,
                   version != "unknown" {
                    result.sourceVersions.insert(version)
                }
                result.recordGap("Local task record continuity changed")
                continue
            }
            let batch: RolloutTailBatch
            do {
                batch = try tail.read(
                    fileURL: file,
                    cursor: previousCursor,
                    observedAt: observedAt,
                    recordScope: .tokenActivity,
                    maximumLines: remainingLines,
                    maximumBytes: remainingBytes,
                    maximumRecordBytes:
                        Self.maximumStoredRolloutRecordBytes
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.recordGap("Local task records are missing")
                continue
            }
            remainingLines = max(
                remainingLines - batch.processedLineCount,
                0
            )
            remainingBytes = batch.bytesRead >= remainingBytes
                ? 0
                : remainingBytes - batch.bytesRead
            result.bytesRead += batch.bytesRead
            if batch.malformedRecordCount > 0 {
                result.recordGap(
                    "Some local diagnostic records could not be read"
                )
            }
            if previousSource != nil,
               batch.requiresRebuild || batch.continuityChanged {
                if var previousSource {
                    previousSource.discontinuityAt = observedAt
                    try store.appendTokenFacts([], to: previousSource)
                }
                result.recordGap("Local task record continuity changed")
                continue
            }
            if batch.hasMoreRecords {
                result.importPending = true
                result.recordGap("Local task import is still in progress")
            }
            if batch.records.isEmpty,
               batch.cursor == previousCursor,
               batch.malformedRecordCount == 0 {
                if let version = previousNormalization?.sourceVersion,
                   version != "unknown" {
                    result.sourceVersions.insert(version)
                }
                continue
            }
            captureRolloutProjections(
                batch.records,
                sourceGeneration: batch.cursor.sourceGeneration,
                observedAt: observedAt
            )
            let normalized = normalizer.normalize(
                records: recordsAfterHistoryCutoff(batch.records),
                sourceGeneration: batch.cursor.sourceGeneration,
                observedAt: observedAt,
                previousState: previousNormalization
            )
            if normalized.state.sourceVersion != "unknown" {
                result.sourceVersions.insert(normalized.state.sourceVersion)
            }
            let newFacts = factsAfterHistoryCutoff(normalized.facts).filter {
                $0.key == .token
                    && $0.availability == .available
                    && $0.eventID != nil
            }
            var source = previousSource ?? LocalActivityStore.Source(
                key: sourceKey,
                sourceGeneration: batch.cursor.sourceGeneration
            )
            source.cursorJSON = try JSONEncoder().encode(batch.cursor)
            source.normalizationJSON = try JSONEncoder().encode(
                normalized.state
            )
            source.hasMalformedRecords =
                source.hasMalformedRecords || batch.malformedRecordCount > 0
            if let bounds = tokenActivityBounds(newFacts) {
                source.activityStart = source.activityStart.map {
                    min($0, bounds.start)
                } ?? bounds.start
                source.activityEnd = source.activityEnd.map {
                    max($0, bounds.end)
                } ?? bounds.end
            }
            let storedProjections =
                normalized.state.context?.taskID.map {
                    projectionChainIDs(for: $0).compactMap {
                        projections[$0]?.withoutRolloutFileURL
                    }
                } ?? []
            try store.append(
                newFacts,
                to: source,
                projections: storedProjections
            )
        }
        return result
    }

    private func storedSource(
        key: String,
        persisted: PersistedFile,
        factsFile: URL
    ) throws -> LocalActivityStore.Source? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: factsFile.path
        ),
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
        let size = (attributes[.size] as? NSNumber)?.uint64Value,
        let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        var source = LocalActivityStore.Source(
            key: key,
            sourceGeneration: persisted.cursor.sourceGeneration
        )
        source.cursorJSON = try JSONEncoder().encode(persisted.cursor)
        source.normalizationJSON = try JSONEncoder().encode(
            persisted.normalization
        )
        source.activityStart = persisted.activityStart
        source.activityEnd = persisted.activityEnd
        source.discontinuityAt = persisted.discontinuityAt
        source.hasMalformedRecords = persisted.hasMalformedRecords ?? false
        source.legacyDevice = device
        source.legacyInode = inode
        source.legacyOffset = 0
        source.legacySize = size
        source.legacyModificationDate = modificationDate
        return source
    }

    private func readStoredTokenFacts(
        from file: URL,
        source: LocalActivityStore.Source,
        maximumLines: Int,
        maximumBytes: UInt64
    ) throws -> (
        facts: [LocalActivityStore.TokenFact],
        source: LocalActivityStore.Source,
        linesRead: Int,
        bytesRead: UInt64,
        complete: Bool
    ) {
        guard let fileSize = source.legacySize,
              let handle = try? FileHandle(forReadingFrom: file) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        let checkpoint: StoredTokenImportCheckpoint
        if let data = source.pendingFactJSON {
            checkpoint = try decoder.decode(
                StoredTokenImportCheckpoint.self,
                from: data
            )
        } else {
            checkpoint = StoredTokenImportCheckpoint(
                retainedTokenAfterCutoff: false
            )
        }
        var retainedTokenAfterCutoff =
            checkpoint.retainedTokenAfterCutoff
        var facts: [LocalActivityStore.TokenFact] = []
        var valid = true
        let read = try BoundedJSONLReader.read(
            handle: handle,
            from: source.legacyOffset ?? 0,
            maximumLines: maximumLines,
            maximumBytes: maximumBytes,
            maximumRecordBytes: Self.maximumMetadataBytes,
            discardsPartialRecordAtByteLimit: false
        ) { line, _ in
            guard let decoded = autoreleasepool(invoking: {
                try? decoder.decode(
                    StoredTokenFactProjection.self,
                    from: line
                )
            }) else {
                valid = false
                return false
            }
            guard decoded.key == .token,
                  decoded.availability == .available,
                  let eventID = decoded.eventID,
                  !eventID.isEmpty,
                  let timestamp = decoded.eventTimestamp,
                  let occurredAt = parseTimestamp(timestamp),
                  historyCutoff.map({ occurredAt >= $0 }) ?? true else {
                return true
            }
            var numericDelta = decoded.numericDelta
            var reason = decoded.reason
            if historyCutoff != nil,
               !retainedTokenAfterCutoff {
                numericDelta = nil
                reason = reason ?? "segment-baseline"
                retainedTokenAfterCutoff = true
            }
            facts.append(
                LocalActivityStore.TokenFact(
                    eventID: eventID,
                    occurredAt: occurredAt,
                    numericDelta: numericDelta,
                    reason: reason,
                    sourceGeneration: decoded.source.sourceGeneration,
                    taskID: decoded.context?.taskID,
                    effectiveModel: decoded.context?.effectiveModel,
                    reasoning: decoded.context?.reasoning
                )
            )
            return true
        }
        guard valid, read.oversizedRecordCount == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let complete = read.completeByteOffset == fileSize
        guard complete || read.stoppedEarly else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var updated = source
        if complete {
            updated.legacyOffset = fileSize
            updated.pendingFactJSON = nil
        } else {
            updated.legacyOffset = read.resumeByteOffset
            updated.pendingFactJSON = try JSONEncoder().encode(
                StoredTokenImportCheckpoint(
                    retainedTokenAfterCutoff: retainedTokenAfterCutoff
                )
            )
        }
        return (
            facts,
            updated,
            read.processedLineCount,
            read.bytesRead,
            complete
        )
    }

    private func openStoredTokenStore() throws -> LocalActivityStore {
        guard partitionID != nil, let directory = stateURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        if let storedTokenStore {
            return storedTokenStore
        }
        let file = directory.appendingPathComponent(
            "local-activity-v1.sqlite3"
        )
        do {
            let store = try LocalActivityStore(
                fileURL: file,
                historyCutoff: historyCutoff
            )
            storedTokenStore = store
            return store
        } catch let error as LocalActivityStore.StoreError
        where error == .historyCutoffMismatch || error == .schemaMismatch {
            for candidate in [
                file,
                URL(fileURLWithPath: file.path + "-wal"),
                URL(fileURLWithPath: file.path + "-shm"),
                URL(fileURLWithPath: file.path + "-journal")
            ] where FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.removeItem(at: candidate)
            }
            let store = try LocalActivityStore(
                fileURL: file,
                historyCutoff: historyCutoff
            )
            storedTokenStore = store
            return store
        }
    }

    private func closeStoredTokenStore() {
        storedTokenStore?.close()
        storedTokenStore = nil
        storedTokenCache = nil
        storedFilterOptionsCache = nil
    }

    private func unavailableStoredTokenActivity(
        _ reason: String,
        interval: DateInterval
    ) -> LocalStoredTokenActivityCollection {
        LocalStoredTokenActivityCollection(
            snapshot: .unavailable(reason, interval: interval),
            filterOptions: UsageReceiptFilterOptions(
                projects: [],
                taskTrees: [],
                models: [],
                reasoningLevels: []
            ),
            observation: .unavailable(reason),
            bytesRead: 0,
            importPending: false
        )
    }

    private func advanceContentRevision() {
        contentRevision = nextRevision(after: contentRevision)
    }

    func hasPendingImport() -> Bool {
        importContinuationPending
    }

    func releaseCachedFacts() {
        refreshGeneration = nextRevision(after: refreshGeneration)
        guard stateURL != nil else { return }
        if !changedPaths.isEmpty, !persist() {
            return
        }
        guard changedPaths.isEmpty,
              pendingFactWrites.isEmpty else {
            return
        }
        restartPartialFactRestores()
        clearPublishedContent()
        unloadPersistedFacts(activePaths: [])
    }

    func deleteHistory(at deletedAt: Date = Date()) throws {
        historyCutoff = deletedAt
        historyDeletionPending = stateDirectory != nil
        deletionMarkerInvalid = false
        if let stateDirectory {
            try persistDeletionMarker(
                cutoff: deletedAt,
                cleanupPending: true,
                for: stateDirectory
            )
        }
        closeStoredTokenStore()
        stateGeneration = nextRevision(after: stateGeneration)
        files.removeAll()
        restoredFilesByFingerprint.removeAll()
        restoredFingerprintByIdentity.removeAll()
        projections.removeAll()
        changedPaths.removeAll()
        pendingFactWrites.removeAll()
        nextProjectionListCursor = nil
        hasStartedProjectionList = false
        hasCompleteProjectionList = false
        restoreWarning = nil
        clearPublishedContent()
        guard let stateDirectory else { return }
        if FileManager.default.fileExists(atPath: stateDirectory.path) {
            try FileManager.default.removeItem(at: stateDirectory)
        }
        try persistDeletionMarker(
            cutoff: deletedAt,
            cleanupPending: false,
            for: stateDirectory
        )
        historyDeletionPending = false
    }

    func restorePendingHistoryDeletion(at cutoff: Date) {
        guard !historyDeletionPending else { return }
        historyCutoff = cutoff
        historyDeletionPending = stateDirectory != nil
    }

    func retryHistoryDeletion(at retriedAt: Date = Date()) throws {
        guard historyDeletionPending,
              let stateDirectory else {
            return
        }
        let cutoff = deletionMarkerInvalid
            ? retriedAt
            : (historyCutoff ?? retriedAt)
        try persistDeletionMarker(
            cutoff: cutoff,
            cleanupPending: true,
            for: stateDirectory
        )
        historyCutoff = cutoff
        deletionMarkerInvalid = false
        closeStoredTokenStore()
        stateGeneration = nextRevision(after: stateGeneration)
        files.removeAll()
        restoredFilesByFingerprint.removeAll()
        restoredFingerprintByIdentity.removeAll()
        projections.removeAll()
        changedPaths.removeAll()
        pendingFactWrites.removeAll()
        nextProjectionListCursor = nil
        hasStartedProjectionList = false
        hasCompleteProjectionList = false
        restoreWarning = nil
        clearPublishedContent()
        if FileManager.default.fileExists(atPath: stateDirectory.path) {
            try FileManager.default.removeItem(at: stateDirectory)
        }
        try persistDeletionMarker(
            cutoff: cutoff,
            cleanupPending: false,
            for: stateDirectory
        )
        historyDeletionPending = false
    }

    func hasPendingHistoryDeletion() -> Bool {
        historyDeletionPending
    }

    func rebuildHistory() throws {
        closeStoredTokenStore()
        if let stateDirectory {
            if FileManager.default.fileExists(atPath: stateDirectory.path) {
                try FileManager.default.removeItem(at: stateDirectory)
            }
            if let markerURL = deletionMarkerURL(for: stateDirectory),
               FileManager.default.fileExists(atPath: markerURL.path) {
                try FileManager.default.removeItem(at: markerURL)
            }
        }
        stateGeneration = nextRevision(after: stateGeneration)
        files.removeAll()
        restoredFilesByFingerprint.removeAll()
        restoredFingerprintByIdentity.removeAll()
        projections.removeAll()
        changedPaths.removeAll()
        pendingFactWrites.removeAll()
        nextProjectionListCursor = nil
        hasStartedProjectionList = false
        hasCompleteProjectionList = false
        restoreWarning = nil
        clearPublishedContent()
        historyCutoff = nil
        historyDeletionPending = false
        deletionMarkerInvalid = false
    }

    private func rolloutFiles(
        in interval: DateInterval,
        maximumDays: Int = 14
    ) -> Set<URL> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var date = calendar.startOfDay(for: interval.start)
        let end = calendar.startOfDay(for: interval.end)
        var result = Set<URL>()

        for _ in 0 ..< max(maximumDays, 1) where date <= end {
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: date
            )
            let directory = rootDirectory
                .appendingPathComponent(
                    String(format: "%04d", components.year ?? 0),
                    isDirectory: true
                )
                .appendingPathComponent(
                    String(format: "%02d", components.month ?? 0),
                    isDirectory: true
                )
                .appendingPathComponent(
                    String(format: "%02d", components.day ?? 0),
                    isDirectory: true
                )
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                result.formUnion(entries.filter {
                    $0.lastPathComponent.hasPrefix("rollout-")
                        && $0.pathExtension == "jsonl"
                })
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date)
            else { break }
            date = next
        }
        return result
    }

    private func storedRolloutFiles(
        in interval: DateInterval
    ) -> Set<URL> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let end = calendar.startOfDay(for: interval.end)
        guard let start = calendar.date(
            byAdding: .day,
            value: -85,
            to: end
        ) else {
            return []
        }
        return rolloutFiles(
            in: DateInterval(start: start, end: end),
            maximumDays: 86
        ).filter {
            guard let modified = try? $0.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else {
                return true
            }
            return modified >= interval.start
        }
    }

    private func taskIDs(in states: [FileState]) -> Set<String> {
        Set(states.compactMap(taskID(in:)))
    }

    private func refreshProjectionList(
        generation: UInt64,
        refreshGeneration: UInt64
    ) async -> Bool? {
        guard let projectionSource else { return nil }
        let hadStarted = hasStartedProjectionList
        do {
            let newestPage = try await projectionSource.list(
                cursor: nil,
                limit: 100
            )
            guard generation == stateGeneration,
                  refreshGeneration == self.refreshGeneration else {
                return nil
            }
            for projection in newestPage.tasks {
                projections[projection.taskID] = projection
            }
            if !hadStarted {
                hasStartedProjectionList = true
                nextProjectionListCursor = newestPage.nextCursor
                if newestPage.nextCursor == nil {
                    hasCompleteProjectionList = true
                }
            }
        } catch {
            return false
        }

        guard !hasCompleteProjectionList else { return true }
        let pageLimit = hadStarted ? 1 : 3
        for _ in 0 ..< pageLimit {
            guard let cursor = nextProjectionListCursor else {
                hasCompleteProjectionList = true
                return true
            }
            do {
                let page = try await projectionSource.list(
                    cursor: cursor,
                    limit: 100
                )
                guard generation == stateGeneration,
                      refreshGeneration == self.refreshGeneration else {
                    return nil
                }
                for projection in page.tasks {
                    projections[projection.taskID] = projection
                }
                guard let nextCursor = page.nextCursor else {
                    nextProjectionListCursor = nil
                    hasCompleteProjectionList = true
                    return hasCompleteProjectionList
                }
                nextProjectionListCursor = nextCursor
            } catch {
                return false
            }
        }
        return hasCompleteProjectionList
    }

    private func completeProjections(
        for taskIDs: Set<String>,
        listSucceeded: Bool?,
        generation: UInt64,
        refreshGeneration: UInt64,
        retriesMissingProjections: Bool
    ) async -> Bool {
        guard let projectionSource else { return true }
        guard !taskIDs.isEmpty else { return true }
        var failed = false
        var pending = taskIDs.sorted()
        var inspected = Set<String>()
        var reads = 0
        while let taskID = pending.first {
            pending.removeFirst()
            guard inspected.insert(taskID).inserted else { continue }
            let mustRead = (
                projections[taskID] == nil
                    && (
                        retriesMissingProjections
                            || !attemptedProjectionTaskIDs.contains(taskID)
                    )
            ) || (
                retriesMissingProjections
                    && taskIDs.contains(taskID)
                    && listSucceeded != true
            )
            if mustRead {
                guard reads < 20 else {
                    failed = true
                    break
                }
                reads += 1
                attemptedProjectionTaskIDs.insert(taskID)
                do {
                    if let projection = try await projectionSource.read(
                        threadID: taskID
                    ) {
                        guard generation == stateGeneration,
                              refreshGeneration == self.refreshGeneration else {
                            return false
                        }
                        projections[taskID] = projection
                    } else {
                        failed = true
                    }
                } catch {
                    failed = true
                }
            }
            guard let projection = projections[taskID] else {
                failed = true
                continue
            }
            if let parentTaskID = projection.parentTaskID {
                pending.append(parentTaskID)
            }
        }
        return !failed && taskIDs.allSatisfy {
            projectionChainIsComplete(for: $0)
        }
    }

    private func projectionChainIDs(for taskID: String) -> Set<String> {
        projectionChainIDs(for: taskID, using: projections)
    }

    private func projectionChainIDs(
        for taskID: String,
        using projections: [String: ThreadProjection]
    ) -> Set<String> {
        var result = Set<String>()
        var current: String? = taskID
        while let task = current, result.insert(task).inserted {
            current = projections[task]?.parentTaskID
        }
        return result
    }

    private func projectionChainIsComplete(for taskID: String) -> Bool {
        var visited = Set<String>()
        var current: String? = taskID
        while let task = current, visited.insert(task).inserted {
            guard let projection = projections[task] else { return false }
            current = projection.parentTaskID
        }
        return current == nil
    }

    private func projectionRootID(for taskID: String) -> String? {
        var visited = Set<String>()
        var current: String? = taskID
        var last: String?
        while let task = current, visited.insert(task).inserted {
            guard let projection = projections[task] else { return nil }
            last = task
            current = projection.parentTaskID
        }
        return current == nil ? last : nil
    }

    private struct ProjectionIdentity: Equatable {
        let taskID: String
        let parentTaskID: String?
        let projectLabel: String?
        let createdAt: Date?
        let updatedAt: Date?
    }

    private func projectionChainIdentities(
        for taskIDs: Set<String>,
        using projections: [String: ThreadProjection]? = nil
    ) -> [String: [ProjectionIdentity]] {
        let source = projections ?? self.projections
        return taskIDs.reduce(into: [:]) { result, taskID in
            result[taskID] = projectionChainIDs(
                for: taskID,
                using: source
            )
                .compactMap { source[$0] }
                .map {
                    ProjectionIdentity(
                        taskID: $0.taskID,
                        parentTaskID: $0.parentTaskID,
                        projectLabel: $0.projectLabel,
                        createdAt: $0.createdAt,
                        updatedAt: $0.updatedAt
                    )
                }
                .sorted { $0.taskID < $1.taskID }
        }
    }

    private func markFilesChanged(for taskIDs: Set<String>) {
        for (path, state) in files
        where taskID(in: state).map(taskIDs.contains) == true {
            changedPaths.insert(path)
        }
    }

    private func taskID(in state: FileState) -> String? {
        state.normalization.context?.taskID ?? state.facts.compactMap { fact in
            guard fact.key == .task,
                  fact.availability == .available,
                  case let .identifier(taskID) = fact.value else {
                return nil
            }
            return taskID
        }.last
    }

    private func captureRolloutProjections(
        _ records: [RolloutRecord],
        sourceGeneration: UInt64,
        observedAt: Date
    ) {
        for record in records
        where record.type == "session_meta" {
            guard let taskID = record.threadID,
                  projections[taskID] == nil else {
                continue
            }
            let label = record.cwd.flatMap {
                let value = URL(fileURLWithPath: $0).lastPathComponent
                return value.isEmpty ? nil : value
            }
            projections[taskID] = ThreadProjection(
                taskID: taskID,
                parentTaskID: record.parentThreadID,
                projectLabel: label,
                rolloutFileURL: nil,
                createdAt: record.timestamp.flatMap(parseTimestamp),
                updatedAt: nil,
                source: LocalActivitySourceMetadata(
                    source: .rolloutJSONL,
                    sourceVersion: record.cliVersion ?? "unknown",
                    schemaVersion: "rollout-jsonl-v1",
                    sourceGeneration: sourceGeneration,
                    historyMode: record.historyMode,
                    observedAt: observedAt
                )
            )
        }
    }

    private func activeProjections(
        in interval: DateInterval
    ) -> [ThreadProjection] {
        projections.values.filter { projection in
            let activeAt = projection.updatedAt ?? projection.createdAt
            return activeAt.map {
                $0 >= interval.start && $0 < interval.end
            } ?? true
        }
    }

    private func validProjectionFile(
        _ projection: ThreadProjection
    ) -> URL? {
        let rootPath = rootDirectory.path + "/"
        guard let file = projection.rolloutFileURL?.resolvingSymlinksInPath(),
              file.path.hasPrefix(rootPath),
              file.lastPathComponent.hasPrefix("rollout-"),
              file.pathExtension == "jsonl" else {
            return nil
        }
        return file
    }

    private func stateHasActivity(
        _ state: FileState,
        in interval: DateInterval
    ) -> Bool {
        guard let start = state.activityStart,
              let end = state.activityEnd else {
            return false
        }
        return start < interval.end && end >= interval.start
    }

    private func parseTimestamp(_ value: String) -> Date? {
        timestampParser.date(from: value)
    }

    private func clearPublishedContent() {
        cachedFacts = nil
        cachedFactPaths.removeAll()
        cachedFactsIntervalStart = nil
        pendingFactRestorePaths.removeAll()
        publishedFactPaths.removeAll()
        lastProjectionListSucceeded = nil
        attemptedProjectionTaskIDs.removeAll()
        lastPublishedProjectionIdentities = nil
        lastObservationSignature = nil
        importContinuationPending = false
        storedTokenCache = nil
        storedFilterOptionsCache = nil
    }

    private func restartPartialFactRestores() {
        for path in Array(files.keys) {
            guard var state = files[path],
                  state.factRestoreFileSize != nil else {
                continue
            }
            state.facts.removeAll(keepingCapacity: false)
            state.eventIDs.removeAll(keepingCapacity: false)
            state.factsLoaded = false
            state.factRestoreOffset = 0
            state.factRestoreFileSize = nil
            state.restoredFactIdentities.removeAll(keepingCapacity: false)
            files[path] = state
        }
    }

    private func unloadPersistedFacts(activePaths: Set<String>) {
        guard let directory = stateURL else { return }
        for path in Array(files.keys) {
            guard var state = files[path],
                  !changedPaths.contains(path),
                  pendingFactWrites[path] == nil,
                  state.factsLoaded || !activePaths.contains(path) else {
                continue
            }
            let file = factsURL(
                forFingerprint: state.storageFingerprint
                    ?? stateFileName(for: path),
                in: directory
            )
            guard FileManager.default.fileExists(atPath: file.path) else {
                continue
            }
            state.facts.removeAll(keepingCapacity: false)
            if !activePaths.contains(path) {
                state.eventIDs.removeAll(keepingCapacity: false)
            }
            state.factsLoaded = false
            state.factRestoreOffset = 0
            state.factRestoreFileSize = nil
            state.restoredFactIdentities.removeAll(keepingCapacity: false)
            files[path] = state
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard !changedPaths.isEmpty else { return true }
        guard let directory = stateURL else { return true }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            for path in Array(changedPaths) {
                guard let state = files[path] else { continue }
                let storageFingerprint = state.storageFingerprint
                    ?? stateFileName(for: path)
                if let write = pendingFactWrites[path] {
                    try persistFacts(
                        write,
                        to: factsURL(
                            forFingerprint: storageFingerprint,
                            in: directory
                        )
                    )
                }
                let data = try JSONEncoder().encode(
                    PersistedFile(
                        version: 7,
                        path: nil,
                        pathFingerprint: storageFingerprint,
                        cursor: state.cursor,
                        normalization: state.normalization,
                        activityStart: state.activityStart,
                        activityEnd: state.activityEnd,
                        discontinuityAt: state.discontinuityAt,
                        hasMalformedRecords: state.hasMalformedRecords,
                        projection: state.normalization.context?.taskID.flatMap {
                            projections[$0]?.withoutRolloutFileURL
                        },
                        ancestorProjections: state.normalization.context?.taskID
                            .map { taskID in
                                projectionChainIDs(for: taskID)
                                    .subtracting([taskID])
                            }
                            .map { ancestorTaskIDs in
                                ancestorTaskIDs.compactMap {
                                    projections[$0]?.withoutRolloutFileURL
                                }
                            }
                    )
                )
                try data.write(
                    to: metadataURL(
                        forFingerprint: storageFingerprint,
                        in: directory
                    ),
                    options: .atomic
                )
                changedPaths.remove(path)
                pendingFactWrites[path] = nil
            }
            return true
        } catch {
            return false
        }
    }

    private func restore() {
        guard let directory = stateURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            if deletionMarkerInvalid {
                restoreWarning = "Saved deletion state could not be read"
            }
            return
        }
        restoreWarning = deletionMarkerInvalid
            ? "Saved deletion state could not be read"
            : nil
        var legacyPaths = Set<String>()
        for entry in entries where entry.pathExtension == "json" {
            guard let data = Self.readMetadata(at: entry),
                  let file = try? JSONDecoder().decode(
                      PersistedFile.self,
                      from: data
                  ),
                  [4, 5, 6, 7].contains(file.version) else {
                restoreWarning = "Saved local activity could not be read"
                continue
            }
            let restoredState = FileState(
                cursor: file.cursor,
                normalization: file.normalization,
                facts: [],
                eventIDs: [],
                activityStart: file.activityStart,
                activityEnd: file.activityEnd,
                discontinuityAt: file.discontinuityAt,
                hasMalformedRecords: file.hasMalformedRecords ?? false,
                storageFingerprint: entry.deletingPathExtension()
                    .lastPathComponent,
                factsLoaded: false,
                requiresContextRebuild: file.version == 4,
                factRestoreOffset: 0,
                factRestoreFileSize: nil,
                restoredFactIdentities: []
            )
            if file.version >= 6 {
                let fingerprint = entry.deletingPathExtension()
                    .lastPathComponent
                guard file.path == nil,
                      file.pathFingerprint == fingerprint else {
                    restoreWarning = "Saved local activity could not be read"
                    continue
                }
                restoredFilesByFingerprint[fingerprint] = restoredState
                restoredFingerprintByIdentity[file.cursor.fileIdentity] =
                    fingerprint
            } else if let path = file.path,
                      isSafeRelativePath(path) {
                files[path] = restoredState
                legacyPaths.insert(path)
            } else {
                restoreWarning = "Saved local activity could not be read"
                continue
            }
            if let projection = file.projection {
                projections[projection.taskID] = projection
            }
            for projection in file.ancestorProjections ?? [] {
                projections[projection.taskID] = projection
            }
        }
        changedPaths = legacyPaths
        pendingFactWrites.removeAll()
    }

    private func bindRestoredStateIfNeeded(to path: String) {
        guard files[path] == nil else { return }
        let currentFingerprint = stateFileName(for: path)
        let fingerprint: String
        if restoredFilesByFingerprint[currentFingerprint] != nil {
            fingerprint = currentFingerprint
        } else if let identity = fileIdentity(fileURL(path)),
                  let identityFingerprint =
                      restoredFingerprintByIdentity[identity] {
            fingerprint = identityFingerprint
        } else {
            return
        }
        guard let restored = restoredFilesByFingerprint.removeValue(
            forKey: fingerprint
        ) else {
            return
        }
        restoredFingerprintByIdentity[restored.cursor.fileIdentity] = nil
        files[path] = restored
    }

    private func fileIdentity(_ file: URL) -> RolloutFileIdentity? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: file.path
            ),
            let systemNumber = (
                attributes[.systemNumber] as? NSNumber
            )?.uint64Value,
            let fileNumber = (
                attributes[.systemFileNumber] as? NSNumber
            )?.uint64Value
        else {
            return nil
        }
        return RolloutFileIdentity(
            systemNumber: systemNumber,
            fileNumber: fileNumber
        )
    }

    private var stateURL: URL? {
        guard let stateDirectory, let partitionID else { return nil }
        return stateDirectory.appendingPathComponent(
            partitionID,
            isDirectory: true
        )
    }

    private func fileKey(_ file: URL) -> String? {
        let rootPath = rootDirectory.path + "/"
        let path = file.resolvingSymlinksInPath().path
        guard path.hasPrefix(rootPath) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }

    private func fileURL(_ path: String) -> URL {
        rootDirectory.appendingPathComponent(path)
    }

    private func stateFileName(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func metadataURL(
        forFingerprint fingerprint: String,
        in directory: URL
    ) -> URL {
        directory.appendingPathComponent(fingerprint + ".json")
    }

    private func factsURL(
        forFingerprint fingerprint: String,
        in directory: URL
    ) -> URL {
        directory.appendingPathComponent(
            fingerprint + ".facts.jsonl"
        )
    }

    private func scheduleFactWrite(
        path: String,
        facts: [LocalActivityFact],
        rewritesFile: Bool
    ) {
        guard rewritesFile || !facts.isEmpty else { return }
        if rewritesFile {
            pendingFactWrites[path] = FactWrite(
                rewritesFile: true,
                facts: facts
            )
        } else if var pending = pendingFactWrites[path] {
            pending.facts.append(contentsOf: facts)
            pendingFactWrites[path] = pending
        } else {
            pendingFactWrites[path] = FactWrite(
                rewritesFile: false,
                facts: facts
            )
        }
    }

    private func persistFacts(_ write: FactWrite, to file: URL) throws {
        if write.rewritesFile {
            let temporary = file.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            do {
                try writeFacts(write.facts, to: temporary, appending: false)
                if FileManager.default.fileExists(atPath: file.path) {
                    _ = try FileManager.default.replaceItemAt(
                        file,
                        withItemAt: temporary
                    )
                } else {
                    try FileManager.default.moveItem(
                        at: temporary,
                        to: file
                    )
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            return
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(
                atPath: file.path,
                contents: nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try writeFacts(write.facts, to: file, appending: true)
    }

    private func writeFacts(
        _ facts: [LocalActivityFact],
        to file: URL,
        appending: Bool
    ) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        if appending {
            try handle.seekToEnd()
        }
        let encoder = JSONEncoder()
        var buffer = Data()
        buffer.reserveCapacity(262_144)
        for fact in facts {
            var data = try encoder.encode(fact)
            data.append(0x0A)
            if !buffer.isEmpty, buffer.count + data.count > 262_144 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            if data.count > 262_144 {
                try handle.write(contentsOf: data)
            } else {
                buffer.append(data)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
    }

    private func restoreFacts(
        from file: URL,
        state: inout FileState,
        interval: DateInterval,
        maximumLines: Int,
        maximumBytes: UInt64
    ) -> FactLoadOutcome {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: file.path
        ),
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
        let handle = try? FileHandle(forReadingFrom: file) else {
            return .invalid
        }
        defer { try? handle.close() }
        if state.factRestoreFileSize != fileSize
            || state.factRestoreOffset > fileSize {
            state.facts.removeAll(keepingCapacity: false)
            state.eventIDs.removeAll(keepingCapacity: false)
            state.restoredFactIdentities.removeAll(keepingCapacity: false)
            state.factRestoreOffset = 0
            state.factRestoreFileSize = fileSize
        }
        let decoder = JSONDecoder()
        var isValid = true
        guard let result = try? BoundedJSONLReader.read(
            handle: handle,
            from: state.factRestoreOffset,
            maximumLines: maximumLines,
            maximumBytes: maximumBytes,
            maximumRecordBytes: Self.maximumMetadataBytes,
            discardsPartialRecordAtByteLimit: false,
            onLine: { line, _ in
                guard isValid else { return false }
                guard let fact = try? decoder.decode(
                    LocalActivityFact.self,
                    from: line
                ) else {
                    isValid = false
                    return false
                }
                guard factPassesHistoryCutoff(fact) else {
                    return true
                }
                let isActive = isFactActive(fact, in: interval)
                if let eventID = fact.eventID {
                    guard isActive else {
                        return true
                    }
                    state.eventIDs.insert(eventID)
                    let identity = FactIdentity(
                        eventID: eventID,
                        key: fact.key.rawValue
                    )
                    guard state.restoredFactIdentities.insert(
                        identity
                    ).inserted else {
                        return true
                    }
                }
                if isActive {
                    appendRestoredFact(fact, to: &state.facts)
                }
                return true
            }
        ),
        isValid,
        result.oversizedRecordCount == 0 else {
            return .invalid
        }
        state.factRestoreOffset = result.resumeByteOffset
        if result.completeByteOffset == fileSize {
            state.factRestoreOffset = 0
            state.factRestoreFileSize = nil
            state.restoredFactIdentities.removeAll(keepingCapacity: false)
            return .ready(
                linesRead: result.processedLineCount,
                bytesRead: result.bytesRead
            )
        }
        guard result.stoppedEarly else { return .invalid }
        return .partial(
            linesRead: result.processedLineCount,
            bytesRead: result.bytesRead
        )
    }

    private func appendRestoredFact(
        _ fact: LocalActivityFact,
        to facts: inout [LocalActivityFact]
    ) {
        guard fact.key == .context,
              case let .tokens(usage) = fact.value,
              let eventID = fact.eventID,
              let lastIndex = facts.indices.last,
              facts[lastIndex].key == .token,
              facts[lastIndex].eventID == eventID,
              facts[lastIndex].eventTimestamp == fact.eventTimestamp,
              facts[lastIndex].source == fact.source,
              facts[lastIndex].context == fact.context else {
            facts.append(fact)
            return
        }
        facts[lastIndex].contextUsage = usage
    }

    private func loadFactsIfNeeded(
        for path: String,
        interval: DateInterval,
        maximumLines: Int,
        maximumBytes: UInt64
    ) -> FactLoadOutcome {
        guard var state = files[path],
              !state.factsLoaded,
              let directory = stateURL else {
            return .ready(linesRead: 0, bytesRead: 0)
        }
        let outcome = restoreFacts(
            from: factsURL(
                forFingerprint: state.storageFingerprint
                    ?? stateFileName(for: path),
                in: directory
            ),
            state: &state,
            interval: interval,
            maximumLines: maximumLines,
            maximumBytes: maximumBytes
        )
        guard case .invalid = outcome else {
            if case .ready = outcome {
                if let pending = pendingFactWrites[path],
                   !pending.rewritesFile {
                    for fact in pending.facts {
                        if let eventID = fact.eventID {
                            guard state.eventIDs.insert(eventID).inserted
                            else { continue }
                        }
                        if factPassesHistoryCutoff(fact),
                           isFactActive(fact, in: interval) {
                            state.facts.append(fact)
                        }
                    }
                }
                state.factsLoaded = true
            }
            files[path] = state
            return outcome
        }
        files[path] = nil
        return .invalid
    }

    private func recordsAfterHistoryCutoff(
        _ records: [RolloutRecord]
    ) -> [RolloutRecord] {
        guard let historyCutoff else { return records }
        return records.filter { record in
            if record.type == "session_meta" {
                return true
            }
            guard let timestamp = record.timestamp,
                  let date = parseTimestamp(timestamp) else {
                return false
            }
            return date >= historyCutoff
        }
    }

    private func factsAfterHistoryCutoff(
        _ facts: [LocalActivityFact]
    ) -> [LocalActivityFact] {
        facts.filter(factPassesHistoryCutoff)
    }

    private func factPassesHistoryCutoff(
        _ fact: LocalActivityFact
    ) -> Bool {
        guard let historyCutoff else { return true }
        guard let timestamp = fact.eventTimestamp,
              let date = parseTimestamp(timestamp) else {
            return fact.eventID == nil
        }
        return date >= historyCutoff
    }

    private func isFactActive(
        _ fact: LocalActivityFact,
        in interval: DateInterval
    ) -> Bool {
        switch fact.key {
        case .task, .parent, .root, .agent:
            return true
        default:
            break
        }
        if case let .duration(duration) = fact.value {
            return duration.completedAt > interval.start
        }
        if case let .turnTiming(timing) = fact.value {
            if let completedAt = timing.completedAt {
                return completedAt > interval.start
            }
            return timing.startedAt.map { $0 >= interval.start } ?? false
        }
        guard let timestamp = fact.eventTimestamp,
              let date = parseTimestamp(timestamp) else {
            return fact.eventID == nil
        }
        return date >= interval.start
    }

    private func factsForActiveInterval(
        _ facts: [LocalActivityFact],
        interval: DateInterval
    ) -> [LocalActivityFact] {
        facts.filter { isFactActive($0, in: interval) }
    }

    private func tokenActivityBounds(
        _ facts: [LocalActivityFact]
    ) -> DateInterval? {
        var start: Date?
        var end: Date?
        for fact in facts {
            guard fact.key == .token,
                  let timestamp = fact.eventTimestamp,
                  let date = parseTimestamp(timestamp) else {
                continue
            }
            start = start.map { min($0, date) } ?? date
            end = end.map { max($0, date) } ?? date
        }
        guard let start, let end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func restoreDeletionMarker(
        for stateDirectory: URL
    ) -> DeletionMarkerRestore {
        guard let file = deletionMarkerURL(for: stateDirectory),
              FileManager.default.fileExists(atPath: file.path) else {
            return .missing
        }
        guard let data = readMetadata(at: file),
              let marker = try? JSONDecoder().decode(
                  DeletionMarker.self,
                  from: data
              ),
              marker.version == 1 else {
            return .invalid
        }
        return .valid(marker)
    }

    private static func restoreLegacyHistoryCutoff(
        from stateDirectory: URL
    ) -> Date? {
        let file = stateDirectory.appendingPathComponent(
            "deletion-cutoff.json"
        )
        guard let data = readMetadata(at: file) else { return nil }
        return try? JSONDecoder().decode(Date.self, from: data)
    }

    private static func readMetadata(at file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumMetadataBytes {
            let remaining = maximumMetadataBytes + 1 - data.count
            let chunk: Data
            do {
                guard let value = try handle.read(
                    upToCount: min(65_536, remaining)
                ) else {
                    return data
                }
                chunk = value
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        return nil
    }

    private static func deletionMarkerURL(
        for stateDirectory: URL
    ) -> URL? {
        let name = stateDirectory.lastPathComponent
        guard !name.isEmpty else { return nil }
        return stateDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(name)-deletion.json"
        )
    }

    private func deletionMarkerURL(for stateDirectory: URL) -> URL? {
        Self.deletionMarkerURL(for: stateDirectory)
    }

    private func persistDeletionMarker(
        cutoff: Date,
        cleanupPending: Bool,
        for stateDirectory: URL
    ) throws {
        guard let file = deletionMarkerURL(for: stateDirectory) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let marker = DeletionMarker(
            version: 1,
            cutoff: cutoff,
            cleanupPending: cleanupPending
        )
        try JSONEncoder().encode(marker).write(to: file, options: .atomic)
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/")
            && !path.split(separator: "/").contains("..")
    }
}
