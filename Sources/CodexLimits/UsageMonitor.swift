import AppKit
import Combine
import Foundation

enum IntegrationWorkPriority: Int, Sendable {
    case explicit
    case visible
    case automatic
    case settings
}

actor IntegrationWorkCoordinator {
    private struct Waiter {
        let priority: IntegrationWorkPriority
        let order: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private var isAvailable = true
    private var nextOrder: UInt64 = 0
    private var waiters: [Waiter] = []

    func run(
        priority: IntegrationWorkPriority,
        operation: @Sendable () async -> Void
    ) async {
        await enter(priority: priority)
        if !Task.isCancelled {
            await operation()
        }
        leave()
    }

    private func enter(priority: IntegrationWorkPriority) async {
        if isAvailable {
            isAvailable = false
            return
        }
        let order = nextOrder
        nextOrder &+= 1
        // ponytail: cancelled waiters drain without source work; add waiter IDs
        // only if bounded-operation metrics show meaningful queue churn.
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(
                priority: priority,
                order: order,
                continuation: continuation
            ))
        }
    }

    private func leave() {
        guard let index = waiters.indices.min(by: {
            let lhs = waiters[$0]
            let rhs = waiters[$1]
            return (lhs.priority.rawValue, lhs.order)
                < (rhs.priority.rawValue, rhs.order)
        }) else {
            isAvailable = true
            return
        }
        waiters.remove(at: index).continuation.resume()
    }
}

enum SafetyBufferPolicy {
    static let defaultValue = 3.0
    static let range = 1.0 ... 10.0

    static func normalized(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

@MainActor
final class UsageMonitor: ObservableObject {
    private struct AccountRefreshRequest: Equatable {
        let generation: UInt64
        let priority: IntegrationWorkPriority
    }

    private static let accountRefreshInterval: TimeInterval = 600
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
    @Published private(set) var isEnabled: Bool
    @Published private(set) var historicalReaderSnapshot: UsageReaderSnapshot?
    @Published private(set) var historicalRange: DateInterval?
    @Published private(set) var historicalRetainedBounds: DateInterval?
    @Published private(set) var historicalRangeIssue: String?
    @Published private(set) var isLoadingHistoricalRange = false
    @Published private(set) var syncFolderName: String?
    @Published private(set) var syncErrorMessage: String?
    @Published private(set) var historyDeletionStatus: UsageHistory.DeletionStatus = .none
    @Published private(set) var isUpdatingHistory = false
    @Published private(set) var resetReminderState: ResetReminderState

    private static let stateKey = "usageState"
    private static let historyInstallationIDKey = "historyInstallationID"
    private static let historySyncBookmarkKey = "historySyncBookmark"
    private static let historyPartitionKey = "historyAccountPartition"
    private static let historyFingerprintKey = "historyAccountFingerprintKey"
    private static let historyAuthStateKey = "historyAccountState"
    private static let historyPlanTypeKey = "historyAccountPlanType"
    private static let historyAccountEpochStartedAtKey = "historyAccountEpochStartedAt"
    private static let historyAccountEpochMigrationVersionKey =
        "historyAccountEpochMigrationVersion"
    private static let historySyncSelectedKey = "historySyncSelected"
    private static let historySyncAccountBindingKey = "historySyncAccountBinding"
    private static let localHistoryDeletionCutoffKey =
        "localHistoryDeletionCutoff"
    private let defaults: UserDefaults
    private let history: UsageHistory
    private let codexAssistedHistory: CodexAssistedHistory?
    private let fetchUsage: () async throws -> CodexFetchResult
    private let cancelFetchUsage: @Sendable () async -> Void
    private let evaluateUsage:
        @Sendable (UsageIntelligenceInput) -> UsageReaderSnapshot
    private let localActivityCollector: LocalActivityCollector?
    private let resetReminderCoordinator: ResetReminderCoordinator
    private let integrationWorkCoordinator: IntegrationWorkCoordinator
    private var historyPartition: AccountHistoryPartition
    private var accountSnapshot: UsageSnapshot?
    private var sourceState: UsageSourceState = .available
    private var previousStatus: PaceStatus?
    private var cancellables: Set<AnyCancellable> = []
    private var accountRefreshCancellable: AnyCancellable?
    private var accountFetchTask: Task<CodexFetchResult, Error>?
    private var accountCollectionGeneration: UInt64 = 0
    private var accountRefreshRequest: AccountRefreshRequest?
    private var menuBarSourceActive: Bool
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
    private var localActivityCollection = LocalActivityCollection.unavailable(
        "Codex local records are unavailable"
    )
    private var evaluationGeneration: UInt64 = 0
    private var evaluationTask: Task<UsageReaderSnapshot?, Never>?
    private var readerBoundaryTask: Task<Void, Never>?
    private var historicalRangeGeneration: UInt64 = 0
    private var historicalRangeTask: Task<Void, Never>?
    private var localImportGeneration: UInt64 = 0
    private var localImportTask: Task<Void, Never>?
    private var localAnalyticsVisible = false
    private var localAnalyticsNeedsLoad = false
    private var visible = false

    convenience init(
        isEnabled: Bool = true,
        menuBarSourceActive: Bool = true,
        integrationWorkCoordinator: IntegrationWorkCoordinator =
            IntegrationWorkCoordinator()
    ) {
        self.init(
            defaults: .standard,
            isEnabled: isEnabled,
            menuBarSourceActive: menuBarSourceActive,
            localActivityCollector: LocalActivityCollector(
                projectionSource: ReadOnlyThreadProjectionSource { request in
                    try await CodexClient.shared.threadProjectionResponse(
                        for: request
                    )
                },
                installedCLIVersion: {
                    try? await CodexClient.shared.installedCLIVersion()
                }
            ),
            codexAssistedHistory: CodexAssistedHistory.shared,
            integrationWorkCoordinator: integrationWorkCoordinator
        )
    }

    init(
        defaults: UserDefaults,
        historyDirectory: URL? = nil,
        startsAutomatically: Bool = true,
        isEnabled: Bool = true,
        menuBarSourceActive: Bool = true,
        localActivityCollector: LocalActivityCollector? = nil,
        resetReminderScheduler: (any ResetReminderScheduling)? = nil,
        resetReminderNow: @escaping () -> Date = Date.init,
        codexAssistedHistory: CodexAssistedHistory? = nil,
        integrationWorkCoordinator: IntegrationWorkCoordinator =
            IntegrationWorkCoordinator(),
        fetchUsage: @escaping () async throws -> CodexFetchResult = CodexClient.fetch,
        cancelFetchUsage: @escaping @Sendable () async -> Void =
            { await CodexClient.cancelFetch() },
        evaluateUsage: @escaping @Sendable (
            UsageIntelligenceInput
        ) -> UsageReaderSnapshot = {
            UsageIntelligenceEngine.evaluate($0)
        }
    ) {
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.menuBarSourceActive = menuBarSourceActive
        self.fetchUsage = fetchUsage
        self.cancelFetchUsage = cancelFetchUsage
        self.evaluateUsage = evaluateUsage
        self.localActivityCollector = localActivityCollector
        self.codexAssistedHistory = codexAssistedHistory
        self.integrationWorkCoordinator = integrationWorkCoordinator
        let storedSafetyBuffer = defaults.object(
            forKey: Self.safetyBufferKey
        ) as? Double
        let safetyBuffer = SafetyBufferPolicy.normalized(storedSafetyBuffer)
        if storedSafetyBuffer != safetyBuffer {
            defaults.set(safetyBuffer, forKey: Self.safetyBufferKey)
        }
        let resetReminderCoordinator = ResetReminderCoordinator(
            defaults: defaults,
            scheduler: resetReminderScheduler
                ?? UserNotificationResetReminderScheduler(),
            now: resetReminderNow
        )
        self.resetReminderCoordinator = resetReminderCoordinator
        resetReminderState = resetReminderCoordinator.state
        accountEpochStartedAt = defaults.object(
            forKey: Self.historyAccountEpochStartedAtKey
        ) as? Date
        if defaults.data(forKey: Self.historySyncBookmarkKey) != nil {
            defaults.set(true, forKey: Self.historySyncSelectedKey)
        }
        if let data = defaults.data(forKey: Self.stateKey),
           let state = try? JSONDecoder().decode(StoredState.self, from: data) {
            let restoredSamples = state.samples.filter(
                \.hasValidObservationMetadata
            )
            accountSnapshot = state.snapshot.flatMap {
                $0.isValid ? $0 : nil
            }
            samples = restoredSamples
            legacySamplesAwaitingMigration = restoredSamples
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
        if defaults.object(forKey: Self.localHistoryDeletionCutoffKey) != nil {
            historyDeletionStatus = .pendingLocal
        }
        if accountSnapshot != nil || !samples.isEmpty {
            let pending = beginRecalculation()
            Task { [weak self] in
                guard let self else { return }
                _ = await finishRecalculation(pending)
            }
        }

        if startsAutomatically {
            Task { [weak self] in
                await self?.start()
            }
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        await resetReminderCoordinator.restore()
        if !isEnabled {
            await resetReminderCoordinator.reconcile(target: nil)
        }
        publishResetReminderState()
        if isEnabled, let cutoff = defaults.object(
            forKey: Self.localHistoryDeletionCutoffKey
        ) as? Date {
            await localActivityCollector?.restorePendingHistoryDeletion(
                at: cutoff
            )
        }

        startAccountRefreshTimerIfNeeded()

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task {
                    @MainActor in
                    await self?.refreshSelectedMenuBarSourceIfStale()
                }
            }
            .store(in: &cancellables)

        await refreshSelectedMenuBarSourceIfStale()
    }

    func automaticRefresh() async {
        guard isEnabled, menuBarSourceActive else { return }
        await refresh(
            forceHistorySync: false,
            includeLocalActivity: false,
            priority: .automatic
        )
    }

    func refreshAccountIfStale(
        now: Date = Date(),
        priority: IntegrationWorkPriority = .visible
    ) async {
        guard isEnabled else { return }
        guard let fetchedAt = accountSnapshot?.fetchedAt,
              now.timeIntervalSince(fetchedAt)
                < Self.accountRefreshInterval else {
            await refresh(
                forceHistorySync: false,
                includeLocalActivity: false,
                priority: priority
            )
            return
        }
    }

    func refresh(
        forceHistorySync: Bool = true,
        includeLocalActivity: Bool = true
    ) async {
        await refresh(
            forceHistorySync: forceHistorySync,
            includeLocalActivity: includeLocalActivity,
            priority: .explicit
        )
    }

    private func refresh(
        forceHistorySync: Bool,
        includeLocalActivity: Bool,
        priority: IntegrationWorkPriority
    ) async {
        guard isEnabled else { return }
        if let current = accountRefreshRequest {
            guard priority.rawValue < current.priority.rawValue else { return }
            accountFetchTask?.cancel()
            await cancelFetchUsage()
        }
        accountCollectionGeneration &+= 1
        let request = AccountRefreshRequest(
            generation: accountCollectionGeneration,
            priority: priority
        )
        accountRefreshRequest = request
        isRefreshing = true
        await integrationWorkCoordinator.run(priority: priority) {
            @MainActor [weak self] in
            guard let self, self.isEnabled,
                  self.accountRefreshRequest == request else {
                return
            }
            await self.performRefresh(
                forceHistorySync: forceHistorySync,
                includeLocalActivity: includeLocalActivity,
                generation: request.generation
            )
        }
        if accountRefreshRequest == request {
            accountRefreshRequest = nil
            isRefreshing = false
        }
    }

    private func performRefresh(
        forceHistorySync: Bool,
        includeLocalActivity: Bool,
        generation: UInt64
    ) async {
        defer {
            if generation == accountCollectionGeneration {
                accountFetchTask = nil
            }
        }
        if includeLocalActivity {
            cancelLocalImport()
        }

        await restoreHistoryIfAvailable()
        let fetchTask = Task { try await fetchUsage() }
        accountFetchTask = fetchTask

        do {
            let result = try await fetchTask.value
            guard canPublishAccountWork(generation) else { return }
            guard let account = result.account else {
                historyMatchesCurrentSnapshot = false
                await exchangeRestoredHistoryIfAvailable(
                    force: forceHistorySync
                )
                guard canPublishAccountWork(generation) else { return }
                accountSnapshot = result.snapshot
                sourceState = .available
                if localAnalyticsVisible,
                   includeLocalActivity || localAnalyticsNeedsLoad {
                    await refreshLocalActivity(
                        for: result.snapshot,
                        observedAt: result.snapshot.fetchedAt,
                        identityVerified: false
                    )
                    guard canPublishAccountWork(generation) else { return }
                }
                let published = await recalculate(
                    now: result.snapshot.fetchedAt
                )
                persist()
                if published {
                    await reconcileResetReminder()
                }
                return
            }
            let legacySamples = legacySamplesAwaitingMigration
            accountWasObserved = true
            historyMatchesCurrentSnapshot = true
            await selectHistoryAccount(
                account,
                planType: result.planType,
                observedAt: result.snapshot.fetchedAt
            )
            guard canPublishAccountWork(generation) else { return }
            await prepareHistory(legacySamples: legacySamples)
            guard canPublishAccountWork(generation) else { return }
            if !historyUsesFiles {
                let historyState = await history.load(legacySamples: samples)
                guard canPublishAccountWork(generation) else { return }
                apply(historyState)
                historyUsesFiles = historyState.errorMessage == nil
            }
            let historyState = await exchangeHistory(force: forceHistorySync)
            guard canPublishAccountWork(generation) else { return }
            apply(historyState, configuredFolderName: configuredSyncDirectory?.lastPathComponent)
            repairInitialAccountEpochIfNeeded()
            let exchangeErrorMessage = historyState.errorMessage
            let newSnapshot = result.snapshot
            if let window = newSnapshot.mainLimit?.window {
                let sample = UsageSample(
                    observedAt: newSnapshot.fetchedAt,
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt,
                    lifetimeTokens: freshLifetimeTokens(in: newSnapshot),
                    comparisonBreak:
                        accountEpochStartedAt == newSnapshot.fetchedAt
                )
                let recordedState = await history.record(sample)
                guard canPublishAccountWork(generation) else { return }
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
            if localAnalyticsVisible,
               includeLocalActivity || localAnalyticsNeedsLoad {
                await refreshLocalActivity(
                    for: newSnapshot,
                    observedAt: newSnapshot.fetchedAt
                )
                guard canPublishAccountWork(generation) else { return }
            }
            let published = await recalculate(now: newSnapshot.fetchedAt)
            persist()
            if published {
                await reconcileResetReminder()
            }
        } catch {
            guard canPublishAccountWork(generation) else { return }
            await exchangeRestoredHistoryIfAvailable(
                force: forceHistorySync
            )
            guard canPublishAccountWork(generation) else { return }
            sourceState = .failed(
                (error as? CodexClientError)?.localizedDescription
                    ?? "Couldn’t read Codex usage. Try refreshing again."
            )
            if localAnalyticsVisible,
               includeLocalActivity || localAnalyticsNeedsLoad,
               let accountSnapshot {
                await refreshLocalActivity(
                    for: accountSnapshot,
                    observedAt: Date(),
                    identityVerified: false
                )
                guard canPublishAccountWork(generation) else { return }
            }
            _ = await recalculate()
            persist()
        }
    }

    func setLocalAnalyticsVisible(_ isVisible: Bool) async {
        if isVisible {
            guard isEnabled else { return }
            if !localAnalyticsVisible {
                localAnalyticsVisible = true
                localAnalyticsNeedsLoad = true
            }
            guard localAnalyticsNeedsLoad else { return }
        } else {
            guard localAnalyticsVisible || localAnalyticsNeedsLoad else {
                return
            }
            localAnalyticsVisible = false
            localAnalyticsNeedsLoad = false
            cancelLocalImport()
            localActivityCollection = .unavailable(
                "Codex local records are unavailable"
            )
            await localActivityCollector?.releaseCachedFacts()
            _ = await recalculate()
            return
        }
        while isRefreshing {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard localAnalyticsVisible,
              localAnalyticsNeedsLoad,
              accountSnapshot != nil else {
            return
        }
        await integrationWorkCoordinator.run(priority: .visible) {
            @MainActor [weak self] in
            guard let self,
                  self.isEnabled,
                  self.localAnalyticsVisible,
                  self.localAnalyticsNeedsLoad,
                  let accountSnapshot = self.accountSnapshot else {
                return
            }
            let identityVerified = self.sourceState == .available
                && self.historyAccountIdentity != nil
            await self.refreshLocalActivity(
                for: accountSnapshot,
                observedAt: identityVerified
                    ? accountSnapshot.fetchedAt
                    : Date(),
                identityVerified: identityVerified
            )
            _ = await self.recalculate()
        }
    }

    func setVisible(_ visible: Bool) async {
        guard visible != self.visible else { return }
        self.visible = visible
        scheduleReaderBoundary()
        if !visible, !menuBarSourceActive {
            await cancelAccountCollection()
        }
        if !visible {
            clearHistoricalRange()
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        accountCollectionGeneration &+= 1
        accountFetchTask?.cancel()
        accountFetchTask = nil
        accountRefreshRequest = nil
        isRefreshing = false

        if enabled {
            startAccountRefreshTimerIfNeeded()
            scheduleReaderBoundary()
            while isRefreshing {
                guard !Task.isCancelled else { return }
                await Task.yield()
            }
            await refreshSelectedMenuBarSourceIfStale()
            return
        }

        accountRefreshCancellable?.cancel()
        accountRefreshCancellable = nil
        await cancelFetchUsage()
        readerBoundaryTask?.cancel()
        readerBoundaryTask = nil
        clearHistoricalRange()
        cancelLocalImport()
        evaluationGeneration &+= 1
        evaluationTask?.cancel()
        evaluationTask = nil
        localAnalyticsVisible = false
        localAnalyticsNeedsLoad = false
        localActivityCollection = .unavailable(
            "Codex local records are unavailable"
        )
        await localActivityCollector?.releaseCachedFacts()
        _ = await history.disconnect()
        await resetReminderCoordinator.reconcile(target: nil)
        publishResetReminderState()
    }

    func setMenuBarSourceActive(_ active: Bool) async {
        guard active != menuBarSourceActive else { return }
        menuBarSourceActive = active
        if !active {
            accountRefreshCancellable?.cancel()
            accountRefreshCancellable = nil
            scheduleReaderBoundary()
            if !visible {
                await cancelAccountCollection()
            }
            return
        }
        guard isEnabled else { return }
        scheduleReaderBoundary()
        startAccountRefreshTimerIfNeeded()
        await refreshAccountIfStale(priority: .automatic)
    }

    private func refreshSelectedMenuBarSourceIfStale() async {
        guard menuBarSourceActive else { return }
        await refreshAccountIfStale(priority: .automatic)
    }

    private func startAccountRefreshTimerIfNeeded() {
        guard started, isEnabled, menuBarSourceActive,
              accountRefreshCancellable == nil else {
            return
        }
        accountRefreshCancellable = Timer.publish(
            every: Self.accountRefreshInterval,
            on: .main,
            in: .common
        )
            .autoconnect()
            .sink { [weak self] _ in
                Task {
                    @MainActor in await self?.automaticRefresh()
                }
            }
    }

    private func canPublishAccountWork(_ generation: UInt64) -> Bool {
        isEnabled
            && generation == accountCollectionGeneration
            && !Task.isCancelled
    }

    private func cancelAccountCollection() async {
        accountCollectionGeneration &+= 1
        accountFetchTask?.cancel()
        accountFetchTask = nil
        accountRefreshRequest = nil
        isRefreshing = false
        await cancelFetchUsage()
    }

    var canLoadEarlierHistory: Bool {
        guard !samples.isEmpty else { return false }
        guard let historicalRange,
              let retained = historicalRetainedBounds else {
            return true
        }
        return retained.start < historicalRange.start
    }

    func loadEarlierHistory(
        exploration: AnalyticsExplorationState,
        dispositions: [String: InsightDisposition]
    ) async {
        guard let end = historicalRange?.start
            ?? samples.first?.observedAt else { return }
        await loadHistoricalRange(
            DateInterval(
                start: end.addingTimeInterval(-84 * 86_400),
                end: end
            ),
            exploration: exploration,
            dispositions: dispositions
        )
    }

    func loadLaterHistory(
        exploration: AnalyticsExplorationState,
        dispositions: [String: InsightDisposition]
    ) async {
        guard let historicalRange else { return }
        guard let latestStart = samples.first?.observedAt,
              historicalRange.end < latestStart else {
            clearHistoricalRange()
            return
        }
        let end = min(
            historicalRange.end.addingTimeInterval(84 * 86_400),
            latestStart
        )
        await loadHistoricalRange(
            DateInterval(
                start: end.addingTimeInterval(-84 * 86_400),
                end: end
            ),
            exploration: exploration,
            dispositions: dispositions
        )
    }

    func clearHistoricalRange() {
        historicalRangeGeneration &+= 1
        historicalRangeTask?.cancel()
        historicalRangeTask = nil
        historicalReaderSnapshot = nil
        historicalRange = nil
        historicalRetainedBounds = nil
        historicalRangeIssue = nil
        isLoadingHistoricalRange = false
    }

    private func loadHistoricalRange(
        _ interval: DateInterval,
        exploration: AnalyticsExplorationState,
        dispositions: [String: InsightDisposition]
    ) async {
        guard isEnabled, visible else { return }
        historicalRangeGeneration &+= 1
        let generation = historicalRangeGeneration
        historicalRangeTask?.cancel()
        isLoadingHistoricalRange = true
        historicalRangeIssue = nil
        var rangeExploration = exploration
        rangeExploration.timeRange = .selected
        rangeExploration.visibleRange = interval
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performHistoricalRangeLoad(
                interval,
                exploration: rangeExploration,
                dispositions: dispositions,
                generation: generation
            )
        }
        historicalRangeTask = task
        await task.value
        if historicalRangeGeneration == generation {
            historicalRangeTask = nil
            isLoadingHistoricalRange = false
        }
    }

    private func performHistoricalRangeLoad(
        _ interval: DateInterval,
        exploration: AnalyticsExplorationState,
        dispositions: [String: InsightDisposition],
        generation: UInt64
    ) async {
        await integrationWorkCoordinator.run(priority: .visible) {
            @MainActor [weak self] in
            guard let self, self.isEnabled, self.visible,
                  self.historicalRangeGeneration == generation,
                  !Task.isCancelled,
                  let view = await self.history.rangeView(for: interval) else {
                return
            }
            let input = self.evaluationInput(
                analyticsExploration: exploration,
                insightDispositions: dispositions,
                historySamples: view.samples
            )
            let evaluateUsage = self.evaluateUsage
            let evaluation = Task.detached(priority: .userInitiated) {
                Task.isCancelled ? nil : evaluateUsage(input)
            }
            let snapshot = await withTaskCancellationHandler {
                await evaluation.value
            } onCancel: {
                evaluation.cancel()
            }
            guard let snapshot, self.isEnabled, self.visible,
                  self.historicalRangeGeneration == generation,
                  !Task.isCancelled else { return }
            self.historicalReaderSnapshot = snapshot
            self.historicalRange = interval
            self.historicalRetainedBounds = view.retainedBounds
            self.historicalRangeIssue = if view.hadReadError {
                "Some history couldn’t be read."
            } else if view.samples.isEmpty {
                "No usage observations in this range."
            } else {
                nil
            }
        }
    }

    func updateSafetyBuffer(_ value: Double) {
        let value = SafetyBufferPolicy.normalized(value)
        defaults.set(value, forKey: Self.safetyBufferKey)
        let pending = beginRecalculation(safetyBuffer: value)
        Task { [weak self] in
            guard let self else { return }
            let published = await finishRecalculation(pending)
            persist()
            if published {
                await reconcileResetReminder()
            }
        }
    }

    func setResetReminderEnabled(_ isEnabled: Bool) async {
        await resetReminderCoordinator.setEnabled(
            isEnabled,
            target: resetReminderTarget()
        )
        publishResetReminderState()
    }

    func setResetReminderLeadTime(_ leadTime: ResetReminderLeadTime) async {
        await resetReminderCoordinator.setLeadTime(
            leadTime,
            target: resetReminderTarget()
        )
        publishResetReminderState()
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
        planType: String? = nil,
        observedAt: Date
    ) async {
        let partition: AccountHistoryPartition
        let authState: String
        let previousAuthState = defaults.string(forKey: Self.historyAuthStateKey)
        let previousPlanType = defaults.string(
            forKey: Self.historyPlanTypeKey
        )
        var migratedEpoch: Date?
        switch observation {
        case let .stable(identity):
            historyAccountIdentity = identity
            partition = .stable(
                identity: identity,
                key: Self.fingerprintKey(in: defaults)
            )
            authState = "stable:\(partition.id)"
            if previousAuthState == nil, accountEpochStartedAt == nil {
                migratedEpoch = legacySamplesAwaitingMigration
                    .map(\.observedAt)
                    .min()
            }
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
        let planChanged = planType.map {
            previousAuthState != nil && previousPlanType != $0
        } ?? false
        if previousAuthState != authState
            || planChanged
            || accountEpochStartedAt == nil {
            let epoch = migratedEpoch ?? observedAt
            accountEpochStartedAt = epoch
            defaults.set(
                epoch,
                forKey: Self.historyAccountEpochStartedAtKey
            )
        }
        defaults.set(authState, forKey: Self.historyAuthStateKey)
        if let planType {
            defaults.set(planType, forKey: Self.historyPlanTypeKey)
        }
        guard partition != historyPartition else { return }
        cancelLocalImport()
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
        localActivityCollection = .unavailable(
            "Codex local records are unavailable"
        )
        _ = await recalculate()
        if historyPrepared {
            persist()
        }
    }

    private func repairInitialAccountEpochIfNeeded() {
        guard defaults.integer(
            forKey: Self.historyAccountEpochMigrationVersionKey
        ) < 1,
        historyAccountIdentity != nil,
        historyUsesFiles,
        !defaults.bool(forKey: Self.historySyncSelectedKey)
            || historyConnectionActive else {
            return
        }
        defer {
            defaults.set(
                1,
                forKey: Self.historyAccountEpochMigrationVersionKey
            )
        }
        guard let epoch = accountEpochStartedAt,
              let epochSample = samples.first(where: {
                  $0.observedAt == epoch && $0.comparisonBreak
              }),
              !samples.contains(where: {
                  $0.observedAt < epoch && $0.comparisonBreak
              }) else {
            return
        }
        let earlierDates = samples.compactMap {
            $0.resetsAt == epochSample.resetsAt && $0.observedAt < epoch
                ? $0.observedAt
                : nil
        }
        guard let restoredEpoch = earlierDates.min() else {
            return
        }
        accountEpochStartedAt = restoredEpoch
        defaults.set(
            restoredEpoch,
            forKey: Self.historyAccountEpochStartedAtKey
        )
    }

    func deleteAnalyticsHistory() async {
        guard !isUpdatingHistory else { return }
        isUpdatingHistory = true
        defer { isUpdatingHistory = false }
        cancelLocalImport()
        let localDeletedAt = Date()
        NotificationCenter.default.post(
            name: .codexAssistedHistoryDeleted,
            object: nil,
            userInfo: [
                codexAssistedHistoryDeletionCutoffKey: localDeletedAt
            ]
        )
        await prepareHistory()
        apply(await history.deleteAnalyticsHistory(
            syncTarget: configuredSyncDirectory,
            expectsSyncTarget: defaults.bool(forKey: Self.historySyncSelectedKey)
        ))
        var localDeletionFailed = false
        do {
            try await localActivityCollector?.deleteHistory(at: localDeletedAt)
        } catch {
            localDeletionFailed = true
        }
        do {
            try await codexAssistedHistory?.deleteAll(
                upTo: localDeletedAt
            )
        } catch {
            localDeletionFailed = true
        }
        if localDeletionFailed {
            defaults.set(
                localDeletedAt,
                forKey: Self.localHistoryDeletionCutoffKey
            )
            historyDeletionStatus = .pendingLocal
        } else {
            defaults.removeObject(
                forKey: Self.localHistoryDeletionCutoffKey
            )
        }
        localActivityCollection = .unavailable(
            "Codex local records are unavailable"
        )
        previousStatus = nil
        if let snapshot = accountSnapshot {
            accountSnapshot = UsageSnapshot(
                mainLimit: snapshot.mainLimit,
                otherLimits: snapshot.otherLimits,
                tokenHistory: [],
                emergencyResetCount: snapshot.emergencyResetCount,
                bankedResetCountAvailable: snapshot.bankedResetCountAvailable,
                bankedResetDetails: snapshot.bankedResetDetails,
                fetchedAt: snapshot.fetchedAt,
                accountFacts: snapshot.accountFacts
            )
        }
        _ = await recalculate()
        persist()
    }

    func retryHistoryDeletion() async {
        guard !isUpdatingHistory else { return }
        isUpdatingHistory = true
        defer { isUpdatingHistory = false }
        cancelLocalImport()
        let assistedDeletionCutoff = defaults.object(
            forKey: Self.localHistoryDeletionCutoffKey
        ) as? Date
        let wasLocalPending = historyDeletionStatus == .pendingLocal
            || assistedDeletionCutoff != nil
        await prepareHistory()
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
        var localDeletionFailed = false
        do {
            if let cutoff = defaults.object(
                forKey: Self.localHistoryDeletionCutoffKey
            ) as? Date {
                await localActivityCollector?.restorePendingHistoryDeletion(
                    at: cutoff
                )
            }
            try await localActivityCollector?.retryHistoryDeletion()
        } catch {
            localDeletionFailed = true
        }
        if let assistedDeletionCutoff {
            do {
                try await codexAssistedHistory?.deleteAll(
                    upTo: assistedDeletionCutoff
                )
            } catch {
                localDeletionFailed = true
            }
        }
        if !localDeletionFailed {
            defaults.removeObject(
                forKey: Self.localHistoryDeletionCutoffKey
            )
        }
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
        if localDeletionFailed {
            historyDeletionStatus = .pendingLocal
        } else if wasLocalPending, historyDeletionStatus == .none {
            historyDeletionStatus = .complete
        }
        historyConnectionActive = if let configuredSyncDirectory {
            await history.isConnected(to: configuredSyncDirectory)
        } else {
            false
        }
        _ = await recalculate()
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
        cancelLocalImport()
        do {
            let result = try await fetchUsage()
            guard let account = result.account else {
                throw CodexClientError.invalidResponse
            }
            accountWasObserved = true
            historyMatchesCurrentSnapshot = true
            await selectHistoryAccount(
                account,
                planType: result.planType,
                observedAt: result.snapshot.fetchedAt
            )
            let snapshot = result.snapshot
            if let window = snapshot.mainLimit?.window {
                let sample = UsageSample(
                    observedAt: snapshot.fetchedAt,
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt,
                    lifetimeTokens: freshLifetimeTokens(in: snapshot),
                    comparisonBreak:
                        accountEpochStartedAt == snapshot.fetchedAt
                )
                apply(await history.rebuildAvailableHistory([sample]))
            }
            accountSnapshot = snapshot
            sourceState = .available
            try await localActivityCollector?.rebuildHistory()
            await refreshLocalActivity(
                for: snapshot,
                observedAt: snapshot.fetchedAt
            )
            let published = await recalculate(now: snapshot.fetchedAt)
            persist()
            if published {
                await reconcileResetReminder()
            }
        } catch let error as CodexClientError {
            sourceState = .failed(error.localizedDescription)
            _ = await recalculate()
            persist()
        } catch {
            sourceState = .failed("Couldn’t read Codex usage. Try again.")
            _ = await recalculate()
            persist()
        }
    }

    private func recalculate(
        safetyBuffer: Double? = nil,
        now: Date = Date()
    ) async -> Bool {
        await finishRecalculation(
            beginRecalculation(safetyBuffer: safetyBuffer, now: now)
        )
    }

    private func beginRecalculation(
        safetyBuffer: Double? = nil,
        now: Date = Date(),
        analyticsExploration: AnalyticsExplorationState? = nil,
        insightDispositions: [String: InsightDisposition]? = nil
    ) -> (
        generation: UInt64,
        task: Task<UsageReaderSnapshot?, Never>
    ) {
        let input = evaluationInput(
            safetyBuffer: safetyBuffer,
            now: now,
            analyticsExploration: analyticsExploration,
            insightDispositions: insightDispositions
        )
        evaluationGeneration &+= 1
        let generation = evaluationGeneration
        let previousTask = evaluationTask
        previousTask?.cancel()
        let evaluateUsage = evaluateUsage
        let task: Task<UsageReaderSnapshot?, Never> = Task.detached(
            priority: .userInitiated
        ) {
            _ = await previousTask?.value
            guard !Task.isCancelled else { return nil }
            let snapshot = evaluateUsage(input)
            return Task.isCancelled ? nil : snapshot
        }
        evaluationTask = task
        return (generation, task)
    }

    private func evaluationInput(
        safetyBuffer: Double? = nil,
        now: Date = Date(),
        analyticsExploration: AnalyticsExplorationState? = nil,
        insightDispositions: [String: InsightDisposition]? = nil,
        historySamples: [UsageSample]? = nil
    ) -> UsageIntelligenceInput {
        let storedBuffer = defaults.object(forKey: Self.safetyBufferKey) as? Double
        let buffer = SafetyBufferPolicy.normalized(
            safetyBuffer ?? storedBuffer
        )
        return UsageIntelligenceInput(
            account: accountSnapshot,
            samples: historyMatchesCurrentSnapshot
                ? (historySamples ?? samples)
                : [],
            safetyBuffer: buffer,
            sourceState: sourceState,
            now: now,
            previousStatus: previousStatus,
            accountPartitionID: historyPartition.id,
            accountEpochStartedAt: accountEpochStartedAt,
            localActivityFacts: localActivityCollection.facts,
            localActivityHistoryFacts: localActivityCollection.facts,
            localActivityObservation: localActivityCollection.observation,
            localTaskProjections: localActivityCollection.projections,
            localActivityContentRevision:
                localActivityCollection.contentRevision,
            reusableLocalAggregates:
                readerSnapshot.reusableLocalAggregates,
            analyticsExploration:
                analyticsExploration
                    ?? AnalyticsWorkspaceStore.restoredState(from: defaults),
            insightDispositions:
                insightDispositions
                    ?? AnalyticsWorkspaceStore
                        .restoredInsightDispositions(from: defaults)
        )
    }

    private func finishRecalculation(
        _ pending: (
            generation: UInt64,
            task: Task<UsageReaderSnapshot?, Never>
        )
    ) async -> Bool {
        let snapshot = await withTaskCancellationHandler {
            await pending.task.value
        } onCancel: {
            pending.task.cancel()
        }
        if pending.generation == evaluationGeneration {
            evaluationTask = nil
        }
        guard let snapshot,
              !Task.isCancelled,
              pending.generation == evaluationGeneration,
              !pending.task.isCancelled else {
            return false
        }
        readerSnapshot = snapshot
        scheduleReaderBoundary()
        if let status = snapshot.guidance?.status {
            previousStatus = status
        }
        return true
    }

    private func scheduleReaderBoundary() {
        readerBoundaryTask?.cancel()
        guard isEnabled, menuBarSourceActive || visible,
              let account = readerSnapshot.account,
              let reset = account.mainLimit?.window.resetsAt else {
            readerBoundaryTask = nil
            return
        }
        let now = Date()
        let candidates = [
            account.fetchedAt.addingTimeInterval(15 * 60),
            reset
        ].filter { $0 > now }.sorted()
        guard let boundary = candidates.first else {
            readerBoundaryTask = nil
            return
        }
        readerBoundaryTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(boundary.timeIntervalSinceNow)
                )
            } catch {
                return
            }
            guard let self else { return }
            readerBoundaryTask = nil
            _ = await recalculate()
        }
    }

    func analyticsPreferencesDidChange(
        exploration: AnalyticsExplorationState,
        dispositions: [String: InsightDisposition]
    ) {
        let input = DeterministicInsightInput(
            reader: readerSnapshot,
            exploration: exploration,
            now: Date()
        )
        readerSnapshot.insights = DeterministicInsightEngine.evaluate(
            input,
            dispositions: dispositions
        )
        let pending = beginRecalculation(
            analyticsExploration: exploration,
            insightDispositions: dispositions
        )
        Task { [weak self] in
            guard let self else { return }
            if await finishRecalculation(pending) {
                await reconcileResetReminder()
            }
        }
    }

    private func reconcileResetReminder() async {
        await resetReminderCoordinator.reconcile(
            target: resetReminderTarget()
        )
        publishResetReminderState()
    }

    private func resetReminderTarget(now: Date = Date()) -> ResetReminderTarget? {
        guard let summary = readerSnapshot.bankedResets,
              let id = summary.nextKnownResetID,
              let expiresAt = summary.currentNextKnownExpiry(at: now) else {
            return nil
        }
        return ResetReminderTarget(id: id, expiresAt: expiresAt)
    }

    private func publishResetReminderState() {
        resetReminderState = resetReminderCoordinator.state
    }

    private func freshLifetimeTokens(in snapshot: UsageSnapshot) -> Int64? {
        guard let facts = snapshot.accountFacts,
              facts.lifetimeTokensObservedAt == snapshot.fetchedAt else {
            return nil
        }
        return facts.lifetimeTokens
    }

    private func refreshLocalActivity(
        for snapshot: UsageSnapshot,
        observedAt: Date,
        identityVerified: Bool = true
    ) async {
        cancelLocalImport()
        let generation = localImportGeneration
        localAnalyticsNeedsLoad = false
        guard let interval = UsageIntelligenceEngine.tokenActivityInterval(
            account: snapshot,
            samples: historyMatchesCurrentSnapshot ? samples : [],
            accountEpochStartedAt: accountEpochStartedAt
        ) else {
            localActivityCollection = .unavailable(
                "Weekly token interval is unavailable"
            )
            return
        }
        guard let localActivityCollector else {
            localActivityCollection = .unavailable(
                "Codex local records are unavailable"
            )
            return
        }
        await localActivityCollector.selectPartition(historyPartition.id)
        guard generation == localImportGeneration else { return }
        localActivityCollection = .unavailable(
            "Codex local records are unavailable"
        )
        let collection = await localActivityCollector.refresh(
            interval: interval,
            observedAt: observedAt
        )
        guard generation == localImportGeneration else { return }
        let deletionPending =
            await localActivityCollector.hasPendingHistoryDeletion()
        guard generation == localImportGeneration else { return }
        if deletionPending {
            historyDeletionStatus = .pendingLocal
        }
        localActivityCollection = identityVerified
            ? collection
            : collection.loweringCoverage(
                "Codex account identity could not be checked"
        )
        let importPending = await localActivityCollector.hasPendingImport()
        guard generation == localImportGeneration, importPending else {
            return
        }
        localImportTask = Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.continueLocalActivityImport(
                with: localActivityCollector,
                interval: interval,
                observedAt: observedAt,
                identityVerified: identityVerified,
                generation: generation
            )
        }
    }

    private func continueLocalActivityImport(
        with collector: LocalActivityCollector,
        interval: DateInterval,
        observedAt: Date,
        identityVerified: Bool,
        generation: UInt64
    ) async {
        var latest: LocalActivityCollection?
        while !Task.isCancelled, await collector.hasPendingImport() {
            while isRefreshing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard generation == localImportGeneration else { return }
            latest = nil
            let collection = await collector.refresh(
                interval: interval,
                observedAt: observedAt,
                refreshMetadata: false
            )
            guard !Task.isCancelled,
                  generation == localImportGeneration else {
                return
            }
            latest = collection
            if await collector.hasPendingImport() {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let latest,
              !Task.isCancelled,
              generation == localImportGeneration else {
            return
        }
        localActivityCollection = identityVerified
            ? latest
            : latest.loweringCoverage(
                "Codex account identity could not be checked"
            )
        _ = await recalculate(now: observedAt)
        persist()
        if generation == localImportGeneration {
            localImportTask = nil
        }
    }

    private func cancelLocalImport() {
        localImportGeneration &+= 1
        localImportTask?.cancel()
        localImportTask = nil
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
            bindsUnresolvedDeletionTarget: true,
            performFullReconciliation: false
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
                planType: result.planType,
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

    private func exchangeHistory(force: Bool) async -> UsageHistory.State {
        if let configuredSyncDirectory {
            if await history.isConnected(to: configuredSyncDirectory) {
                return force
                    ? await history.synchronize()
                    : await history.synchronizeIfDue()
            }
            let state = await history.connect(
                to: configuredSyncDirectory,
                accountIdentity: historyAccountIdentity,
                accountBindingToken: defaults.string(
                    forKey: Self.historySyncAccountBindingKey
                ),
                performFullReconciliation: false
            )
            historyConnectionActive = state.folderName != nil
            return state
        }
        return force
            ? await history.synchronize()
            : await history.synchronizeIfDue()
    }

    private func exchangeRestoredHistoryIfAvailable(force: Bool) async {
        guard restoredFileStoreAvailable else { return }
        await prepareHistory(legacySamples: [])
        let state = await exchangeHistory(force: force)
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
