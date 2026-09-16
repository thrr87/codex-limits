import AppKit
import ClaudeIntegrationCore
import Combine
import Foundation

private actor GrokSnapshotCache {
    let url: URL
    private var historyURL: URL { url.deletingLastPathComponent().appendingPathComponent("History") }

    init(url: URL) { self.url = url }

    func read(now: Date) throws -> GrokAllowanceSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1_024 + 1) ?? Data()
        guard data.count <= 64 * 1_024 else {
            throw GrokBillingError.invalidResponse
        }
        let snapshot = try JSONDecoder().decode(GrokAllowanceSnapshot.self, from: data)
        guard snapshot.isValid, snapshot.observedAt <= now.addingTimeInterval(60) else {
            throw GrokBillingError.invalidResponse
        }
        return snapshot
    }

    func write(_ snapshot: GrokAllowanceSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The private directory also protects the atomic replacement before chmod.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func readHistory(now: Date, seed: GrokAllowanceSnapshot?) throws -> [AllowanceObservation] {
        if let seed { try appendHistory(seed) }
        return try AllowanceHistory.read(in: historyURL, now: now)
    }

    func readOverview(
        snapshot: GrokAllowanceSnapshot?, now: Date, safetyBuffer: Double
    ) -> (snapshot: UsageOverviewSnapshot?, historyReadFailed: Bool) {
        let current = snapshot?.historyObservation
        guard let since = UsageOverviewSnapshot.historyReadStart(current: current, now: now) else {
            return (nil, false)
        }
        do {
            if let snapshot { try appendHistory(snapshot) }
            let observations = try AllowanceHistory.read(in: historyURL, now: now, since: since)
            return (UsageOverviewSnapshot(
                observations: observations, current: current, now: now, safetyBuffer: safetyBuffer
            ), false)
        } catch {
            return (UsageOverviewSnapshot(
                observations: [], current: current, now: now, safetyBuffer: safetyBuffer
            ), true)
        }
    }

    func appendHistory(_ snapshot: GrokAllowanceSnapshot, previous: GrokAllowanceSnapshot? = nil) throws {
        try AllowanceHistory.append([previous, snapshot].compactMap { $0?.historyObservation }, in: historyURL)
    }

    func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: historyURL.path)
    }

    func delete() throws {
        try AllowanceHistory.delete(in: historyURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor
final class GrokIntegrationStore: ObservableObject {
    @Published private(set) var snapshot: GrokAllowanceSnapshot?
    @Published private(set) var history: [AllowanceObservation] = []
    @Published private(set) var overview: UsageOverviewSnapshot?
    @Published private(set) var historyIssue: String?
    @Published private(set) var error: GrokBillingError?
    @Published private(set) var storageIssue: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasStoredData = false
    @Published private(set) var displayNow: Date

    private var enabled: Bool
    private var menuBarSourceActive: Bool
    private var visible = false
    private var historyVisible = false
    private var overviewSafetyBuffer: Double = 3
    private var overviewDemand: UInt64 = 0
    private var settingsVisible = false
    private var selectedExecutableURL: URL?
    private let cache: GrokSnapshotCache
    private let coordinator: IntegrationWorkCoordinator
    private let fetchUsage: @Sendable (URL) async throws -> GrokAllowanceSnapshot
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private var cacheLoaded = false
    private var historyLoaded = false
    private var generation: UInt64 = 0
    private var request: Task<Void, Never>?
    private var requestPriority: IntegrationWorkPriority?
    private var boundaryTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private var lastLaunchUptime: TimeInterval?
    private var nextRefreshAt = Date.distantPast
    private var failures = 0

    init(
        isEnabled: Bool,
        menuBarSourceActive: Bool = false,
        selectedExecutableURL: URL? = nil,
        cacheURL: URL? = nil,
        integrationWorkCoordinator: IntegrationWorkCoordinator = IntegrationWorkCoordinator(),
        fetchUsage: @escaping @Sendable (URL) async throws -> GrokAllowanceSnapshot = {
            try await GrokBillingClient().fetch(executableURL: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        enabled = isEnabled
        self.menuBarSourceActive = menuBarSourceActive
        self.selectedExecutableURL = selectedExecutableURL
        self.coordinator = integrationWorkCoordinator
        self.fetchUsage = fetchUsage
        self.now = now
        self.uptime = uptime
        displayNow = now()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.cache = GrokSnapshotCache(url: cacheURL ?? support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.github.thrr87.CodexLimits")
            .appendingPathComponent("Integrations/Grok/snapshot.json"))
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemClockDidChange))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateDisplayTime()
                    if self.enabled, self.menuBarSourceActive {
                        await self.refresh(force: false, priority: .automatic)
                    }
                }
            }
            .store(in: &observers)
        if isEnabled, menuBarSourceActive {
            Task { [weak self] in await self?.refresh(force: false, priority: .automatic) }
        }
    }

    var currentSnapshot: GrokAllowanceSnapshot? {
        snapshot.flatMap { $0.resetsAt > displayNow ? $0 : nil }
    }

    var isStale: Bool {
        guard let snapshot = currentSnapshot else { return false }
        return error != nil || displayNow.timeIntervalSince(snapshot.observedAt) >= 30 * 60
            || snapshot.observedAt > displayNow.addingTimeInterval(60)
    }

    var menuBarText: String {
        currentSnapshot?.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    var statusText: String {
        if isRefreshing { return "Checking" }
        if let error { return error.localizedDescription }
        if let currentSnapshot, currentSnapshot.remainingPercent == nil { return "Usage percentage unavailable" }
        if snapshot != nil, currentSnapshot == nil { return "New usage observation needed" }
        return snapshot == nil ? "Ready to check" : (isStale ? "Stale" : "Ready")
    }

    var canRefresh: Bool {
        enabled && !isRefreshing && (lastLaunchUptime.map { uptime() - $0 >= 30 } ?? true)
    }

    func settingsPresented() async {
        guard !Task.isCancelled else { return }
        settingsVisible = true
        updateDisplayTime()
        let expected = generation
        let selected = selectedExecutableURL
        await coordinator.run(priority: .settings) { @MainActor [weak self] in
            guard let self, self.generation == expected, self.settingsVisible else { return }
            let exists = await self.cache.exists()
            guard self.generation == expected, self.settingsVisible else { return }
            self.hasStoredData = exists
            guard self.enabled else { return }
            let executable = await Task.detached { GrokBillingClient.executableURL(selected: selected) }.value
            guard self.generation == expected, self.settingsVisible else { return }
            if executable == nil { self.error = .notFound }
            else if self.error == .notFound { self.error = nil }
        }
    }

    func settingsDismissed() {
        settingsVisible = false
        updateDisplayTime()
    }

    func setEnabled(_ enabled: Bool) async {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if !enabled {
            history = []
            overview = nil
            historyLoaded = false
        }
        let expected = generation &+ 1
        await cancelRequest()
        guard generation == expected else { return }
        if enabled { await refresh(force: false, priority: .explicit) }
    }

    func setMenuBarSourceActive(_ active: Bool) async {
        guard menuBarSourceActive != active else { return }
        menuBarSourceActive = active
        if !active, !visible, requestPriority != .explicit { await cancelRequest() }
        updateDisplayTime()
        if active { await refresh(force: false, priority: .automatic) }
    }

    func setVisible(_ visible: Bool, includeHistory: Bool = true, safetyBuffer: Double = 3) async {
        guard !Task.isCancelled else { return }
        let historyVisible = visible && includeHistory
        let buffer = SafetyBufferPolicy.normalized(safetyBuffer)
        guard self.visible != visible || self.historyVisible != historyVisible
                || overviewSafetyBuffer != buffer else { return }
        self.visible = visible
        self.historyVisible = historyVisible
        overviewSafetyBuffer = buffer
        overviewDemand &+= 1
        overview = nil
        if !visible, !menuBarSourceActive, requestPriority != .explicit { await cancelRequest() }
        if !historyVisible {
            history = []
            historyLoaded = false
        }
        updateDisplayTime()
        if visible {
            await refresh(force: false, priority: .visible)
            // A shared request may have started before All acquired demand.
            if self.visible, !self.historyVisible, overview == nil {
                let expected = generation
                await coordinator.run(priority: .visible) { @MainActor [weak self] in
                    await self?.refreshOverview(expected: expected)
                }
            }
        }
    }

    func selectExecutable(_ url: URL) async -> Bool {
        let initialGeneration = generation
        let valid = await Task.detached { GrokBillingClient.isExecutable(url) }.value
        guard valid, enabled, generation == initialGeneration else { return false }
        selectedExecutableURL = url
        let expected = generation &+ 1
        await cancelRequest()
        guard enabled, generation == expected else { return false }
        error = nil
        nextRefreshAt = .distantPast
        await refresh(force: true)
        return enabled && generation == expected && selectedExecutableURL == url
    }

    func refresh(force: Bool = true, priority: IntegrationWorkPriority = .explicit) async {
        guard enabled, hasDemand(priority), !Task.isCancelled else { return }
        if let request {
            if priority == .explicit, requestPriority != .explicit, !isRefreshing {
                let expected = generation &+ 1
                await cancelRequest()
                guard enabled, generation == expected else { return }
            } else {
                await request.value
                return
            }
        }
        let expected = generation
        requestPriority = priority
        let task = Task { [weak self] in
            guard let self else { return }
            await self.coordinator.run(priority: priority) { @MainActor [weak self] in
                guard let self, self.isCurrent(expected), self.hasDemand(priority) else { return }
                if !self.cacheLoaded {
                    do {
                        let cached = try await self.cache.read(now: self.now())
                        guard self.isCurrent(expected) else { return }
                        self.snapshot = cached
                        self.hasStoredData = cached != nil
                        if let cached, cached.remainingPercent != nil {
                            self.nextRefreshAt = min(cached.observedAt.addingTimeInterval(600), cached.resetsAt)
                        }
                    } catch {
                        guard self.isCurrent(expected) else { return }
                        self.storageIssue = "Saved Grok usage couldn’t be read."
                    }
                    self.cacheLoaded = true
                }
                if self.historyVisible, !self.historyLoaded {
                    do {
                        let history = try await self.cache.readHistory(now: self.now(), seed: self.snapshot)
                        guard self.isCurrent(expected) else { return }
                        if self.historyVisible {
                            self.history = history
                            self.historyLoaded = true
                            self.hasStoredData = self.hasStoredData || !history.isEmpty
                            self.historyIssue = nil
                        }
                    } catch {
                        guard self.isCurrent(expected) else { return }
                        self.historyIssue = "Saved Grok history couldn’t be read."
                    }
                }
                await self.refreshOverview(expected: expected)
                self.updateDisplayTime()
                guard force || self.now() >= self.nextRefreshAt,
                      self.canRefresh else { return }
                let selected = self.selectedExecutableURL
                let executable = await Task.detached { GrokBillingClient.executableURL(selected: selected) }.value
                guard self.isCurrent(expected), self.hasDemand(priority) else { return }
                guard let executable else {
                    self.error = .notFound
                    self.nextRefreshAt = self.now().addingTimeInterval(600)
                    return
                }
                self.isRefreshing = true
                self.lastLaunchUptime = self.uptime()
                do {
                    let snapshot = try await self.fetchUsage(executable)
                    guard self.isCurrent(expected) else { return }
                    let previous = self.snapshot
                    self.snapshot = snapshot
                    self.error = nil
                    self.failures = 0
                    self.nextRefreshAt = self.now().addingTimeInterval(600)
                    do {
                        try await self.cache.appendHistory(snapshot, previous: previous)
                        guard self.isCurrent(expected) else { return }
                        if self.historyVisible, !self.historyLoaded {
                            let history = try await self.cache.readHistory(now: self.now(), seed: nil)
                            guard self.isCurrent(expected) else { return }
                            if self.historyVisible {
                                self.history = history
                                self.historyLoaded = true
                            }
                        } else if self.historyVisible {
                            if let observation = snapshot.historyObservation,
                               observation.isValid, !self.history.contains(observation) {
                                self.history.append(observation)
                            }
                        }
                        let start = self.now().addingTimeInterval(-84 * 86_400)
                        self.history.removeAll { $0.observedAt < start }
                        guard self.history.count <= AllowanceHistory.maximumReadRecords else {
                            self.history = []
                            self.historyLoaded = false
                            throw AllowanceHistoryError.readLimitExceeded
                        }
                        self.historyIssue = nil
                        self.hasStoredData = true
                    } catch {
                        guard self.isCurrent(expected) else { return }
                        self.historyIssue = "Grok history couldn’t be updated on this Mac."
                    }
                    do {
                        try await self.cache.write(snapshot)
                        guard self.isCurrent(expected) else { return }
                        self.hasStoredData = true
                        self.storageIssue = nil
                    } catch {
                        guard self.isCurrent(expected) else { return }
                        self.storageIssue = "Grok usage couldn’t be saved on this Mac."
                    }
                    await self.refreshOverview(expected: expected)
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrent(expected) else { return }
                    self.error = error as? GrokBillingError ?? .failed
                    self.failures = min(self.failures + 1, 4)
                    self.nextRefreshAt = self.now().addingTimeInterval(min(600 * pow(2, Double(self.failures - 1)), 3_600))
                }
            }
            guard self.generation == expected else { return }
            self.isRefreshing = false
            self.request = nil
            self.requestPriority = nil
            self.updateDisplayTime()
        }
        request = task
        await task.value
    }

    func deleteData() async {
        enabled = false
        menuBarSourceActive = false
        visible = false
        historyVisible = false
        overview = nil
        overviewDemand &+= 1
        selectedExecutableURL = nil
        let expected = generation &+ 1
        await cancelRequest()
        await coordinator.run(priority: .explicit) { @MainActor [weak self] in
            guard let self, self.generation == expected, !self.enabled else { return }
            do {
                try await self.cache.delete()
                guard self.generation == expected else { return }
                self.snapshot = nil
                self.history = []
                self.historyLoaded = true
                self.historyIssue = nil
                self.hasStoredData = false
                self.cacheLoaded = true
                self.error = nil
                self.storageIssue = nil
                self.nextRefreshAt = .distantPast
            } catch {
                guard self.generation == expected else { return }
                self.storageIssue = "Grok usage couldn’t be deleted. Try again."
            }
            self.updateDisplayTime()
        }
    }

    func updateDisplayTime() {
        displayNow = now()
        if let overview, overview.range.end <= displayNow { self.overview = nil }
        scheduleBoundary()
    }

    private func refreshOverview(expected: UInt64) async {
        guard isCurrent(expected), visible, !historyVisible else { return }
        let demand = overviewDemand
        let current = snapshot
        let result = await cache.readOverview(
            snapshot: current, now: now(), safetyBuffer: overviewSafetyBuffer
        )
        guard isCurrent(expected), visible, !historyVisible,
              overviewDemand == demand, snapshot == current else { return }
        overview = result.snapshot
        if result.historyReadFailed { historyIssue = "Saved Grok history couldn’t be read." }
        else if current != nil { historyIssue = nil }
    }

    private func hasDemand(_ priority: IntegrationWorkPriority) -> Bool {
        switch priority {
        case .explicit, .settings: true
        case .visible: visible
        case .automatic: menuBarSourceActive
        }
    }

    private func isCurrent(_ expected: UInt64) -> Bool {
        generation == expected && enabled && !Task.isCancelled
    }

    private func cancelRequest() async {
        generation &+= 1
        boundaryTask?.cancel()
        boundaryTask = nil
        let pending = request
        request = nil
        requestPriority = nil
        isRefreshing = false
        pending?.cancel()
        await pending?.value
    }

    private func scheduleBoundary() {
        boundaryTask?.cancel()
        boundaryTask = nil
        guard enabled, menuBarSourceActive || visible || settingsVisible else { return }
        let now = now()
        let cooldown = lastLaunchUptime.map { max(0, 30 - (uptime() - $0)) } ?? 0
        var dates = [snapshot?.observedAt.addingTimeInterval(30 * 60), snapshot?.resetsAt]
            .compactMap { $0 }.filter { $0 > now }
        if cooldown > 0 { dates.append(now.addingTimeInterval(cooldown)) }
        if menuBarSourceActive, request == nil {
            dates.append(max(nextRefreshAt, now.addingTimeInterval(max(cooldown, 0.1))))
        }
        guard let boundary = dates.min() else { return }
        boundaryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(boundary.timeIntervalSince(now))) }
            catch { return }
            guard let self else { return }
            self.displayNow = self.now()
            if let overview = self.overview, overview.range.end <= self.displayNow { self.overview = nil }
            if self.menuBarSourceActive { await self.refresh(force: false, priority: .automatic) }
            else { self.scheduleBoundary() }
        }
    }

    deinit {
        request?.cancel()
        boundaryTask?.cancel()
    }
}
