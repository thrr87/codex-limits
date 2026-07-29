import CryptoKit
import Foundation

struct LocalActivityCollection: Equatable, Sendable {
    let facts: [LocalActivityFact]
    let projections: [ThreadProjection]
    let observation: LocalActivityObservation
    let bytesRead: UInt64

    static func unavailable(
        _ reason: String,
        facts: [LocalActivityFact] = [],
        projections: [ThreadProjection] = []
    ) -> LocalActivityCollection {
        LocalActivityCollection(
            facts: facts,
            projections: projections,
            observation: .unavailable(reason),
            bytesRead: 0
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
                bytesRead: bytesRead
            )
        case .unavailable:
            return self
        }
    }
}

actor LocalActivityCollector {
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
    private var stateGeneration: UInt64 = 0
    private var historyCutoff: Date?
    private var historyDeletionPending = false
    private var deletionMarkerInvalid = false
    private var restoreWarning: String?

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
        stateGeneration &+= 1
        persist()
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
        restore()
    }

    func refresh(
        interval: DateInterval,
        observedAt: Date = Date()
    ) async -> LocalActivityCollection {
        let refreshGeneration = stateGeneration
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
                facts: files.values.flatMap(\.facts)
            )
        }

        let projectionsBeforeRefresh = projections
        let listSucceeded = await refreshProjectionList(
            generation: refreshGeneration
        )
        guard refreshGeneration == stateGeneration else {
            return .unavailable("Account changed during local activity read")
        }
        let calendarFiles = rolloutFiles(in: interval)
        let currentProjections = activeProjections(in: interval)
        let projectedFiles = Set(
            currentProjections.compactMap(validProjectionFile)
        )
        let trackedFiles = Set(files.compactMap { path, state in
            stateHasActivity(state, in: interval) ? fileURL(path) : nil
        })
        let candidatePaths = Set(
            calendarFiles
            .union(projectedFiles)
            .union(trackedFiles)
            .compactMap(fileKey)
        )
        var bytesRead: UInt64 = 0
        var gapReason = restoreWarning ?? (listSucceeded == false
            ? "Local task discovery is incomplete"
            : currentProjections.contains {
            validProjectionFile($0) == nil
        } ? "Local rollout path is unavailable" : nil)

        for path in candidatePaths.sorted() {
            bindRestoredStateIfNeeded(to: path)
            let file = fileURL(path)
            loadFactsIfNeeded(for: path)
            guard FileManager.default.fileExists(atPath: file.path) else {
                gapReason = gapReason ?? "Local task records are missing"
                continue
            }
            do {
                let previous = files[path]
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
                    observedAt: observedAt
                )
                bytesRead += batch.bytesRead
                if batch.malformedRecordCount > 0 {
                    gapReason = gapReason
                        ?? "Some local diagnostic records could not be read"
                }
                if batch.requiresRebuild, previous != nil {
                    gapReason = gapReason
                        ?? "Local task record continuity changed"
                }
                if batch.records.isEmpty,
                   !batch.requiresRebuild,
                   previous != nil,
                   !requiresContextRebuild {
                    if batch.malformedRecordCount > 0 {
                        files[path]?.hasMalformedRecords = true
                    }
                    if previous?.cursor != batch.cursor {
                        files[path]?.cursor = batch.cursor
                        changedPaths.insert(path)
                    } else if batch.malformedRecordCount > 0 {
                        changedPaths.insert(path)
                    }
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
                let combinedFacts = rewritesFacts
                    ? newFacts
                    : (previous?.facts ?? []) + newFacts
                let activityBounds = tokenActivityBounds(combinedFacts)
                let discontinuityAt = batch.requiresRebuild
                    && previous != nil
                    && !requiresContextRebuild
                    ? observedAt
                    : previous?.discontinuityAt
                files[path] = FileState(
                    cursor: batch.cursor,
                    normalization: normalized.state,
                    facts: combinedFacts,
                    eventIDs: Set(combinedFacts.compactMap(\.eventID)),
                    activityStart: activityBounds?.start,
                    activityEnd: activityBounds?.end,
                    discontinuityAt: discontinuityAt,
                    hasMalformedRecords: batch.requiresRebuild
                        ? batch.malformedRecordCount > 0
                        : previous?.hasMalformedRecords == true
                            || batch.malformedRecordCount > 0,
                    storageFingerprint: previous?.storageFingerprint,
                    factsLoaded: true,
                    requiresContextRebuild: false
                )
                changedPaths.insert(path)
                scheduleFactWrite(
                    path: path,
                    facts: newFacts,
                    rewritesFile: rewritesFacts
                )
            } catch {
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
            gapReason = gapReason ?? "Local task record continuity changed"
        }
        let activeTaskIDs = taskIDs(in: activeStates)
        let projectionChainsBefore = projectionChainIdentities(
            for: activeTaskIDs,
            using: projectionsBeforeRefresh
        )
        if await completeProjections(
            for: activeTaskIDs,
            listSucceeded: listSucceeded,
            generation: refreshGeneration
        ) == false {
            gapReason = gapReason ?? "Local task metadata is incomplete"
        }
        if projectionChainsBefore != projectionChainIdentities(
            for: activeTaskIDs
        ) {
            markFilesChanged(for: activeTaskIDs)
        }
        guard refreshGeneration == stateGeneration else {
            return .unavailable("Account changed during local activity read")
        }
        if activeStates.contains(where: { state in
            state.facts.contains { $0.key == .token }
                && !state.facts.contains {
                    $0.key == .task && $0.availability == .available
                }
        }) {
            gapReason = gapReason ?? "Local task identity is missing"
        }
        let versions = Set(
            activeStates
                .map(\.normalization.sourceVersion)
                .filter { $0 != "unknown" }
        )
        let hasTokenFacts = activeStates.contains {
            $0.facts.contains { $0.key == .token }
        }
        if hasTokenFacts {
            let installedVersion = await installedCLIVersion?()
            guard refreshGeneration == stateGeneration else {
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
        if !persist() {
            gapReason = gapReason ?? "Local activity could not be saved"
        }
        return LocalActivityCollection(
            facts: activeStates.flatMap(\.facts),
            projections: activeProjections,
            observation: gapReason.map {
                .gap(
                    sourceVersion: version,
                    observedAt: observedAt,
                    reason: $0
                )
            } ?? .continuous(
                sourceVersion: version,
                observedAt: observedAt
            ),
            bytesRead: bytesRead
        )
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
        stateGeneration &+= 1
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
        stateGeneration &+= 1
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
        if let stateDirectory {
            if FileManager.default.fileExists(atPath: stateDirectory.path) {
                try FileManager.default.removeItem(at: stateDirectory)
            }
            if let markerURL = deletionMarkerURL(for: stateDirectory),
               FileManager.default.fileExists(atPath: markerURL.path) {
                try FileManager.default.removeItem(at: markerURL)
            }
        }
        stateGeneration &+= 1
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
        historyCutoff = nil
        historyDeletionPending = false
        deletionMarkerInvalid = false
    }

    private func rolloutFiles(in interval: DateInterval) -> Set<URL> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var date = calendar.startOfDay(for: interval.start)
        let end = calendar.startOfDay(for: interval.end)
        var result = Set<URL>()

        for _ in 0 ..< 14 where date <= end {
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

    private func taskIDs(in states: [FileState]) -> Set<String> {
        Set(states.compactMap(taskID(in:)))
    }

    private func refreshProjectionList(generation: UInt64) async -> Bool? {
        guard let projectionSource else { return nil }
        let hadStarted = hasStartedProjectionList
        do {
            let newestPage = try await projectionSource.list(
                cursor: nil,
                limit: 100
            )
            guard generation == stateGeneration else { return nil }
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
                guard generation == stateGeneration else { return nil }
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
        generation: UInt64
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
            let mustRead = projections[taskID] == nil
                || (taskIDs.contains(taskID) && listSucceeded != true)
            if mustRead {
                guard reads < 20 else {
                    failed = true
                    break
                }
                reads += 1
                do {
                    if let projection = try await projectionSource.read(
                        threadID: taskID
                    ) {
                        guard generation == stateGeneration else {
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
        state.facts.compactMap { fact in
            guard fact.key == .task,
                  fact.availability == .available,
                  case let .identifier(taskID) = fact.value else {
                return nil
            }
            return taskID
        }.last
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
        LocalEventTimestampParser().date(from: value)
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
                        version: 6,
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
            guard let data = try? Data(contentsOf: entry),
                  let file = try? JSONDecoder().decode(
                      PersistedFile.self,
                      from: data
                  ),
                  [4, 5, 6].contains(file.version) else {
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
                requiresContextRebuild: file.version == 4
            )
            if file.version == 6 {
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
        let data = try write.facts.reduce(into: Data()) { result, fact in
            result.append(try JSONEncoder().encode(fact))
            result.append(0x0A)
        }
        if write.rewritesFile {
            try data.write(to: file, options: .atomic)
            return
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data().write(to: file, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func restoreFacts(from file: URL) -> [LocalActivityFact]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        var facts: [LocalActivityFact] = []
        var seenFacts = Set<String>()
        for line in data.split(separator: 0x0A) {
            guard let fact = try? decoder.decode(
                LocalActivityFact.self,
                from: Data(line)
            ) else {
                return nil
            }
            if let eventID = fact.eventID {
                let identity = "\(eventID)|\(fact.key.rawValue)"
                guard seenFacts.insert(identity).inserted else { continue }
            }
            facts.append(fact)
        }
        return facts
    }

    private func loadFactsIfNeeded(for path: String) {
        guard var state = files[path],
              !state.factsLoaded,
              let directory = stateURL else {
            return
        }
        guard let restoredFacts = restoreFacts(
            from: factsURL(
                forFingerprint: state.storageFingerprint
                    ?? stateFileName(for: path),
                in: directory
            )
        ) else {
            files[path] = nil
            return
        }
        let facts = factsAfterHistoryCutoff(restoredFacts)
        state.facts = facts
        state.eventIDs = Set(facts.compactMap(\.eventID))
        let activityBounds = tokenActivityBounds(facts)
        state.activityStart = activityBounds?.start
        state.activityEnd = activityBounds?.end
        state.factsLoaded = true
        files[path] = state
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
        guard let historyCutoff else { return facts }
        return facts.filter { fact in
            guard let timestamp = fact.eventTimestamp,
                  let date = parseTimestamp(timestamp) else {
                return fact.eventID == nil
            }
            return date >= historyCutoff
        }
    }

    private func tokenActivityBounds(
        _ facts: [LocalActivityFact]
    ) -> DateInterval? {
        let dates = facts.compactMap { fact -> Date? in
            guard fact.key == .token,
                  let timestamp = fact.eventTimestamp else {
                return nil
            }
            return parseTimestamp(timestamp)
        }
        guard let start = dates.min(), let end = dates.max() else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func restoreDeletionMarker(
        for stateDirectory: URL
    ) -> DeletionMarkerRestore {
        guard let file = deletionMarkerURL(for: stateDirectory),
              FileManager.default.fileExists(atPath: file.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: file),
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
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Date.self, from: data)
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
