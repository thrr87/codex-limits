import CryptoKit
import Foundation

struct AccountHistoryPartition: Codable, Equatable, Hashable, Sendable {
    let id: String

    private enum CodingKeys: String, CodingKey {
        case id
    }

    private init(id: String) {
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard Self.isValid(id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Invalid account history partition."
            )
        }
        self.id = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
    }

    static let legacy = Self(id: "legacy")

    static func stable(identity: String, key: Data) -> Self {
        let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        precondition(!normalized.isEmpty && !key.isEmpty)
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(normalized.utf8),
            using: SymmetricKey(data: key)
        )
        return Self(id: "account-" + digest.map { String(format: "%02x", $0) }.joined())
    }

    static func unknown(transitionID: UUID) -> Self {
        Self(id: "unknown-" + transitionID.uuidString.lowercased())
    }

    private static func isValid(_ id: String) -> Bool {
        if id == legacy.id { return true }
        if id.hasPrefix("account-") {
            let digest = id.dropFirst("account-".count)
            return digest.count == 64 && digest.allSatisfy {
                $0.isNumber || ("a" ... "f").contains($0)
            }
        }
        if id.hasPrefix("unknown-") {
            let value = String(id.dropFirst("unknown-".count))
            return UUID(uuidString: value)?.uuidString.lowercased() == value
        }
        return false
    }
}

actor UsageHistory {
    enum DeletionStatus: Equatable, Sendable {
        case none
        case complete
        case pendingSync
        case pendingLocal
    }

    enum Issue: Equatable, Sendable {
        case wrongAccount
    }

    struct State: Equatable, Sendable {
        let samples: [UsageSample]
        let folderName: String?
        let errorMessage: String?
        let deletionStatus: DeletionStatus
        let issue: Issue?
    }

    enum RangeResolution: Equatable, Sendable {
        case exact
        case downsampled
    }

    struct RangeView: Equatable, Sendable {
        let retainedBounds: DateInterval?
        let coveredInterval: DateInterval?
        let samples: [UsageSample]
        let resolution: RangeResolution
        let hadReadError: Bool
    }

    private struct Marker: Codable {
        let version: Int
        let generation: Int?
        let pendingDeletion: Bool?
        let localDeletionComplete: Bool?
        let pendingDeletionTarget: PendingDeletionTarget?
        let pendingSyncTarget: String?
        let syncTarget: String?
        let lineageID: String?
        let migrationWarning: Bool?
    }

    private enum PendingDeletionTarget: String, Codable {
        case localOnly = "local-only"
        case unresolvedSync = "unresolved-sync"
        case boundSync = "bound-sync"
    }

    private struct DailyFile: Codable {
        let version: Int
        let generation: Int?
        let samples: [UsageSample]
    }

    private struct LineageRecord: Codable {
        let version: Int
        let id: String
    }

    private struct DeletionRecord: Codable {
        let version: Int
        let generation: Int
        let lineageID: String
    }

    private struct AccountBinding: Codable {
        let version: Int
        let salt: Data
        let digest: String
    }

    private struct WriterManifest: Codable {
        let version: Int
        let generation: Int
        let oldestDay: String
        let newestDay: String
        let latestChangedDay: String
        let revision: UInt64
    }

    private struct WriterCursor: Codable {
        var nextDay: String?
        var observedRevision: UInt64?
    }

    private struct SyncProgress: Codable {
        let version: Int
        let lineageID: String
        let generation: Int
        var publication: WriterCursor
        var imports: [String: WriterCursor]
        var nextImportWriter: String?
    }

    private enum HistoryError: Error {
        case invalidFolder
        case invalidFile
        case unsupportedFileVersion
        case unsupportedFolderVersion
        case unavailableFolder
        case wrongDeletionFolder
        case wrongAccount
    }

    private static let folderFormatVersion = 2
    private static let dailyFileVersion = 1
    private static let markerName = ".codex-limits-history.json"
    private static let installationsName = "installations"
    private static let lineagesName = "lineages"
    private static let deletionsName = "deletions"
    private static let accountBindingName = ".codex-limits-account.json"
    private static let writerManifestName = ".codex-limits-writer"
    private static let syncProgressName = ".codex-limits-sync-progress"
    private static let maximumFileSize = 1_000_000
    private static let maximumGeneration = 1_000_000_000
    private static let maximumAutomaticSyncCandidates = 32
    private static let automaticSyncInterval: TimeInterval = 30 * 60
    private static let localMarkerUpdateLock = NSLock()
    private static let workingSetFileDays = 90
    private static let workingSetDuration: TimeInterval = 84 * 86_400
    private static let fullResolutionDuration: TimeInterval = 8 * 86_400
    private static let historicalBucketDuration: TimeInterval = 60 * 60
    private static let maximumWorkingSetSamples = 6_000
    private static let maximumWorkingSetWriters = 32
    private static let maximumWorkingSetFileReads = 256
    private static let maximumWorkingSetReadBytes = 8 * 1_024 * 1_024

    private struct WorkingSetReadBudget {
        var files = 0
        var bytes = 0
        var didReachLimit = false

        mutating func admit(_ url: URL) throws -> Bool {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return false
            }
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size >= 0,
                  size <= UsageHistory.maximumFileSize else {
                throw HistoryError.invalidFile
            }
            guard files < UsageHistory.maximumWorkingSetFileReads,
                  size <= UsageHistory.maximumWorkingSetReadBytes - bytes else {
                didReachLimit = true
                return false
            }
            files += 1
            bytes += size
            return true
        }
    }

    private let localDirectory: URL
    private let installationID: String
    private var partition: AccountHistoryPartition
    private var syncDirectory: URL?
    private var errorMessage: String?
    private var knownSamples: [UsageSample] = []
    private var deletionStatus: DeletionStatus = .none
    private var migrationWarning = false
    private var syncAccountBindingToken: String?
    private var lastSynchronizationAttemptAt: Date?
    private let beforeCoordinatedMarkerRead: ((URL) throws -> Void)?

    init(
        localDirectory: URL,
        installationID: String,
        partition: AccountHistoryPartition = .legacy,
        beforeCoordinatedMarkerRead: ((URL) throws -> Void)? = nil
    ) {
        self.localDirectory = localDirectory
        self.installationID = installationID
        self.partition = partition
        self.beforeCoordinatedMarkerRead = beforeCoordinatedMarkerRead
    }

    func load(legacySamples: [UsageSample] = []) -> State {
        do {
            try prepareLocalStore()
            try prepareRoot(activeLocalDirectory, createIfMissing: true, coordinated: false)
            try add(
                legacySamples,
                to: activeLocalDirectory,
                installationID: installationID,
                coordinated: false
            )
            errorMessage = migrationWarning
                ? "Some usage history couldn’t be migrated."
                : nil
        } catch {
            errorMessage = "Usage history couldn’t be saved."
        }
        return state(
            fallback: legacySamples,
            refreshSamples: true
        )
    }

    func restoreExistingState() -> State? {
        let markerURL = localDirectory.appendingPathComponent(Self.markerName)
        guard FileManager.default.fileExists(atPath: markerURL.path),
              let marker = try? readMarker(at: markerURL, coordinated: false),
              marker.version == Self.folderFormatVersion else {
            return nil
        }
        migrationWarning = marker.migrationWarning == true
        if marker.pendingDeletion == true,
           marker.pendingDeletionTarget != .localOnly {
            deletionStatus = .pendingSync
        } else if marker.pendingDeletionTarget == .localOnly {
            deletionStatus = .complete
        }
        let local = readWorkingSet(from: activeLocalDirectory)
        knownSamples = local.samples
        errorMessage = if migrationWarning {
            "Some usage history couldn’t be migrated."
        } else if local.hadError {
            "Some usage history couldn’t be read."
        } else {
            nil
        }
        return State(
            samples: local.samples,
            folderName: nil,
            errorMessage: errorMessage,
            deletionStatus: deletionStatus,
            issue: nil
        )
    }

    func record(_ sample: UsageSample) -> State {
        do {
            try prepareLocalStore()
            let marker = try readMarker(
                at: localDirectory.appendingPathComponent(Self.markerName),
                coordinated: false
            )
            guard marker.pendingDeletion != true else {
                errorMessage = "Deletion pending — retry before recording new history."
                deletionStatus = .pendingSync
                return state()
            }
            try prepareRoot(activeLocalDirectory, createIfMissing: true, coordinated: false)
            try add(
                [sample],
                to: activeLocalDirectory,
                installationID: installationID,
                coordinated: false
            )
            knownSamples = boundedWorkingSet(knownSamples + [sample])
            if let syncDirectory {
                try prepareRoot(
                    syncDirectory,
                    createIfMissing: false,
                    coordinated: true,
                    requiresLineage: true
                )
                let generation = try effectiveGeneration(in: syncDirectory)
                try add(
                    [sample],
                    to: syncDirectory,
                    installationID: installationID,
                    generation: generation,
                    coordinated: true
                )
            }
            errorMessage = nil
            deletionStatus = .none
        } catch {
            errorMessage = syncDirectory == nil
                ? "Usage history couldn’t be saved."
                : message(for: error)
        }
        return state()
    }

    func connect(
        to directory: URL,
        accountIdentity: String? = nil,
        accountBindingToken: String? = nil,
        bindsUnresolvedDeletionTarget: Bool = false,
        performFullReconciliation: Bool = true
    ) -> State {
        do {
            try prepareLocalStore()
            try prepareRoot(
                directory,
                createIfMissing: false,
                coordinated: true,
                requiresLineage: true
            )
            let localMarker = try readMarker(
                at: localDirectory.appendingPathComponent(Self.markerName),
                coordinated: false
            )
            if localMarker.pendingDeletion == true {
                try completePendingDeletion(
                    in: directory,
                    generation: localMarker.generation ?? 1,
                    bindsUnresolvedTarget: bindsUnresolvedDeletionTarget
                )
                syncDirectory = nil
                syncAccountBindingToken = nil
                if let accountIdentity {
                    syncAccountBindingToken = try ensureAccountBinding(
                        identity: accountIdentity,
                        in: directory
                    )
                } else if let accountBindingToken {
                    try validateAccountBinding(
                            token: accountBindingToken,
                            in: directory
                    )
                    syncAccountBindingToken = accountBindingToken
                } else if partition != .legacy {
                    throw HistoryError.wrongAccount
                }
                syncDirectory = directory
                errorMessage = nil
                return state(refreshSamples: true)
            }
            if let accountIdentity {
                syncAccountBindingToken = try ensureAccountBinding(
                    identity: accountIdentity,
                    in: directory
                )
            } else if let accountBindingToken {
                try validateAccountBinding(
                    token: accountBindingToken,
                    in: directory
                )
                syncAccountBindingToken = accountBindingToken
            } else if partition != .legacy {
                throw HistoryError.wrongAccount
            }
            try reconcileGeneration(with: directory)
            syncDirectory = directory
            errorMessage = nil
            return synchronize(
                at: Date(),
                refreshLocalWhenDisconnected: false,
                boundedReconciliation: !performFullReconciliation
            )
        } catch {
            if case HistoryError.wrongDeletionFolder = error {
                syncDirectory = nil
                syncAccountBindingToken = nil
            } else if case HistoryError.wrongAccount = error,
                      syncDirectory?.standardizedFileURL
                        == directory.standardizedFileURL {
                syncDirectory = nil
                syncAccountBindingToken = nil
            }
            errorMessage = message(for: error)
            let issue: Issue? = if case HistoryError.wrongAccount = error {
                .wrongAccount
            } else {
                nil
            }
            return state(issue: issue)
        }
    }

    func disconnect() -> State {
        syncDirectory = nil
        syncAccountBindingToken = nil
        errorMessage = nil
        lastSynchronizationAttemptAt = nil
        return state()
    }

    func isConnected(to directory: URL) -> Bool {
        syncDirectory?.standardizedFileURL == directory.standardizedFileURL
    }

    func accountBindingToken() -> String? {
        syncAccountBindingToken
    }

    func selectPartition(_ partition: AccountHistoryPartition) -> State {
        guard partition != self.partition else { return state() }
        self.partition = partition
        syncDirectory = nil
        syncAccountBindingToken = nil
        lastSynchronizationAttemptAt = nil
        errorMessage = nil
        knownSamples = []
        return load()
    }

    func synchronize() -> State {
        synchronize(
            at: Date(),
            refreshLocalWhenDisconnected: true,
            boundedReconciliation: true
        )
    }

    func synchronizeIfDue(at now: Date = Date()) -> State {
        if let lastSynchronizationAttemptAt {
            let elapsed = now.timeIntervalSince(lastSynchronizationAttemptAt)
            if elapsed >= 0, elapsed < Self.automaticSyncInterval {
                return state()
            }
        }
        return synchronize(
            at: now,
            refreshLocalWhenDisconnected: false,
            boundedReconciliation: true
        )
    }

    func rangeView(for requestedInterval: DateInterval) -> RangeView? {
        guard requestedInterval.duration > 0,
              requestedInterval.duration <= Self.workingSetDuration,
              requestedInterval.start.timeIntervalSinceReferenceDate.isFinite,
              requestedInterval.end.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }
        do {
            try prepareLocalStore()
            try prepareRoot(
                activeLocalDirectory,
                createIfMissing: true,
                coordinated: false
            )
        } catch {
            return RangeView(
                retainedBounds: nil,
                coveredInterval: nil,
                samples: [],
                resolution: .exact,
                hadReadError: true
            )
        }

        let directory = installationsDirectory(in: activeLocalDirectory)
        var retainedStart: Date?
        var retainedEnd: Date?
        var samples: [UsageSample] = []
        var wasDownsampled = false
        var hadReadError = false
        var budget = WorkingSetReadBudget()
        do {
            let writers = try boundedWorkingSetWriters(in: directory)
            hadReadError = writers.didReachLimit
            writerLoop: for writer in writers.values {
                guard !Task.isCancelled else { return nil }
                do {
                    if let manifest = try ensureWriterManifest(
                        in: writer,
                        generation: 1,
                        coordinated: false
                    ), let oldest = date(forDayName: manifest.oldestDay),
                       let newest = nextDay(after: manifest.newestDay)
                            .flatMap(date(forDayName:)) {
                        retainedStart = min(retainedStart ?? oldest, oldest)
                        retainedEnd = max(retainedEnd ?? newest, newest)
                    }
                } catch {
                    hadReadError = true
                }

                for day in dayNames(in: requestedInterval) {
                    guard !Task.isCancelled else { return nil }
                    let file = writer.appendingPathComponent("\(day).json")
                    do {
                        guard try budget.admit(file) else {
                            if budget.didReachLimit {
                                hadReadError = true
                                break writerLoop
                            }
                            continue
                        }
                        let next = try readDailyFileIfPresent(
                            at: file,
                            coordinated: false
                        ).filter { requestedInterval.contains($0.observedAt) }
                        let bounded = boundedRangeSamples(samples + next)
                        samples = bounded.samples
                        wasDownsampled = wasDownsampled || bounded.didDownsample
                    } catch {
                        hadReadError = true
                    }
                }
            }
        } catch {
            hadReadError = true
        }

        let retainedBounds = retainedStart.flatMap { start in
            retainedEnd.flatMap { end in
                end > start ? DateInterval(start: start, end: end) : nil
            }
        }
        return RangeView(
            retainedBounds: retainedBounds,
            coveredInterval: retainedBounds?.intersection(with: requestedInterval),
            samples: samples,
            resolution: wasDownsampled ? .downsampled : .exact,
            hadReadError: hadReadError
        )
    }

    private func synchronize(
        at now: Date,
        refreshLocalWhenDisconnected: Bool,
        boundedReconciliation: Bool
    ) -> State {
        lastSynchronizationAttemptAt = now
        guard let syncDirectory else {
            return state(refreshSamples: refreshLocalWhenDisconnected)
        }
        do {
            try prepareLocalStore()
            try prepareRoot(
                syncDirectory,
                createIfMissing: false,
                coordinated: true,
                requiresLineage: true
            )
            let localMarker = try readMarker(
                at: localDirectory.appendingPathComponent(Self.markerName),
                coordinated: false
            )
            if localMarker.pendingDeletion == true {
                try completePendingDeletion(
                    in: syncDirectory,
                    generation: localMarker.generation ?? 1
                )
                errorMessage = nil
                return state(refreshSamples: true)
            }
            try reconcileGeneration(with: syncDirectory)
            let generation = try effectiveGeneration(in: syncDirectory)
            let hadImportErrors: Bool
            if boundedReconciliation {
                let marker = try readMarker(
                    at: localDirectory.appendingPathComponent(Self.markerName),
                    coordinated: false
                )
                guard let lineageID = marker.syncTarget else {
                    throw HistoryError.invalidFolder
                }
                hadImportErrors = try synchronizeBounded(
                    with: syncDirectory,
                    generation: generation,
                    lineageID: lineageID
                )
            } else {
                hadImportErrors = try importHistory(
                    from: syncDirectory,
                    generation: generation
                )
                try publishOwnHistory(
                    to: syncDirectory,
                    generation: generation
                )
            }
            errorMessage = hadImportErrors
                ? "Some synced history couldn’t be read."
                : nil
        } catch {
            errorMessage = message(for: error)
        }
        return state()
    }

    func deleteAnalyticsHistory(
        syncTarget: URL? = nil,
        expectsSyncTarget: Bool = false
    ) -> State {
        let deletionTarget = syncTarget ?? syncDirectory
        do {
            try prepareLocalStore()
            let localMarkerURL = localDirectory.appendingPathComponent(Self.markerName)
            let localMarker = try readMarker(at: localMarkerURL, coordinated: false)
            let localGeneration = localMarker.generation ?? 1

            if let target = deletionTarget {
                let nextGeneration: Int
                let syncLineage: String
                do {
                    try prepareRoot(
                        target,
                        createIfMissing: false,
                        coordinated: true,
                        requiresLineage: true
                    )
                    let lineages = try syncLineages(in: target)
                    if let expected = localMarker.syncTarget,
                       !lineages.contains(expected) {
                        throw HistoryError.wrongDeletionFolder
                    }
                    guard let lineage = localMarker.syncTarget ?? lineages.sorted().first else {
                        throw HistoryError.invalidFolder
                    }
                    let currentGeneration = max(
                        localGeneration,
                        try effectiveGeneration(in: target, lineages: lineages)
                    )
                    nextGeneration = try incrementedGeneration(after: currentGeneration)
                    syncLineage = lineage
                } catch {
                    try beginPendingDeletion(
                        generation: try incrementedGeneration(after: localGeneration),
                        target: localMarker.syncTarget == nil
                            ? .unresolvedSync
                            : .boundSync,
                        syncLineage: localMarker.syncTarget
                    )
                    errorMessage = "Deletion pending — sync folder unavailable."
                    deletionStatus = .pendingSync
                    return state()
                }
                try beginPendingDeletion(
                    generation: nextGeneration,
                    target: .boundSync,
                    syncLineage: syncLineage
                )
                try completePendingDeletion(
                    in: target,
                    generation: nextGeneration
                )
            } else if expectsSyncTarget {
                try beginPendingDeletion(
                    generation: try incrementedGeneration(after: localGeneration),
                    target: localMarker.syncTarget == nil
                        ? .unresolvedSync
                        : .boundSync,
                    syncLineage: localMarker.syncTarget
                )
                errorMessage = "Deletion pending — sync folder unavailable."
                deletionStatus = .pendingSync
                return state()
            } else {
                let nextGeneration = try incrementedGeneration(after: localGeneration)
                try beginPendingDeletion(
                    generation: nextGeneration,
                    target: .localOnly
                )
                try writeMarker(
                    to: localMarkerURL,
                    generation: nextGeneration,
                    pendingDeletion: false,
                    coordinated: false
                )
                deletionStatus = .complete
            }

            errorMessage = nil
        } catch {
            errorMessage = deletionTarget == nil
                ? "Analytics history couldn’t be deleted."
                : "Deletion pending — sync folder unavailable."
            deletionStatus = deletionTarget == nil ? .none : .pendingSync
        }
        return state(refreshSamples: true)
    }

    func retryPendingDeletion(
        syncTarget: URL? = nil,
        bindsUnresolvedDeletionTarget: Bool = false
    ) -> State {
        do {
            try prepareLocalStore()
            let marker = try readMarker(
                at: localDirectory.appendingPathComponent(Self.markerName),
                coordinated: false
            )
            guard marker.pendingDeletion == true else { return state() }
            if marker.pendingDeletionTarget == .localOnly {
                if marker.localDeletionComplete != true {
                    try removeAllLocalHistory()
                    knownSamples = []
                }
                try writeMarker(
                    to: localDirectory.appendingPathComponent(Self.markerName),
                    generation: marker.generation ?? 1,
                    pendingDeletion: false,
                    coordinated: false
                )
                deletionStatus = .complete
                errorMessage = nil
                return state()
            }
            guard let target = syncTarget ?? syncDirectory else {
                errorMessage = "Deletion pending — sync folder unavailable."
                deletionStatus = .pendingSync
                return state()
            }
            try completePendingDeletion(
                in: target,
                generation: marker.generation ?? 1,
                bindsUnresolvedTarget: bindsUnresolvedDeletionTarget
            )
            syncDirectory = nil
            syncAccountBindingToken = nil
            errorMessage = nil
        } catch {
            errorMessage = if case HistoryError.wrongDeletionFolder = error {
                "Reconnect the folder used for this deletion."
            } else {
                "Deletion pending — sync folder unavailable."
            }
            deletionStatus = .pendingSync
        }
        return state(refreshSamples: true)
    }

    func rebuildAvailableHistory(_ samples: [UsageSample]) -> State {
        do {
            try prepareLocalStore()
            try prepareRoot(activeLocalDirectory, createIfMissing: true, coordinated: false)
            try add(
                samples,
                to: activeLocalDirectory,
                installationID: installationID,
                coordinated: false
            )
            let marker = try readMarker(
                at: localDirectory.appendingPathComponent(Self.markerName),
                coordinated: false
            )
            if marker.pendingDeletion == true {
                errorMessage = "Deletion pending — sync folder unavailable."
                deletionStatus = .pendingSync
            } else {
                if let syncDirectory {
                    try prepareRoot(
                        syncDirectory,
                        createIfMissing: false,
                        coordinated: true,
                        requiresLineage: true
                    )
                    try reconcileGeneration(with: syncDirectory)
                    try add(
                        samples,
                        to: syncDirectory,
                        installationID: installationID,
                        generation: try effectiveGeneration(in: syncDirectory),
                        coordinated: true
                    )
                }
                errorMessage = nil
                deletionStatus = .none
            }
        } catch {
            errorMessage = "Available history couldn’t be rebuilt."
        }
        return state(refreshSamples: true)
    }

    private func state(
        fallback: [UsageSample] = [],
        issue: Issue? = nil,
        refreshSamples: Bool = false
    ) -> State {
        if refreshSamples {
            let local = readWorkingSet(from: activeLocalDirectory)
            if local.hadError && errorMessage == nil {
                errorMessage = "Some usage history couldn’t be read."
            }
            knownSamples = local.hadError || errorMessage != nil
                ? boundedWorkingSet(local.samples + knownSamples + fallback)
                : local.samples
        } else if !fallback.isEmpty {
            knownSamples = boundedWorkingSet(knownSamples + fallback)
        }
        return State(
            samples: knownSamples,
            folderName: syncDirectory?.lastPathComponent,
            errorMessage: errorMessage,
            deletionStatus: deletionStatus,
            issue: issue
        )
    }

    private func prepareRoot(
        _ root: URL,
        createIfMissing: Bool,
        coordinated: Bool,
        requiresLineage: Bool = false
    ) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        if !exists {
            guard createIfMissing else { throw HistoryError.unavailableFolder }
            try createDirectory(at: root, coordinated: coordinated)
        } else if !isDirectory.boolValue {
            throw HistoryError.invalidFolder
        }

        let marker = root.appendingPathComponent(Self.markerName)
        if FileManager.default.fileExists(atPath: marker.path) {
            let value = try JSONDecoder().decode(
                Marker.self,
                from: readData(at: marker, coordinated: coordinated)
            )
            guard value.version == 1 || value.version == Self.folderFormatVersion else {
                throw HistoryError.unsupportedFolderVersion
            }
            if value.version == 1 {
                try writeMarker(
                    to: marker,
                    generation: 1,
                    pendingDeletion: false,
                    coordinated: coordinated
                )
            }
        } else {
            let entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard entries.isEmpty else { throw HistoryError.invalidFolder }
            try writeMarker(
                to: marker,
                generation: 1,
                pendingDeletion: false,
                coordinated: coordinated
            )
        }

        try createDirectory(
            at: installationsDirectory(in: root),
            coordinated: coordinated
        )
        if requiresLineage {
            try createDirectory(
                at: root.appendingPathComponent(Self.lineagesName, isDirectory: true),
                coordinated: coordinated
            )
            try createDirectory(
                at: root.appendingPathComponent(Self.deletionsName, isDirectory: true),
                coordinated: coordinated
            )
            _ = try ensureSyncLineage(in: root)
        }
    }

    private func add(
        _ samples: [UsageSample],
        to root: URL,
        installationID: String,
        generation: Int? = nil,
        coordinated: Bool
    ) throws {
        let valid = normalized(samples)
        guard !valid.isEmpty else { return }
        let grouped = Dictionary(grouping: valid, by: { dayName(for: $0.observedAt) })
        let writerDirectory = installationsDirectory(in: root, generation: generation)
            .appendingPathComponent(installationID, isDirectory: true)
        try createDirectory(at: writerDirectory, coordinated: coordinated)

        for day in grouped.keys.sorted() {
            guard let newSamples = grouped[day] else { continue }
            let url = writerDirectory.appendingPathComponent("\(day).json")
            let existing = try readDailyFileIfPresent(
                at: url,
                generation: generation,
                coordinated: coordinated
            )
            let merged = normalized(existing + newSamples)
            guard merged != existing else { continue }
            try write(
                merged,
                to: url,
                generation: generation,
                coordinated: coordinated
            )
            try noteChangedDay(
                day,
                in: writerDirectory,
                generation: generation ?? 1,
                coordinated: coordinated
            )
        }
    }

    private func noteChangedDay(
        _ day: String,
        in writerDirectory: URL,
        generation: Int,
        coordinated: Bool
    ) throws {
        guard date(forDayName: day) != nil else {
            throw HistoryError.invalidFile
        }
        let url = writerDirectory.appendingPathComponent(
            Self.writerManifestName
        )
        let existing: WriterManifest? = if FileManager.default.fileExists(
            atPath: url.path
        ) {
            try JSONDecoder().decode(
                WriterManifest.self,
                from: readData(at: url, coordinated: coordinated)
            )
        } else {
            nil
        }
        if let existing {
            guard existing.version == 1,
                  existing.generation == generation,
                  date(forDayName: existing.oldestDay) != nil,
                  date(forDayName: existing.newestDay) != nil,
                  date(forDayName: existing.latestChangedDay) != nil,
                  existing.revision < UInt64.max else {
                throw HistoryError.invalidFile
            }
        }
        let manifest = WriterManifest(
            version: 1,
            generation: generation,
            oldestDay: min(existing?.oldestDay ?? day, day),
            newestDay: max(existing?.newestDay ?? day, day),
            latestChangedDay: day,
            revision: (existing?.revision ?? 0) + 1
        )
        try writeData(
            try JSONEncoder().encode(manifest),
            to: url,
            coordinated: coordinated
        )
    }

    private func writerManifest(
        in writerDirectory: URL,
        generation: Int,
        coordinated: Bool
    ) throws -> WriterManifest? {
        let url = writerDirectory.appendingPathComponent(
            Self.writerManifestName
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let manifest = try JSONDecoder().decode(
            WriterManifest.self,
            from: readData(at: url, coordinated: coordinated)
        )
        guard manifest.version == 1,
              manifest.generation == generation,
              date(forDayName: manifest.oldestDay) != nil,
              date(forDayName: manifest.newestDay) != nil,
              date(forDayName: manifest.latestChangedDay) != nil,
              manifest.oldestDay <= manifest.newestDay else {
            throw HistoryError.invalidFile
        }
        return manifest
    }

    private func ensureWriterManifest(
        in writerDirectory: URL,
        generation: Int,
        coordinated: Bool
    ) throws -> WriterManifest? {
        if let manifest = try writerManifest(
            in: writerDirectory,
            generation: generation,
            coordinated: coordinated
        ) {
            return manifest
        }
        let days = try jsonFiles(in: writerDirectory)
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { date(forDayName: $0) != nil }
            .sorted()
        guard let oldestDay = days.first,
              let newestDay = days.last else {
            return nil
        }
        let manifest = WriterManifest(
            version: 1,
            generation: generation,
            oldestDay: oldestDay,
            newestDay: newestDay,
            latestChangedDay: newestDay,
            revision: 1
        )
        try writeData(
            try JSONEncoder().encode(manifest),
            to: writerDirectory.appendingPathComponent(
                Self.writerManifestName
            ),
            coordinated: coordinated
        )
        return manifest
    }

    private func syncProgress(
        lineageID: String,
        generation: Int
    ) -> SyncProgress {
        let url = activeLocalDirectory.appendingPathComponent(
            Self.syncProgressName
        )
        if let data = try? readData(at: url, coordinated: false),
           let progress = try? JSONDecoder().decode(
               SyncProgress.self,
               from: data
           ), progress.version == 1,
           progress.lineageID == lineageID,
           progress.generation == generation {
            return progress
        }
        return SyncProgress(
            version: 1,
            lineageID: lineageID,
            generation: generation,
            publication: WriterCursor(
                nextDay: nil,
                observedRevision: nil
            ),
            imports: [:],
            nextImportWriter: nil
        )
    }

    private func saveSyncProgress(_ progress: SyncProgress) throws {
        try writeData(
            try JSONEncoder().encode(progress),
            to: activeLocalDirectory.appendingPathComponent(
                Self.syncProgressName
            ),
            coordinated: false
        )
    }

    private func automaticCandidates(
        manifest: WriterManifest,
        cursor: inout WriterCursor,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []
        if cursor.observedRevision != manifest.revision {
            result.append(manifest.latestChangedDay)
            cursor.observedRevision = manifest.revision
        }
        var next = cursor.nextDay.flatMap { day in
            day >= manifest.oldestDay && day <= manifest.newestDay
                ? day
                : nil
        } ?? manifest.oldestDay
        var visited: Set<String> = []
        while result.count < limit, visited.insert(next).inserted {
            if !result.contains(next) {
                result.append(next)
            }
            guard let following = nextDay(after: next) else { break }
            next = following > manifest.newestDay
                ? manifest.oldestDay
                : following
            cursor.nextDay = next
        }
        return result
    }

    private func importHistory(
        from remoteRoot: URL,
        generation: Int
    ) throws -> Bool {
        let remoteInstallations = installationsDirectory(
            in: remoteRoot,
            generation: generation
        )
        let localInstallations = installationsDirectory(in: activeLocalDirectory)
        var hadError = false
        for remoteWriter in try directoryContents(of: remoteInstallations) {
            let localWriter = localInstallations.appendingPathComponent(
                remoteWriter.lastPathComponent,
                isDirectory: true
            )
            try createDirectory(at: localWriter, coordinated: false)
            for remoteFile in try jsonFiles(in: remoteWriter).sorted(by: {
                $0.lastPathComponent < $1.lastPathComponent
            }) {
                do {
                    let localFile = localWriter.appendingPathComponent(remoteFile.lastPathComponent)
                    let remoteSamples = try readDailyFileIfPresent(
                        at: remoteFile,
                        generation: generation,
                        coordinated: true
                    )
                    let localSamples = try readDailyFileIfPresent(at: localFile, coordinated: false)
                    let merged = normalized(localSamples + remoteSamples)
                    if merged != localSamples {
                        try write(
                            merged,
                            to: localFile,
                            coordinated: false
                        )
                        try noteChangedDay(
                            remoteFile.deletingPathExtension().lastPathComponent,
                            in: localWriter,
                            generation: 1,
                            coordinated: false
                        )
                    }
                    knownSamples = boundedWorkingSet(knownSamples + merged)
                } catch {
                    hadError = true
                }
            }
        }
        return hadError
    }

    private func publishOwnHistory(
        to remoteRoot: URL,
        generation: Int
    ) throws {
        let localWriter = installationsDirectory(in: activeLocalDirectory)
            .appendingPathComponent(installationID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: localWriter.path) else { return }
        let remoteWriter = installationsDirectory(
            in: remoteRoot,
            generation: generation
        )
            .appendingPathComponent(installationID, isDirectory: true)
        try createDirectory(at: remoteWriter, coordinated: true)
        for localFile in try jsonFiles(in: localWriter).sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            let remoteFile = remoteWriter.appendingPathComponent(localFile.lastPathComponent)
            let localSamples = try readDailyFileIfPresent(at: localFile, coordinated: false)
            let remoteSamples = try readDailyFileIfPresent(
                at: remoteFile,
                generation: generation,
                coordinated: true
            )
            let merged = normalized(localSamples + remoteSamples)
            let day = localFile.deletingPathExtension().lastPathComponent
            if merged != localSamples {
                try write(merged, to: localFile, coordinated: false)
                try noteChangedDay(
                    day,
                    in: localWriter,
                    generation: 1,
                    coordinated: false
                )
            }
            if merged != remoteSamples {
                try write(
                    merged,
                    to: remoteFile,
                    generation: generation,
                    coordinated: true
                )
                try noteChangedDay(
                    day,
                    in: remoteWriter,
                    generation: generation,
                    coordinated: true
                )
            }
            knownSamples = boundedWorkingSet(knownSamples + merged)
        }
    }

    private func synchronizeBounded(
        with remoteRoot: URL,
        generation: Int,
        lineageID: String
    ) throws -> Bool {
        var progress = syncProgress(
            lineageID: lineageID,
            generation: generation
        )
        var remaining = Self.maximumAutomaticSyncCandidates
        var hadError = false
        let remoteInstallations = installationsDirectory(
            in: remoteRoot,
            generation: generation
        )
        let remoteWriters = try directoryContents(of: remoteInstallations)
            .filter { $0.lastPathComponent != installationID }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let localWriter = installationsDirectory(in: activeLocalDirectory)
            .appendingPathComponent(installationID, isDirectory: true)
        if FileManager.default.fileExists(atPath: localWriter.path),
           let manifest = try ensureWriterManifest(
               in: localWriter,
               generation: 1,
               coordinated: false
           ) {
            var cursor = progress.publication
            let limit = remoteWriters.isEmpty
                ? remaining
                : min(8, remaining)
            let days = automaticCandidates(
                manifest: manifest,
                cursor: &cursor,
                limit: limit
            )
            let remoteWriter = remoteInstallations.appendingPathComponent(
                installationID,
                isDirectory: true
            )
            try createDirectory(at: remoteWriter, coordinated: true)
            for day in days {
                hadError = try publishDay(
                    day,
                    from: localWriter,
                    to: remoteWriter,
                    generation: generation
                ) || hadError
            }
            progress.publication = cursor
            remaining -= days.count
        }

        let orderedWriters = rotatedWriters(
            remoteWriters,
            startingAt: progress.nextImportWriter
        )
        var lastWriterID: String?
        for (index, remoteWriter) in orderedWriters.enumerated()
            where remaining > 0 {
            let writerID = remoteWriter.lastPathComponent
            let writersLeft = orderedWriters.count - index
            let limit = max(remaining / max(writersLeft, 1), 1)
            guard let manifest = try ensureWriterManifest(
                in: remoteWriter,
                generation: generation,
                coordinated: true
            ) else {
                lastWriterID = writerID
                continue
            }
            var cursor = progress.imports[writerID] ?? WriterCursor(
                nextDay: nil,
                observedRevision: nil
            )
            let days = automaticCandidates(
                manifest: manifest,
                cursor: &cursor,
                limit: min(limit, remaining)
            )
            let localWriter = installationsDirectory(in: activeLocalDirectory)
                .appendingPathComponent(writerID, isDirectory: true)
            try createDirectory(at: localWriter, coordinated: false)
            for day in days {
                hadError = try importDay(
                    day,
                    from: remoteWriter,
                    to: localWriter,
                    generation: generation
                ) || hadError
            }
            progress.imports[writerID] = cursor
            remaining -= days.count
            lastWriterID = writerID
        }
        if let lastWriterID,
           let index = remoteWriters.firstIndex(where: {
               $0.lastPathComponent == lastWriterID
           }), !remoteWriters.isEmpty {
            progress.nextImportWriter = remoteWriters[
                (index + 1) % remoteWriters.count
            ].lastPathComponent
        }
        try saveSyncProgress(progress)
        return hadError
    }

    private func rotatedWriters(
        _ writers: [URL],
        startingAt writerID: String?
    ) -> [URL] {
        guard let writerID,
              let index = writers.firstIndex(where: {
                  $0.lastPathComponent >= writerID
              }), index > 0 else {
            return writers
        }
        return Array(writers[index...]) + Array(writers[..<index])
    }

    private func importDay(
        _ day: String,
        from remoteWriter: URL,
        to localWriter: URL,
        generation: Int
    ) throws -> Bool {
        let remoteFile = remoteWriter.appendingPathComponent("\(day).json")
        guard FileManager.default.fileExists(atPath: remoteFile.path) else {
            return false
        }
        let localFile = localWriter.appendingPathComponent("\(day).json")
        let localSamples: [UsageSample]
        let remoteSamples: [UsageSample]
        do {
            localSamples = try readDailyFileIfPresent(
                at: localFile,
                coordinated: false
            )
            remoteSamples = try readDailyFileIfPresent(
                at: remoteFile,
                generation: generation,
                coordinated: true
            )
        } catch {
            guard isMalformedHistoryFileError(error) else { throw error }
            return true
        }
        let merged = normalized(localSamples + remoteSamples)
        if merged != localSamples {
            try write(merged, to: localFile, coordinated: false)
            try noteChangedDay(
                day,
                in: localWriter,
                generation: 1,
                coordinated: false
            )
        }
        knownSamples = boundedWorkingSet(knownSamples + merged)
        return false
    }

    private func publishDay(
        _ day: String,
        from localWriter: URL,
        to remoteWriter: URL,
        generation: Int
    ) throws -> Bool {
        let localFile = localWriter.appendingPathComponent("\(day).json")
        guard FileManager.default.fileExists(atPath: localFile.path) else {
            return false
        }
        let remoteFile = remoteWriter.appendingPathComponent("\(day).json")
        let localSamples: [UsageSample]
        let remoteSamples: [UsageSample]
        do {
            localSamples = try readDailyFileIfPresent(
                at: localFile,
                coordinated: false
            )
            remoteSamples = try readDailyFileIfPresent(
                at: remoteFile,
                generation: generation,
                coordinated: true
            )
        } catch {
            guard isMalformedHistoryFileError(error) else { throw error }
            return true
        }
        let merged = normalized(localSamples + remoteSamples)
        if merged != localSamples {
            try write(merged, to: localFile, coordinated: false)
        }
        if merged != remoteSamples {
            try write(
                merged,
                to: remoteFile,
                generation: generation,
                coordinated: true
            )
            try noteChangedDay(
                day,
                in: remoteWriter,
                generation: generation,
                coordinated: true
            )
        }
        knownSamples = boundedWorkingSet(knownSamples + merged)
        return false
    }

    private func isMalformedHistoryFileError(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        switch error {
        case HistoryError.invalidFile, HistoryError.unsupportedFileVersion:
            return true
        default:
            return false
        }
    }

    private func readAll(from root: URL) -> (samples: [UsageSample], hadError: Bool) {
        var samples: [UsageSample] = []
        var hadError = false
        let directory = installationsDirectory(in: root)
        do {
            for writer in try directoryContents(of: directory) {
                do {
                    for file in try jsonFiles(in: writer) {
                        do {
                            samples += try readDailyFileIfPresent(at: file, coordinated: false)
                        } catch {
                            hadError = true
                        }
                    }
                } catch {
                    hadError = true
                }
            }
        } catch {
            hadError = true
        }
        return (normalized(samples), hadError)
    }

    private func readWorkingSet(
        from root: URL
    ) -> (samples: [UsageSample], hadError: Bool) {
        var samples: [UsageSample] = []
        var hadError = false
        var budget = WorkingSetReadBudget()
        let directory = installationsDirectory(in: root)
        do {
            let writers = try boundedWorkingSetWriters(in: directory)
            hadError = writers.didReachLimit
            writerLoop: for writer in writers.values {
                do {
                    for file in try workingSetFiles(in: writer) {
                        do {
                            guard try budget.admit(file) else {
                                if budget.didReachLimit {
                                    hadError = true
                                    break writerLoop
                                }
                                continue
                            }
                            samples = boundedWorkingSet(
                                samples + (try readDailyFileIfPresent(
                                    at: file,
                                    coordinated: false
                                ))
                            )
                        } catch {
                            hadError = true
                        }
                    }
                } catch {
                    hadError = true
                }
            }
        } catch {
            hadError = true
        }
        return (boundedWorkingSet(samples), hadError)
    }

    private func readDailyFileIfPresent(
        at url: URL,
        generation: Int? = nil,
        coordinated: Bool
    ) throws -> [UsageSample] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let value = try JSONDecoder().decode(
            DailyFile.self,
            from: readData(at: url, coordinated: coordinated)
        )
        guard value.version == Self.dailyFileVersion else {
            throw HistoryError.unsupportedFileVersion
        }
        if let generation, value.generation ?? 1 != generation {
            return []
        }
        return value.samples
    }

    private func write(
        _ samples: [UsageSample],
        to url: URL,
        generation: Int? = nil,
        coordinated: Bool
    ) throws {
        let value = DailyFile(
            version: Self.dailyFileVersion,
            generation: generation,
            samples: samples
        )
        let data = try JSONEncoder().encode(value)
        try writeData(data, to: url, coordinated: coordinated)
    }

    private func readData(at url: URL, coordinated: Bool) throws -> Data {
        guard coordinated, isUbiquitousItem(url) else { return try checkedData(at: url) }
        var result: Result<Data, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result { try checkedData(at: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw HistoryError.unavailableFolder }
        return try result.get()
    }

    private func writeData(_ data: Data, to url: URL, coordinated: Bool) throws {
        guard coordinated, isUbiquitousItem(url) else {
            try data.write(to: url, options: .atomic)
            return
        }
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let coordinationURL = fileExists ? url : url.deletingLastPathComponent()
        var writeError: Error?
        var coordinationError: NSError?
        var didWrite = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: coordinationURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let destination = fileExists
                    ? coordinatedURL
                    : coordinatedURL.appendingPathComponent(url.lastPathComponent)
                try data.write(to: destination, options: .atomic)
                didWrite = true
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        guard didWrite else { throw HistoryError.unavailableFolder }
    }

    private func removeItem(at url: URL, coordinated: Bool) throws {
        guard coordinated, isUbiquitousItem(url) else {
            try FileManager.default.removeItem(at: url)
            return
        }
        var removeError: Error?
        var coordinationError: NSError?
        var didRemove = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
                didRemove = true
            } catch {
                removeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let removeError { throw removeError }
        guard didRemove else { throw HistoryError.unavailableFolder }
    }

    private func createDirectory(at url: URL, coordinated: Bool) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        guard coordinated, isUbiquitousItem(url) else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return
        }
        var createError: Error?
        var coordinationError: NSError?
        var didCreate = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url.deletingLastPathComponent(),
            options: [],
            error: &coordinationError
        ) { coordinatedParent in
            do {
                let directory = coordinatedParent.appendingPathComponent(url.lastPathComponent)
                if !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: false
                    )
                }
                didCreate = true
            } catch {
                createError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let createError { throw createError }
        guard didCreate else { throw HistoryError.unavailableFolder }
    }

    private func checkedData(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard (size ?? 0) <= Self.maximumFileSize else {
            throw HistoryError.invalidFile
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumFileSize else {
            throw HistoryError.invalidFile
        }
        return data
    }

    private func isUbiquitousItem(_ url: URL) -> Bool {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path),
              candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        return (try? candidate.resourceValues(
            forKeys: [.isUbiquitousItemKey]
        ).isUbiquitousItem) == true
    }

    private func normalized(_ samples: [UsageSample]) -> [UsageSample] {
        let valid = samples.filter(\.hasValidObservationMetadata)
        let normalized = Dictionary(grouping: valid, by: { $0 }).values
            .flatMap { matchingSamples -> [UsageSample] in
                let sample = matchingSamples[0]
                let comparisonBreak = matchingSamples.contains {
                    $0.comparisonBreak
                }
                let counters = Set(matchingSamples.compactMap(\.lifetimeTokens))
                if counters.isEmpty {
                    return [UsageSample(
                        observedAt: sample.observedAt,
                        remainingPercent: sample.remainingPercent,
                        resetsAt: sample.resetsAt,
                        comparisonBreak: comparisonBreak
                    )]
                }
                return counters.map {
                    UsageSample(
                        observedAt: sample.observedAt,
                        remainingPercent: sample.remainingPercent,
                        resetsAt: sample.resetsAt,
                        lifetimeTokens: $0,
                        comparisonBreak: comparisonBreak
                    )
                }
            }
        return normalized.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            if $0.remainingPercent != $1.remainingPercent {
                return $0.remainingPercent > $1.remainingPercent
            }
            if $0.resetsAt != $1.resetsAt { return $0.resetsAt < $1.resetsAt }
            return ($0.lifetimeTokens ?? .min) < ($1.lifetimeTokens ?? .min)
        }
    }

    private func boundedWorkingSet(_ samples: [UsageSample]) -> [UsageSample] {
        let ordered = normalized(samples)
        guard let newest = ordered.last?.observedAt else { return [] }
        let cutoff = newest.addingTimeInterval(-Self.workingSetDuration)
        let fullResolutionStart = newest.addingTimeInterval(
            -Self.fullResolutionDuration
        )
        var result: [UsageSample] = []
        var bucketFirst: UsageSample?
        var bucketLast: UsageSample?
        var bucketCount = 0
        var bucketNumber: Int?
        var bucketReset: Date?

        func flushBucket() {
            guard let first = bucketFirst else { return }
            result.append(first)
            if bucketCount > 1, let last = bucketLast {
                result.append(last)
            }
            bucketFirst = nil
            bucketLast = nil
            bucketCount = 0
            bucketNumber = nil
            bucketReset = nil
        }

        for sample in ordered where sample.observedAt >= cutoff {
            if sample.observedAt >= fullResolutionStart || sample.comparisonBreak {
                flushBucket()
                result.append(sample)
                continue
            }
            let number = Int(floor(
                sample.observedAt.timeIntervalSinceReferenceDate
                    / Self.historicalBucketDuration
            ))
            if bucketNumber != number || bucketReset != sample.resetsAt {
                flushBucket()
                bucketFirst = sample
                bucketNumber = number
                bucketReset = sample.resetsAt
            }
            bucketLast = sample
            bucketCount += 1
        }
        flushBucket()
        return Array(result.suffix(Self.maximumWorkingSetSamples))
    }

    private func boundedRangeSamples(
        _ samples: [UsageSample]
    ) -> (samples: [UsageSample], didDownsample: Bool) {
        let ordered = normalized(samples)
        guard ordered.count > Self.maximumWorkingSetSamples else {
            return (ordered, false)
        }
        var reduced: [UsageSample] = []
        var bucket: [UsageSample] = []
        var bucketNumber: Int?
        var bucketReset: Date?

        func flushBucket() {
            guard let first = bucket.first else { return }
            reduced.append(first)
            if let last = bucket.last, last != first {
                reduced.append(last)
            }
            bucket = []
            bucketNumber = nil
            bucketReset = nil
        }

        for sample in ordered {
            if sample.comparisonBreak {
                flushBucket()
                reduced.append(sample)
                continue
            }
            let number = Int(floor(
                sample.observedAt.timeIntervalSinceReferenceDate
                    / Self.historicalBucketDuration
            ))
            if bucketNumber != number || bucketReset != sample.resetsAt {
                flushBucket()
                bucketNumber = number
                bucketReset = sample.resetsAt
            }
            bucket.append(sample)
        }
        flushBucket()
        guard reduced.count > Self.maximumWorkingSetSamples else {
            return (reduced, true)
        }
        let lastIndex = reduced.count - 1
        let capped = (0 ..< Self.maximumWorkingSetSamples).map { index in
            reduced[Int(
                (Double(index) * Double(lastIndex)
                    / Double(Self.maximumWorkingSetSamples - 1)).rounded()
            )]
        }
        return (capped, true)
    }

    private func installationsDirectory(
        in root: URL,
        generation: Int? = nil
    ) -> URL {
        let base = root.appendingPathComponent(Self.installationsName, isDirectory: true)
        guard let generation, generation > 1 else { return base }
        return base.appendingPathComponent(
            "generation-\(generation)",
            isDirectory: true
        )
    }

    private func prepareLocalStore() throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: localDirectory.path,
            isDirectory: &isDirectory
        )
        if !exists {
            try createDirectory(at: localDirectory, coordinated: false)
        } else if !isDirectory.boolValue {
            throw HistoryError.invalidFolder
        }

        let markerURL = localDirectory.appendingPathComponent(Self.markerName)
        if FileManager.default.fileExists(atPath: markerURL.path) {
            let marker = try JSONDecoder().decode(
                Marker.self,
                from: readData(at: markerURL, coordinated: false)
            )
            if marker.version == 1 {
                try migrateVersionOneLocalStore(markerURL: markerURL)
            } else {
                guard marker.version == Self.folderFormatVersion else {
                    throw HistoryError.unsupportedFolderVersion
                }
                migrationWarning = marker.migrationWarning == true
                if marker.pendingDeletion == true {
                    if marker.pendingDeletionTarget == .localOnly {
                        if marker.localDeletionComplete != true {
                            try removeAllLocalHistory()
                            knownSamples = []
                        }
                        try writeMarker(
                            to: markerURL,
                            generation: marker.generation ?? 1,
                            pendingDeletion: false,
                            coordinated: false
                        )
                        deletionStatus = .complete
                    } else {
                        deletionStatus = .pendingSync
                    }
                }
            }
        } else {
            let entries = try FileManager.default.contentsOfDirectory(
                at: localDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard entries.isEmpty else { throw HistoryError.invalidFolder }
            try writeMarker(
                to: markerURL,
                generation: 1,
                pendingDeletion: false,
                coordinated: false
            )
        }

        try createDirectory(
            at: localDirectory.appendingPathComponent("partitions", isDirectory: true),
            coordinated: false
        )
    }

    private func migrateVersionOneLocalStore(markerURL: URL) throws {
        let legacy = readAll(from: localDirectory)
        try prepareRoot(activeLocalDirectory, createIfMissing: true, coordinated: false)
        try add(
            legacy.samples,
            to: activeLocalDirectory,
            installationID: installationID,
            coordinated: false
        )
        migrationWarning = legacy.hadError
        try writeMarker(
            to: markerURL,
            generation: 1,
            pendingDeletion: false,
            coordinated: false
        )
        let legacyInstallations = installationsDirectory(in: localDirectory)
        if !legacy.hadError,
           FileManager.default.fileExists(atPath: legacyInstallations.path) {
            try removeItem(at: legacyInstallations, coordinated: false)
        }
    }

    private func writeMarker(
        to url: URL,
        generation: Int,
        pendingDeletion: Bool,
        localDeletionComplete: Bool = false,
        pendingDeletionTarget: PendingDeletionTarget? = nil,
        pendingSyncTarget: String? = nil,
        syncTarget: String? = nil,
        lineageID: String? = nil,
        coordinated: Bool
    ) throws {
        let data = try JSONEncoder().encode(Marker(
            version: Self.folderFormatVersion,
            generation: generation,
            pendingDeletion: pendingDeletion,
            localDeletionComplete: localDeletionComplete,
            pendingDeletionTarget: pendingDeletionTarget,
            pendingSyncTarget: pendingSyncTarget,
            syncTarget: syncTarget,
            lineageID: lineageID,
            migrationWarning: migrationWarning
        ))
        try writeData(data, to: url, coordinated: coordinated)
    }

    private func readMarker(at url: URL, coordinated: Bool) throws -> Marker {
        let marker = try JSONDecoder().decode(
            Marker.self,
            from: readData(at: url, coordinated: coordinated)
        )
        guard let generation = marker.generation,
              (1 ... Self.maximumGeneration).contains(generation) else {
            throw HistoryError.invalidFile
        }
        return marker
    }

    private func updateMarkerAtomically(
        at url: URL,
        _ update: (Marker) throws -> Marker
    ) throws -> Marker {
        func updateAtURL(_ target: URL) throws -> Marker {
            try self.beforeCoordinatedMarkerRead?(target)
            let current = try JSONDecoder().decode(
                Marker.self,
                from: self.checkedData(at: target)
            )
            guard current.version == Self.folderFormatVersion,
                  let currentGeneration = current.generation,
                  (1 ... Self.maximumGeneration).contains(currentGeneration) else {
                throw current.version == Self.folderFormatVersion
                    ? HistoryError.invalidFile
                    : HistoryError.unsupportedFolderVersion
            }
            let updated = try update(current)
            guard updated.version == Self.folderFormatVersion,
                  let updatedGeneration = updated.generation,
                  (1 ... Self.maximumGeneration).contains(updatedGeneration) else {
                throw updated.version == Self.folderFormatVersion
                    ? HistoryError.invalidFile
                    : HistoryError.unsupportedFolderVersion
            }
            try JSONEncoder().encode(updated).write(to: target, options: .atomic)
            return updated
        }
        guard isUbiquitousItem(url) else {
            return try Self.localMarkerUpdateLock.withLock {
                try updateAtURL(url)
            }
        }
        var result: Result<Marker, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result { try updateAtURL(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw HistoryError.unavailableFolder }
        return try result.get()
    }

    private func ensureSyncLineage(in root: URL) throws -> Set<String> {
        let markerURL = root.appendingPathComponent(Self.markerName)
        let marker = try readMarker(at: markerURL, coordinated: true)
        var lineages = try storedLineages(in: root)

        if let markerLineage = marker.lineageID,
           isValidLineage(markerLineage) {
            try storeLineageIfNeeded(markerLineage, in: root)
            lineages.insert(markerLineage)
        }

        if lineages.isEmpty {
            let lineage = UUID().uuidString.lowercased()
            try storeLineageIfNeeded(lineage, in: root)
            lineages.insert(lineage)
        }

        if marker.lineageID == nil, let preferred = lineages.sorted().first {
            _ = try updateMarkerAtomically(at: markerURL) { current in
                guard current.lineageID == nil else { return current }
                return Marker(
                    version: Self.folderFormatVersion,
                    generation: current.generation ?? 1,
                    pendingDeletion: current.pendingDeletion ?? false,
                    localDeletionComplete: current.localDeletionComplete ?? false,
                    pendingDeletionTarget: current.pendingDeletionTarget,
                    pendingSyncTarget: current.pendingSyncTarget,
                    syncTarget: current.syncTarget,
                    lineageID: preferred,
                    migrationWarning: current.migrationWarning
                )
            }
        }
        return lineages
    }

    private func syncLineages(in root: URL) throws -> Set<String> {
        try ensureSyncLineage(in: root)
    }

    private func storedLineages(in root: URL) throws -> Set<String> {
        let directory = root.appendingPathComponent(Self.lineagesName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var result: Set<String> = []
        for file in try jsonFiles(in: directory) {
            guard let record = try? JSONDecoder().decode(
                LineageRecord.self,
                from: readData(at: file, coordinated: true)
            ), record.version == 1, isValidLineage(record.id) else {
                continue
            }
            result.insert(record.id)
        }
        return result
    }

    private func storeLineageIfNeeded(_ lineage: String, in root: URL) throws {
        guard isValidLineage(lineage) else { throw HistoryError.invalidFolder }
        let directory = root.appendingPathComponent(Self.lineagesName, isDirectory: true)
        let url = directory.appendingPathComponent("\(lineage).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try writeData(
            try JSONEncoder().encode(LineageRecord(version: 1, id: lineage)),
            to: url,
            coordinated: true
        )
    }

    private func isValidLineage(_ lineage: String) -> Bool {
        UUID(uuidString: lineage)?.uuidString.lowercased() == lineage
    }

    private func ensureAccountBinding(
        identity: String,
        in root: URL
    ) throws -> String {
        let normalized = identity
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { throw HistoryError.wrongAccount }
        let url = root.appendingPathComponent(Self.accountBindingName)
        if FileManager.default.fileExists(atPath: url.path) {
            let binding = try JSONDecoder().decode(
                AccountBinding.self,
                from: readData(at: url, coordinated: true)
            )
            guard binding.version == 1,
                  binding.salt.count == 32,
                  binding.digest == accountDigest(
                    identity: normalized,
                    salt: binding.salt
                  ) else {
                throw HistoryError.wrongAccount
            }
            return binding.digest
        }

        var generator = SystemRandomNumberGenerator()
        let salt = Data((0 ..< 32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
        let binding = AccountBinding(
            version: 1,
            salt: salt,
            digest: accountDigest(identity: normalized, salt: salt)
        )
        try writeData(
            try JSONEncoder().encode(binding),
            to: url,
            coordinated: true
        )
        let stored = try JSONDecoder().decode(
            AccountBinding.self,
            from: readData(at: url, coordinated: true)
        )
        guard stored.version == 1,
              stored.salt.count == 32,
              stored.digest == accountDigest(identity: normalized, salt: stored.salt) else {
            throw HistoryError.wrongAccount
        }
        return stored.digest
    }

    private func validateAccountBinding(
        token: String,
        in root: URL
    ) throws {
        let url = root.appendingPathComponent(Self.accountBindingName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HistoryError.wrongAccount
        }
        let binding = try JSONDecoder().decode(
            AccountBinding.self,
            from: readData(at: url, coordinated: true)
        )
        guard binding.version == 1,
              binding.salt.count == 32,
              binding.digest == token else {
            throw HistoryError.wrongAccount
        }
    }

    private func accountDigest(identity: String, salt: Data) -> String {
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(identity.utf8),
            using: SymmetricKey(data: salt)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func effectiveGeneration(
        in root: URL,
        lineages: Set<String>? = nil
    ) throws -> Int {
        let currentLineages = try lineages ?? syncLineages(in: root)
        let marker = try readMarker(
            at: root.appendingPathComponent(Self.markerName),
            coordinated: true
        )
        var generation = marker.generation ?? 1
        let directory = root.appendingPathComponent(Self.deletionsName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return generation
        }
        for file in try jsonFiles(in: directory) {
            guard let record = try? JSONDecoder().decode(
                DeletionRecord.self,
                from: readData(at: file, coordinated: true)
            ), record.version == 1,
               (1 ... Self.maximumGeneration).contains(record.generation),
               currentLineages.contains(record.lineageID) else {
                continue
            }
            generation = max(generation, record.generation)
        }
        return generation
    }

    private func storeDeletion(
        generation: Int,
        lineage: String,
        in root: URL
    ) throws {
        guard (2 ... Self.maximumGeneration).contains(generation),
              isValidLineage(lineage) else {
            throw HistoryError.invalidFolder
        }
        let directory = root.appendingPathComponent(Self.deletionsName, isDirectory: true)
        let url = directory.appendingPathComponent(
            "\(generation)-\(UUID().uuidString.lowercased()).json"
        )
        try writeData(
            try JSONEncoder().encode(DeletionRecord(
                version: 1,
                generation: generation,
                lineageID: lineage
            )),
            to: url,
            coordinated: true
        )
    }

    private func updateCompatibilityMarker(
        in root: URL,
        generation: Int,
        lineage: String
    ) throws {
        _ = try updateMarkerAtomically(
            at: root.appendingPathComponent(Self.markerName)
        ) { current in
            Marker(
                version: Self.folderFormatVersion,
                generation: max(current.generation ?? 1, generation),
                pendingDeletion: false,
                localDeletionComplete: false,
                pendingDeletionTarget: nil,
                pendingSyncTarget: nil,
                syncTarget: nil,
                lineageID: current.lineageID ?? lineage,
                migrationWarning: current.migrationWarning
            )
        }
    }

    private func removeAllLocalHistory() throws {
        let partitions = localDirectory.appendingPathComponent("partitions", isDirectory: true)
        if FileManager.default.fileExists(atPath: partitions.path) {
            try removeItem(at: partitions, coordinated: false)
        }
        let legacyInstallations = installationsDirectory(in: localDirectory)
        if FileManager.default.fileExists(atPath: legacyInstallations.path) {
            try removeItem(at: legacyInstallations, coordinated: false)
        }
        migrationWarning = false
        try createDirectory(at: partitions, coordinated: false)
        try prepareRoot(activeLocalDirectory, createIfMissing: true, coordinated: false)
    }

    private func removeSyncedHistory(
        beforeGeneration generation: Int,
        from root: URL
    ) throws {
        let installations = installationsDirectory(in: root)
        for directory in try directoryContents(of: installations) {
            if let storedGeneration = generationNumber(for: directory.lastPathComponent) {
                if storedGeneration < generation {
                    try removeItem(at: directory, coordinated: true)
                }
            } else if generation > 1 {
                try removeItem(at: directory, coordinated: true)
            }
        }
        try createDirectory(
            at: installationsDirectory(in: root, generation: generation),
            coordinated: true
        )
    }

    private func generationNumber(for directoryName: String) -> Int? {
        guard directoryName.hasPrefix("generation-"),
              let generation = Int(directoryName.dropFirst("generation-".count)),
              (2 ... Self.maximumGeneration).contains(generation) else {
            return nil
        }
        return generation
    }

    private func incrementedGeneration(after generation: Int) throws -> Int {
        guard (1 ..< Self.maximumGeneration).contains(generation) else {
            throw HistoryError.invalidFile
        }
        return generation + 1
    }

    private func beginPendingDeletion(
        generation: Int,
        target: PendingDeletionTarget,
        syncLineage: String? = nil
    ) throws {
        try writeMarker(
            to: localDirectory.appendingPathComponent(Self.markerName),
            generation: generation,
            pendingDeletion: true,
            localDeletionComplete: false,
            pendingDeletionTarget: target,
            pendingSyncTarget: syncLineage,
            syncTarget: syncLineage,
            coordinated: false
        )
        try removeAllLocalHistory()
        knownSamples = []
        try writeMarker(
            to: localDirectory.appendingPathComponent(Self.markerName),
            generation: generation,
            pendingDeletion: true,
            localDeletionComplete: true,
            pendingDeletionTarget: target,
            pendingSyncTarget: syncLineage,
            syncTarget: syncLineage,
            coordinated: false
        )
        deletionStatus = .pendingSync
    }

    private func completePendingDeletion(
        in remoteRoot: URL,
        generation: Int,
        bindsUnresolvedTarget: Bool = false
    ) throws {
        let localMarkerURL = localDirectory.appendingPathComponent(Self.markerName)
        let localMarker = try readMarker(at: localMarkerURL, coordinated: false)
        try prepareRoot(
            remoteRoot,
            createIfMissing: false,
            coordinated: true,
            requiresLineage: true
        )
        let remoteLineages = try syncLineages(in: remoteRoot)
        guard let remoteLineage = localMarker.pendingSyncTarget
            ?? localMarker.syncTarget
            ?? remoteLineages.sorted().first else {
            throw HistoryError.invalidFolder
        }
        if let expectedTarget = localMarker.pendingSyncTarget,
           !remoteLineages.contains(expectedTarget) {
            throw HistoryError.wrongDeletionFolder
        }
        if localMarker.pendingDeletion == true,
           localMarker.pendingDeletionTarget != .boundSync,
           localMarker.pendingSyncTarget == nil,
           !bindsUnresolvedTarget {
            throw HistoryError.wrongDeletionFolder
        }
        if localMarker.pendingDeletion == true,
           localMarker.localDeletionComplete != true {
            try removeAllLocalHistory()
            knownSamples = []
        }
        guard remoteLineages.contains(remoteLineage) else {
            throw HistoryError.wrongDeletionFolder
        }
        let remoteGeneration = try effectiveGeneration(
            in: remoteRoot,
            lineages: remoteLineages
        )
        let effectiveGeneration = max(
            try incrementedGeneration(after: remoteGeneration),
            generation
        )
        try storeDeletion(
            generation: effectiveGeneration,
            lineage: remoteLineage,
            in: remoteRoot
        )
        try updateCompatibilityMarker(
            in: remoteRoot,
            generation: effectiveGeneration,
            lineage: remoteLineage
        )
        try writeMarker(
            to: localMarkerURL,
            generation: effectiveGeneration,
            pendingDeletion: true,
            localDeletionComplete: true,
            pendingDeletionTarget: .boundSync,
            pendingSyncTarget: localMarker.pendingSyncTarget,
            syncTarget: remoteLineage,
            coordinated: false
        )
        try removeSyncedHistory(
            beforeGeneration: effectiveGeneration,
            from: remoteRoot
        )
        try publishOwnHistory(
            to: remoteRoot,
            generation: effectiveGeneration
        )
        try writeMarker(
            to: localMarkerURL,
            generation: effectiveGeneration,
            pendingDeletion: false,
            syncTarget: remoteLineage,
            coordinated: false
        )
        deletionStatus = .complete
    }

    private func reconcileGeneration(with remoteRoot: URL) throws {
        let localMarkerURL = localDirectory.appendingPathComponent(Self.markerName)
        let localMarker = try readMarker(
            at: localMarkerURL,
            coordinated: false
        )
        let localGeneration = localMarker.generation ?? 1
        let remoteLineages = try syncLineages(in: remoteRoot)
        guard let target = localMarker.syncTarget.flatMap({
            remoteLineages.contains($0) ? $0 : nil
        }) ?? remoteLineages.sorted().first else {
            throw HistoryError.invalidFolder
        }
        let remoteGeneration = try effectiveGeneration(
            in: remoteRoot,
            lineages: remoteLineages
        )
        if remoteGeneration > 1 {
            try removeSyncedHistory(
                beforeGeneration: remoteGeneration,
                from: remoteRoot
            )
        }

        if localMarker.syncTarget == nil
            || !remoteLineages.contains(localMarker.syncTarget!) {
            if remoteGeneration > 1 {
                try removeAllLocalHistory()
                knownSamples = []
            }
            try writeMarker(
                to: localMarkerURL,
                generation: remoteGeneration,
                pendingDeletion: false,
                syncTarget: target,
                coordinated: false
            )
            return
        }

        if remoteGeneration > localGeneration {
            try removeAllLocalHistory()
            knownSamples = []
            try writeMarker(
                to: localMarkerURL,
                generation: remoteGeneration,
                pendingDeletion: false,
                syncTarget: target,
                coordinated: false
            )
        } else if localGeneration > remoteGeneration {
            try storeDeletion(
                generation: localGeneration,
                lineage: target,
                in: remoteRoot
            )
            try updateCompatibilityMarker(
                in: remoteRoot,
                generation: localGeneration,
                lineage: target
            )
            let updatedGeneration = try effectiveGeneration(
                in: remoteRoot,
                lineages: remoteLineages
            )
            if updatedGeneration > localGeneration {
                try removeAllLocalHistory()
                knownSamples = []
                try writeMarker(
                    to: localMarkerURL,
                    generation: updatedGeneration,
                    pendingDeletion: false,
                    syncTarget: target,
                    coordinated: false
                )
            } else {
                try removeSyncedHistory(
                    beforeGeneration: localGeneration,
                    from: remoteRoot
                )
            }
        }
    }

    private var activeLocalDirectory: URL {
        localDirectory
            .appendingPathComponent("partitions", isDirectory: true)
            .appendingPathComponent(partition.id, isDirectory: true)
    }

    private func directoryContents(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func boundedWorkingSetWriters(
        in directory: URL
    ) throws -> (values: [URL], didReachLimit: Bool) {
        var values: [URL] = []
        let preferred = directory.appendingPathComponent(
            installationID,
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: preferred.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            values.append(preferred)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return (values, false)
        }
        for case let url as URL in enumerator {
            guard url.standardizedFileURL != preferred.standardizedFileURL,
                  (try? url.resourceValues(
                    forKeys: [.isDirectoryKey]
                  ).isDirectory) == true else {
                continue
            }
            guard values.count < Self.maximumWorkingSetWriters else {
                // ponytail: cap cold fan-out; add a compact partition summary
                // if real histories exceed 32 contributing installations.
                return (values, true)
            }
            values.append(url)
        }
        return (values, false)
    }

    private func jsonFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.pathExtension == "json"
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func workingSetFiles(in writerDirectory: URL) throws -> [URL] {
        guard let manifest = try ensureWriterManifest(
            in: writerDirectory,
            generation: 1,
            coordinated: false
        ), let newest = date(forDayName: manifest.newestDay) else {
            return []
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return (0 ..< Self.workingSetFileDays).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: newest).map {
                writerDirectory.appendingPathComponent("\(dayName(for: $0)).json")
            }
        }
    }

    private func dayName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func date(forDayName day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let dayOfMonth = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: dayOfMonth
        )), dayName(for: date) == day else {
            return nil
        }
        return date
    }

    private func nextDay(after day: String) -> String? {
        guard let date = date(forDayName: day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: 1, to: date).map(dayName)
    }

    private func dayNames(in interval: DateInterval) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var date = calendar.startOfDay(for: interval.start)
        var result: [String] = []
        while date <= interval.end, result.count <= Self.workingSetFileDays {
            result.append(dayName(for: date))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else {
                break
            }
            date = next
        }
        return result
    }

    private func message(for error: Error) -> String {
        switch error {
        case HistoryError.invalidFolder:
            "Choose an empty folder or an existing Codex Limits history folder."
        case HistoryError.unsupportedFolderVersion:
            "This history folder was created by a newer version of Codex Limits."
        case HistoryError.unavailableFolder:
            "Sync paused — folder unavailable."
        case HistoryError.wrongDeletionFolder:
            "Reconnect the folder used for this deletion."
        case HistoryError.wrongAccount:
            "This history folder belongs to a different Codex account."
        default:
            "Some synced history couldn’t be read."
        }
    }
}
