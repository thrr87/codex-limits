import AppKit
import Combine
import Foundation

@MainActor
final class UsageMonitor: ObservableObject {
    static let safetyBufferKey = "safetyBuffer"

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var forecast: Forecast?
    @Published private(set) var samples: [UsageSample] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncFolderName: String?
    @Published private(set) var syncErrorMessage: String?

    private static let stateKey = "usageState"
    private static let historyInstallationIDKey = "historyInstallationID"
    private static let historySyncBookmarkKey = "historySyncBookmark"
    private let history: UsageHistory
    private var previousStatus: PaceStatus?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var historyPrepared = false
    private var historyUsesFiles = false
    private var configuredSyncDirectory: URL?
    private var historyConnectionActive = false

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.stateKey),
           let state = try? JSONDecoder().decode(StoredState.self, from: data) {
            snapshot = state.snapshot
            samples = state.samples
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
        history = UsageHistory(
            localDirectory: Self.historyDirectory(),
            installationID: installationID
        )
        recalculate()

        Task { [weak self] in
            await self?.start()
        }
    }

    var menuBarText: String {
        guard let remaining = snapshot?.mainLimit.window.remainingPercent else { return "—" }
        return "\(Int(remaining.rounded()))%"
    }

    var currentWindowSamples: [UsageSample] {
        guard let reset = snapshot?.mainLimit.window.resetsAt else { return [] }
        return samples.filter { $0.resetsAt == reset }.sorted { $0.observedAt < $1.observedAt }
    }

    func start() async {
        guard !started else { return }
        started = true

        await prepareHistory()

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

        await prepareHistory()
        if !historyUsesFiles {
            let historyState = await history.load(legacySamples: samples)
            apply(historyState)
            historyUsesFiles = historyState.errorMessage == nil
        }

        let fetchTask = Task { try await CodexClient.fetch() }
        let historyState = await exchangeHistory()
        apply(historyState, configuredFolderName: configuredSyncDirectory?.lastPathComponent)
        let exchangeErrorMessage = historyState.errorMessage
        recalculate()
        persist()

        do {
            let newSnapshot = try await fetchTask.value
            let window = newSnapshot.mainLimit.window
            let sample = UsageSample(
                observedAt: newSnapshot.fetchedAt,
                remainingPercent: window.remainingPercent,
                resetsAt: window.resetsAt
            )
            let recordedState = await history.record(sample)
            apply(recordedState, configuredFolderName: configuredSyncDirectory?.lastPathComponent)
            if recordedState.errorMessage == nil {
                syncErrorMessage = exchangeErrorMessage
            }
            snapshot = newSnapshot
            errorMessage = nil
            recalculate()
            persist()
        } catch let error as CodexClientError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Couldn’t read Codex usage. Try refreshing again."
        }
    }

    func updateSafetyBuffer(_ value: Double) {
        recalculate(safetyBuffer: value)
        persist()
    }

    func connectHistoryFolder(_ directory: URL) async {
        await prepareHistory()
        let state = await history.connect(to: directory)
        apply(state)
        historyConnectionActive = state.folderName != nil
        guard historyConnectionActive else { return }

        do {
            let bookmark = try directory.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.historySyncBookmarkKey)
            configuredSyncDirectory = directory
            syncFolderName = directory.lastPathComponent
        } catch {
            _ = await history.disconnect()
            configuredSyncDirectory = nil
            historyConnectionActive = false
            syncFolderName = nil
            syncErrorMessage = "Couldn’t remember the history folder. Choose it again."
        }
    }

    func stopHistorySync() async {
        UserDefaults.standard.removeObject(forKey: Self.historySyncBookmarkKey)
        configuredSyncDirectory = nil
        historyConnectionActive = false
        apply(await history.disconnect())
    }

    private func recalculate(safetyBuffer: Double? = nil) {
        guard let snapshot else { return }
        let storedBuffer = UserDefaults.standard.object(forKey: Self.safetyBufferKey) as? Double
        let buffer = safetyBuffer ?? storedBuffer ?? 3
        let result = ForecastEngine.evaluate(
            window: snapshot.mainLimit.window,
            samples: samples,
            tokenHistory: snapshot.tokenHistory,
            safetyBuffer: buffer,
            now: snapshot.fetchedAt,
            previousStatus: previousStatus
        )
        forecast = result
        previousStatus = result.status
    }

    private func persist() {
        let state = StoredState(
            snapshot: snapshot,
            samples: historyUsesFiles ? [] : samples,
            previousStatus: previousStatus
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    private func prepareHistory() async {
        guard !historyPrepared else { return }
        historyPrepared = true

        let state = await history.load(legacySamples: samples)
        apply(state)
        historyUsesFiles = state.errorMessage == nil
        if historyUsesFiles {
            persist()
        }

        guard let bookmark = UserDefaults.standard.data(forKey: Self.historySyncBookmarkKey) else {
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
            UserDefaults.standard.removeObject(forKey: Self.historySyncBookmarkKey)
            syncErrorMessage = "Couldn’t reopen the history folder. Choose it again."
            return
        }

        configuredSyncDirectory = directory
        let connectedState = await history.connect(to: directory)
        historyConnectionActive = connectedState.folderName != nil
        apply(connectedState, configuredFolderName: directory.lastPathComponent)
        if isStale, historyConnectionActive {
            do {
                let refreshed = try directory.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(refreshed, forKey: Self.historySyncBookmarkKey)
            } catch {
                syncErrorMessage = "Couldn’t update the saved history folder."
            }
        }
    }

    private func exchangeHistory() async -> UsageHistory.State {
        if let configuredSyncDirectory, !historyConnectionActive {
            let state = await history.connect(to: configuredSyncDirectory)
            historyConnectionActive = state.folderName != nil
            return state
        }
        return await history.synchronize()
    }

    private func apply(
        _ state: UsageHistory.State,
        configuredFolderName: String? = nil
    ) {
        samples = state.samples
        syncFolderName = state.folderName ?? configuredFolderName
        syncErrorMessage = state.errorMessage
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
}

private struct StoredState: Codable {
    let snapshot: UsageSnapshot?
    let samples: [UsageSample]
    let previousStatus: PaceStatus?
}
