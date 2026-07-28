import AppKit
import Combine
import Foundation

@MainActor
final class UsageMonitor: ObservableObject {
    static let safetyBufferKey = "safetyBuffer"

    @Published private(set) var readerSnapshot = UsageIntelligenceEngine.evaluate(
        UsageIntelligenceInput(
            account: nil,
            samples: [],
            safetyBuffer: 3,
            sourceState: .available,
            now: .distantPast,
            previousStatus: nil
        )
    )
    @Published private(set) var samples: [UsageSample] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var syncFolderName: String?
    @Published private(set) var syncErrorMessage: String?
    @Published private(set) var historyDeletionStatus: UsageHistory.DeletionStatus = .none
    @Published private(set) var isUpdatingHistory = false

    private static let stateKey = "usageState"
    private static let historyInstallationIDKey = "historyInstallationID"
    private static let historySyncBookmarkKey = "historySyncBookmark"
    private static let historyPartitionKey = "historyAccountPartition"
    private static let historyFingerprintKey = "historyAccountFingerprintKey"
    private static let historyAuthStateKey = "historyAccountState"
    private static let historyAccountEpochStartedAtKey = "historyAccountEpochStartedAt"
    private static let historySyncSelectedKey = "historySyncSelected"
    private static let historySyncAccountBindingKey = "historySyncAccountBinding"
    private let defaults: UserDefaults
    private let history: UsageHistory
    private let fetchUsage: () async throws -> CodexFetchResult
    private var historyPartition: AccountHistoryPartition
    private var accountSnapshot: UsageSnapshot?
    private var sourceState: UsageSourceState = .available
    private var previousStatus: PaceStatus?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var historyPrepared = false
    private var historyUsesFiles = false
    private var configuredSyncDirectory: URL?
    private var historyConnectionActive = false
    private var accountWasObserved = false
    private var historyWasRestored = false
    private var restoredFileStoreAvailable = false
    private var historyAccountIdentity: String?
    private var accountEpochStartedAt: Date?
    private var historyMatchesCurrentSnapshot = false
    private var legacySamplesAwaitingMigration: [UsageSample] = []

    init(
        defaults: UserDefaults = .standard,
        historyDirectory: URL? = nil,
        startsAutomatically: Bool = true,
        fetchUsage: @escaping () async throws -> CodexFetchResult = CodexClient.fetch
    ) {
        self.defaults = defaults
        self.fetchUsage = fetchUsage
        accountEpochStartedAt = defaults.object(
            forKey: Self.historyAccountEpochStartedAtKey
        ) as? Date
        if defaults.data(forKey: Self.historySyncBookmarkKey) != nil {
            defaults.set(true, forKey: Self.historySyncSelectedKey)
        }
        if let data = defaults.data(forKey: Self.stateKey),
           let state = try? JSONDecoder().decode(StoredState.self, from: data) {
            accountSnapshot = state.snapshot
            samples = state.samples
            legacySamplesAwaitingMigration = state.samples
            previousStatus = state.previousStatus
        }

        let installationID: String
        if let existing = defaults.string(forKey: Self.historyInstallationIDKey),
           let uuid = UUID(uuidString: existing) {
            installationID = uuid.uuidString.lowercased()
        } else {
            installationID = UUID().uuidString.lowercased()
            defaults.set(installationID, forKey: Self.historyInstallationIDKey)
        }
        let historyPartition = Self.historyPartition(in: defaults)
        self.historyPartition = historyPartition
        history = UsageHistory(
            localDirectory: historyDirectory ?? Self.historyDirectory(),
            installationID: installationID,
            partition: historyPartition
        )
        recalculate()

        if startsAutomatically {
            Task { [weak self] in
                await self?.start()
            }
        }
    }

    func start() async {
        guard !started else { return }
        started = true

        Timer.publish(every: 600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            .store(in: &cancellables)

        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await restoreHistoryIfAvailable()
        let fetchTask = Task { try await fetchUsage() }

        do {
            let result = try await fetchTask.value
            guard let account = result.account else {
                historyMatchesCurrentSnapshot = false
                await exchangeRestoredHistoryIfAvailable()
                accountSnapshot = result.snapshot
                sourceState = .available
                recalculate(now: result.snapshot.fetchedAt)
                persist()
                return
            }
            let legacySamples = legacySamplesAwaitingMigration
            accountWasObserved = true
            historyMatchesCurrentSnapshot = true
            await selectHistoryAccount(
                account,
                observedAt: result.snapshot.fetchedAt
            )
            await prepareHistory(legacySamples: legacySamples)
            if !historyUsesFiles {
                let historyState = await history.load(legacySamples: samples)
                apply(historyState)
                historyUsesFiles = historyState.errorMessage == nil
            }
            let historyState = await exchangeHistory()
            apply(historyState, configuredFolderName: configuredSyncDirectory?.lastPathComponent)
            let exchangeErrorMessage = historyState.errorMessage
            let newSnapshot = result.snapshot
            if let window = newSnapshot.mainLimit?.window {
                let sample = UsageSample(
                    observedAt: newSnapshot.fetchedAt,
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt,
                    lifetimeTokens: freshLifetimeTokens(in: newSnapshot)
                )
                let recordedState = await history.record(sample)
                apply(
                    recordedState,
                    configuredFolderName: configuredSyncDirectory?.lastPathComponent
                )
                if recordedState.errorMessage == nil {
                    syncErrorMessage = exchangeErrorMessage
                }
            } else {
                syncErrorMessage = exchangeErrorMessage
            }
            accountSnapshot = newSnapshot
            sourceState = .available
            recalculate(now: newSnapshot.fetchedAt)
            persist()
        } catch let error as CodexClientError {
            await exchangeRestoredHistoryIfAvailable()
            sourceState = .failed(error.localizedDescription)
            recalculate()
            persist()
        } catch {
            await exchangeRestoredHistoryIfAvailable()
            sourceState = .failed("Couldn’t read Codex usage. Try refreshing again.")
            recalculate()
            persist()
        }
    }

    func updateSafetyBuffer(_ value: Double) {
        recalculate(safetyBuffer: value)
        persist()
    }

    func connectHistoryFolder(_ directory: URL) async {
        await restoreHistoryIfAvailable()
        if historyDeletionStatus == .pendingSync {
            _ = await ensureAccountObserved()
        } else {
            guard await ensureAccountObserved() else { return }
        }
        await prepareHistory()
        let bookmark: Data
        do {
            bookmark = try directory.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            syncErrorMessage = "Couldn’t remember the history folder. Choose it again."
            return
        }
        let state = await history.connect(
            to: directory,
            accountIdentity: historyAccountIdentity,
            accountBindingToken: defaults.string(
                forKey: Self.historySyncAccountBindingKey
            ),
            bindsUnresolvedDeletionTarget: historyDeletionStatus == .pendingSync
        )
        apply(state)
        historyConnectionActive = await history.isConnected(to: directory)
        if !historyConnectionActive,
           state.deletionStatus == .complete,
           historyAccountIdentity == nil {
            defaults.removeObject(forKey: Self.historySyncBookmarkKey)
            defaults.removeObject(forKey: Self.historySyncAccountBindingKey)
            defaults.set(false, forKey: Self.historySyncSelectedKey)
            configuredSyncDirectory = nil
            syncFolderName = nil
            syncErrorMessage = "History was deleted. Codex account details are unavailable, so history sync is off."
        }
        guard historyConnectionActive else { return }

        defaults.set(bookmark, forKey: Self.historySyncBookmarkKey)
        defaults.set(true, forKey: Self.historySyncSelectedKey)
        if let token = await history.accountBindingToken() {
            defaults.set(token, forKey: Self.historySyncAccountBindingKey)
        } else {
            defaults.removeObject(forKey: Self.historySyncAccountBindingKey)
        }
        configuredSyncDirectory = directory
        syncFolderName = directory.lastPathComponent
    }

    func stopHistorySync() async {
        defaults.removeObject(forKey: Self.historySyncBookmarkKey)
        defaults.removeObject(forKey: Self.historySyncAccountBindingKey)
        defaults.set(false, forKey: Self.historySyncSelectedKey)
        configuredSyncDirectory = nil
        historyConnectionActive = false
        apply(await history.disconnect())
    }

    private func selectHistoryAccount(
        _ observation: CodexAccountObservation,
        observedAt: Date
    ) async {
        let partition: AccountHistoryPartition
        let authState: String
        let previousAuthState = defaults.string(forKey: Self.historyAuthStateKey)
        switch observation {
        case let .stable(identity):
            historyAccountIdentity = identity
            partition = .stable(
                identity: identity,
                key: Self.fingerprintKey(in: defaults)
            )
            authState = "stable:\(partition.id)"
        case let .unknown(state):
            historyAccountIdentity = nil
            authState = "unknown:\(state)"
            if previousAuthState == authState,
               historyPartition.id.hasPrefix("unknown-") {
                partition = historyPartition
            } else {
                partition = .unknown(transitionID: UUID())
            }
        }
        if previousAuthState != authState || accountEpochStartedAt == nil {
            accountEpochStartedAt = observedAt
            defaults.set(
                observedAt,
                forKey: Self.historyAccountEpochStartedAtKey
            )
        }
        defaults.set(authState, forKey: Self.historyAuthStateKey)
        guard partition != historyPartition else { return }
        historyPartition = partition
        historyConnectionActive = false
        if let data = try? JSONEncoder().encode(partition) {
            defaults.set(data, forKey: Self.historyPartitionKey)
        }
        if previousAuthState != nil,
           historyDeletionStatus != .pendingSync {
            defaults.removeObject(forKey: Self.historySyncBookmarkKey)
            defaults.removeObject(forKey: Self.historySyncAccountBindingKey)
            defaults.set(false, forKey: Self.historySyncSelectedKey)
            configuredSyncDirectory = nil
            historyConnectionActive = false
        }
        apply(await history.selectPartition(partition))
        recalculate()
        if historyPrepared {
            persist()
        }
    }

    func deleteAnalyticsHistory() async {
        guard !isUpdatingHistory else { return }
        isUpdatingHistory = true
        defer { isUpdatingHistory = false }
        await prepareHistory()
        apply(await history.deleteAnalyticsHistory(
            syncTarget: configuredSyncDirectory,
            expectsSyncTarget: defaults.bool(forKey: Self.historySyncSelectedKey)
        ))
        previousStatus = nil
        if let snapshot = accountSnapshot {
            accountSnapshot = UsageSnapshot(
                mainLimit: snapshot.mainLimit,
                otherLimits: snapshot.otherLimits,
                tokenHistory: [],
                emergencyResetCount: snapshot.emergencyResetCount,
                fetchedAt: snapshot.fetchedAt,
                accountFacts: snapshot.accountFacts
            )
        }
        recalculate()
        persist()
    }

    func retryHistoryDeletion() async {
        guard !isUpdatingHistory else { return }
        isUpdatingHistory = true
        defer { isUpdatingHistory = false }
        let bookmarkedTarget = resolveHistoryBookmark()
        if configuredSyncDirectory == nil {
            configuredSyncDirectory = bookmarkedTarget
        }
        let bindsUnresolvedTarget = bookmarkedTarget?.standardizedFileURL
            == configuredSyncDirectory?.standardizedFileURL
        var state = await history.retryPendingDeletion(
            syncTarget: configuredSyncDirectory,
            bindsUnresolvedDeletionTarget: bindsUnresolvedTarget
        )
        if state.deletionStatus == .complete,
           let configuredSyncDirectory {
            state = await history.connect(
                to: configuredSyncDirectory,
                accountIdentity: historyAccountIdentity,
                accountBindingToken: defaults.string(
                    forKey: Self.historySyncAccountBindingKey
                )
            )
        }
        if state.deletionStatus == .complete,
           state.issue == .wrongAccount {
            defaults.removeObject(forKey: Self.historySyncBookmarkKey)
            defaults.removeObject(forKey: Self.historySyncAccountBindingKey)
            defaults.set(false, forKey: Self.historySyncSelectedKey)
            configuredSyncDirectory = nil
        }
        apply(
            state,
            configuredFolderName: state.deletionStatus == .pendingSync
                ? configuredSyncDirectory?.lastPathComponent
                : nil
        )
        historyConnectionActive = if let configuredSyncDirectory {
            await history.isConnected(to: configuredSyncDirectory)
        } else {
            false
        }
        recalculate()
        persist()
    }

    var canRebuildAvailableHistory: Bool {
        accountSnapshot?.mainLimit != nil
            && historyDeletionStatus != .pendingSync
    }

    func rebuildAvailableHistory() async {
        guard !isUpdatingHistory, canRebuildAvailableHistory else { return }
        isUpdatingHistory = true
        defer { isUpdatingHistory = false }
        do {
            let result = try await fetchUsage()
            guard let account = result.account else {
                throw CodexClientError.invalidResponse
            }
            accountWasObserved = true
            historyMatchesCurrentSnapshot = true
            await selectHistoryAccount(
                account,
                observedAt: result.snapshot.fetchedAt
            )
            let snapshot = result.snapshot
            if let window = snapshot.mainLimit?.window {
                let sample = UsageSample(
                    observedAt: snapshot.fetchedAt,
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt,
                    lifetimeTokens: freshLifetimeTokens(in: snapshot)
                )
                apply(await history.rebuildAvailableHistory([sample]))
            }
            accountSnapshot = snapshot
            sourceState = .available
            recalculate(now: snapshot.fetchedAt)
            persist()
        } catch let error as CodexClientError {
            sourceState = .failed(error.localizedDescription)
            recalculate()
            persist()
        } catch {
            sourceState = .failed("Couldn’t read Codex usage. Try again.")
            recalculate()
            persist()
        }
    }

    private func recalculate(
        safetyBuffer: Double? = nil,
        now: Date = Date()
    ) {
        let storedBuffer = defaults.object(forKey: Self.safetyBufferKey) as? Double
        let buffer = safetyBuffer ?? storedBuffer ?? 3
        readerSnapshot = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: accountSnapshot,
                samples: historyMatchesCurrentSnapshot ? samples : [],
                safetyBuffer: buffer,
                sourceState: sourceState,
                now: now,
                previousStatus: previousStatus,
                accountEpochStartedAt: accountEpochStartedAt
            )
        )
        if let status = readerSnapshot.guidance?.status {
            previousStatus = status
        }
    }

    private func freshLifetimeTokens(in snapshot: UsageSnapshot) -> Int64? {
        guard let facts = snapshot.accountFacts,
              facts.lifetimeTokensObservedAt == snapshot.fetchedAt else {
            return nil
        }
        return facts.lifetimeTokens
    }

    private func persist() {
        let state = StoredState(
            snapshot: accountSnapshot,
            samples: historyUsesFiles ? [] : samples,
            previousStatus: previousStatus
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }

    private func prepareHistory(legacySamples: [UsageSample]? = nil) async {
        guard !historyPrepared else { return }
        historyPrepared = true

        let state = await history.load(legacySamples: legacySamples ?? samples)
        apply(state)
        historyUsesFiles = state.errorMessage == nil
        if historyUsesFiles {
            legacySamplesAwaitingMigration = []
            persist()
        }

        guard let bookmark = defaults.data(forKey: Self.historySyncBookmarkKey) else {
            return
        }
        let directory: URL
        var isStale = false
        do {
            directory = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            syncErrorMessage = "Couldn’t reopen the history folder. Choose it again."
            return
        }

        configuredSyncDirectory = directory
        let connectedState = await history.connect(
            to: directory,
            accountIdentity: historyAccountIdentity,
            accountBindingToken: defaults.string(
                forKey: Self.historySyncAccountBindingKey
            ),
            bindsUnresolvedDeletionTarget: true
        )
        historyConnectionActive = connectedState.folderName != nil
        apply(connectedState, configuredFolderName: directory.lastPathComponent)
        if historyConnectionActive,
           let token = await history.accountBindingToken() {
            defaults.set(token, forKey: Self.historySyncAccountBindingKey)
        } else if historyConnectionActive {
            defaults.removeObject(forKey: Self.historySyncAccountBindingKey)
        }
        if isStale, historyConnectionActive {
            do {
                let refreshed = try directory.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                defaults.set(refreshed, forKey: Self.historySyncBookmarkKey)
            } catch {
                syncErrorMessage = "Couldn’t update the saved history folder."
            }
        }
    }

    private func restoreHistoryIfAvailable() async {
        guard !historyWasRestored else { return }
        historyWasRestored = true
        guard let state = await history.restoreExistingState() else { return }
        restoredFileStoreAvailable = true
        legacySamplesAwaitingMigration = []
        apply(state)
        historyUsesFiles = state.errorMessage == nil
    }

    private func ensureAccountObserved() async -> Bool {
        guard !accountWasObserved else { return true }
        do {
            let result = try await fetchUsage()
            guard let account = result.account else {
                syncErrorMessage = "Couldn’t verify the Codex account. Try again."
                return false
            }
            accountWasObserved = true
            historyMatchesCurrentSnapshot = true
            await selectHistoryAccount(
                account,
                observedAt: result.snapshot.fetchedAt
            )
            guard historyAccountIdentity != nil else {
                syncErrorMessage = "Codex account details are unavailable, so history sync is off."
                return false
            }
            return true
        } catch {
            syncErrorMessage = "Couldn’t verify the Codex account. Try again."
            return false
        }
    }

    private func exchangeHistory() async -> UsageHistory.State {
        if let configuredSyncDirectory {
            let state = await history.connect(
                to: configuredSyncDirectory,
                accountIdentity: historyAccountIdentity,
                accountBindingToken: defaults.string(
                    forKey: Self.historySyncAccountBindingKey
                )
            )
            historyConnectionActive = state.folderName != nil
            return state
        }
        return await history.synchronize()
    }

    private func exchangeRestoredHistoryIfAvailable() async {
        guard restoredFileStoreAvailable else { return }
        await prepareHistory(legacySamples: [])
        let state = await exchangeHistory()
        apply(state, configuredFolderName: configuredSyncDirectory?.lastPathComponent)
    }

    private func apply(
        _ state: UsageHistory.State,
        configuredFolderName: String? = nil
    ) {
        samples = state.samples
        syncFolderName = state.folderName ?? configuredFolderName
        syncErrorMessage = state.errorMessage
        historyDeletionStatus = state.deletionStatus
    }

    private static func historyDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.github.thrr87.CodexLimits", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    private func resolveHistoryBookmark() -> URL? {
        guard let bookmark = defaults.data(forKey: Self.historySyncBookmarkKey) else {
            return nil
        }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private static func historyPartition(in defaults: UserDefaults) -> AccountHistoryPartition {
        if let data = defaults.data(forKey: historyPartitionKey),
           let partition = try? JSONDecoder().decode(
               AccountHistoryPartition.self,
               from: data
           ) {
            return partition
        }
        let partition = AccountHistoryPartition.unknown(transitionID: UUID())
        if let data = try? JSONEncoder().encode(partition) {
            defaults.set(data, forKey: historyPartitionKey)
        }
        return partition
    }

    private static func fingerprintKey(in defaults: UserDefaults) -> Data {
        if let key = defaults.data(forKey: historyFingerprintKey), key.count == 32 {
            return key
        }
        var generator = SystemRandomNumberGenerator()
        let key = Data((0 ..< 32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
        defaults.set(key, forKey: historyFingerprintKey)
        return key
    }
}

private struct StoredState: Codable {
    let snapshot: UsageSnapshot?
    let samples: [UsageSample]
    let previousStatus: PaceStatus?
}
