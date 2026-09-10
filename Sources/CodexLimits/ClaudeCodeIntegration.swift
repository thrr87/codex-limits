import ClaudeIntegrationCore
import Foundation

enum ClaudeCodeReadiness: Equatable, Sendable {
    case disabled
    case checking
    case notFound
    case setUp
    case waitingForData
    case ready
    case conflict
    case updateRequired
    case manualCleanupRequired
    case failed
}

struct ClaudeCodeInspection: Equatable, Sendable {
    let readiness: ClaudeCodeReadiness
    let snapshot: ClaudeAllowanceSnapshot?
}

struct ClaudeCodeIntegrationPaths: Sendable {
    let executableCandidates: [URL]
    let settingsURL: URL
    let dataDirectory: URL
    let helperURL: URL

    var cacheURL: URL { dataDirectory.appendingPathComponent("snapshot.json") }
    var enabledMarkerURL: URL { dataDirectory.appendingPathComponent("enabled") }
    var installRecordURL: URL { dataDirectory.appendingPathComponent("install.json") }
    var historyDirectory: URL { ClaudeRelay.historyDirectory(for: cacheURL) }

    static func live() -> Self {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier
            ?? "com.github.thrr87.CodexLimits"
        return Self(
            executableCandidates: [
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                URL(fileURLWithPath: "/usr/local/bin/claude"),
                home.appendingPathComponent(".local/bin/claude")
            ],
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            dataDirectory: applicationSupport
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("Integrations/ClaudeCode", isDirectory: true),
            helperURL: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent("CodexLimitsClaudeRelay")
        )
    }

    static func isolatedQA(base: URL, bundleURL: URL) -> Self {
        let helperURL = bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("CodexLimitsClaudeRelay")
        return Self(
            executableCandidates: [helperURL],
            settingsURL: base
                .appendingPathComponent("Fixtures/ClaudeCode", isDirectory: true)
                .appendingPathComponent("settings.json"),
            dataDirectory: base
                .appendingPathComponent("Integrations/ClaudeCode", isDirectory: true),
            helperURL: helperURL
        )
    }
}

actor ClaudeCodeSetupService {
    enum SetupError: Error {
        case notFound
        case conflict
        case updateRequired
        case invalidSettings
    }

    private struct StatusLineConfiguration: Codable, Equatable {
        let type: String
        let command: String
        let padding: Int
    }

    private struct InstallRecord: Codable {
        let version: Int
        let settingsPath: String
        let configuration: StatusLineConfiguration
        let createdSettingsFile: Bool?
    }

    private enum StoredStatusLine {
        case absent
        case value(Data)
    }

    private static let maximumSettingsBytes = 1_000_000
    private let paths: ClaudeCodeIntegrationPaths
    private var selectedExecutableURL: URL?
    private var configurationGeneration: UInt64 = 0

    init(
        paths: ClaudeCodeIntegrationPaths = .live(),
        selectedExecutableURL: URL? = nil
    ) {
        self.paths = paths
        self.selectedExecutableURL = selectedExecutableURL
    }

    func inspect() -> ClaudeCodeInspection {
        let snapshot = try? ClaudeRelay.readSnapshot(at: paths.cacheURL)
        guard executableURL() != nil else {
            return ClaudeCodeInspection(readiness: .notFound, snapshot: snapshot)
        }
        guard isExecutable(paths.helperURL) else {
            return ClaudeCodeInspection(
                readiness: .updateRequired,
                snapshot: snapshot
            )
        }
        do {
            let current = try storedStatusLine()
            let owned = try ownedConfigurationData()
            switch current {
            case .absent:
                return ClaudeCodeInspection(
                    readiness: .setUp,
                    snapshot: snapshot
                )
            case let .value(data) where owned.contains(data):
                let enabled = FileManager.default.fileExists(
                    atPath: paths.enabledMarkerURL.path
                )
                return ClaudeCodeInspection(
                    readiness: enabled
                        ? (snapshot == nil ? .waitingForData : .ready)
                        : .setUp,
                    snapshot: snapshot
                )
            case .value:
                return ClaudeCodeInspection(
                    readiness: .conflict,
                    snapshot: snapshot
                )
            }
        } catch {
            return ClaudeCodeInspection(readiness: .failed, snapshot: snapshot)
        }
    }

    func setUp() throws -> ClaudeCodeInspection {
        guard executableURL() != nil else { throw SetupError.notFound }
        guard isExecutable(paths.helperURL) else {
            throw SetupError.updateRequired
        }
        let configuration = expectedConfiguration()
        let expectedData = try canonicalData(configuration)
        let settingsFileExisted = FileManager.default.fileExists(
            atPath: paths.settingsURL.path
        )
        let previousRecord = installRecord()
        switch try storedStatusLine() {
        case .absent:
            break
        case let .value(data):
            guard try ownedConfigurationData().contains(data)
                    || data == expectedData else {
                throw SetupError.conflict
            }
        }

        try FileManager.default.createDirectory(
            at: paths.dataDirectory,
            withIntermediateDirectories: true
        )
        let record = InstallRecord(
            version: 1,
            settingsPath: paths.settingsURL.standardizedFileURL.path,
            configuration: configuration,
            createdSettingsFile: previousRecord?.configuration == configuration
                && previousRecord?.createdSettingsFile == true
                ? true
                : !settingsFileExisted
        )
        try writePrivate(
            try JSONEncoder().encode(record),
            to: paths.installRecordURL
        )
        try writeStatusLine(configuration)
        configurationGeneration &+= 1
        try writePrivate(Data(), to: paths.enabledMarkerURL)
        return inspect()
    }

    func selectExecutable(_ url: URL) -> ClaudeCodeInspection? {
        guard isExecutable(url) else { return nil }
        selectedExecutableURL = url.standardizedFileURL
        return inspect()
    }

    func deactivate() -> Bool {
        guard stopWrites() else { return false }
        do {
            switch try storedStatusLine() {
            case .absent:
                try removeEmptyCreatedSettingsFile()
                try? FileManager.default.removeItem(at: paths.installRecordURL)
                return true
            case let .value(data):
                guard try ownedConfigurationData().contains(data) else {
                    return false
                }
                try removeStatusLine()
                try? FileManager.default.removeItem(at: paths.installRecordURL)
                return true
            }
        } catch {
            return false
        }
    }

    func readSnapshot() -> ClaudeAllowanceSnapshot? {
        try? ClaudeRelay.readSnapshot(at: paths.cacheURL)
    }

    func readHistory() throws -> [AllowanceObservation] {
        if let snapshot = readSnapshot() {
            try AllowanceHistory.append(snapshot.historyObservations, in: paths.historyDirectory)
        }
        return try AllowanceHistory.read(in: paths.historyDirectory, now: Date())
    }

    func readOverview(
        current: AllowanceObservation?, now: Date, safetyBuffer: Double
    ) -> (snapshot: UsageOverviewSnapshot?, historyReadFailed: Bool) {
        guard let since = UsageOverviewSnapshot.historyReadStart(current: current, now: now) else {
            return (nil, false)
        }
        do {
            try AllowanceHistory.append([current].compactMap { $0 }, in: paths.historyDirectory)
            let observations = try AllowanceHistory.read(in: paths.historyDirectory, now: now, since: since)
            return (UsageOverviewSnapshot(
                observations: observations, current: current, now: now, safetyBuffer: safetyBuffer
            ), false)
        } catch {
            return (UsageOverviewSnapshot(
                observations: [], current: current, now: now, safetyBuffer: safetyBuffer
            ), true)
        }
    }

    @discardableResult
    func stopWrites() -> Bool {
        configurationGeneration &+= 1
        do {
            if FileManager.default.fileExists(atPath: paths.enabledMarkerURL.path) {
                try FileManager.default.removeItem(at: paths.enabledMarkerURL)
            }
            return true
        } catch {
            return false
        }
    }

    func hasStoredData() -> Bool {
        [
            paths.cacheURL,
            paths.historyDirectory,
            paths.enabledMarkerURL,
            paths.installRecordURL
        ].contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func deleteData() async -> Bool {
        let deactivated = deactivate()
        let generation = configurationGeneration
        guard !FileManager.default.fileExists(atPath: paths.enabledMarkerURL.path) else {
            return false
        }
        if FileManager.default.fileExists(atPath: paths.dataDirectory.path) {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while true {
                guard generation == configurationGeneration,
                      !Task.isCancelled else { return false }
                do {
                    try ClaudeRelay.deleteSnapshotIfIdle(at: paths.cacheURL)
                    break
                } catch ClaudeRelayError.lockUnavailable {
                    guard ContinuousClock.now < deadline else { return false }
                    do {
                        try await Task.sleep(for: .milliseconds(20))
                    } catch {
                        return false
                    }
                } catch {
                    return false
                }
            }
        }
        var removed = true
        for url in [
            paths.enabledMarkerURL,
            paths.installRecordURL
        ] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                removed = false
            }
        }
        selectedExecutableURL = nil
        return deactivated && removed
    }

    private func executableURL() -> URL? {
        ([selectedExecutableURL].compactMap { $0 }
            + paths.executableCandidates).first(where: isExecutable)
    }

    private func isExecutable(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(
            forKeys: [.isRegularFileKey]
        )
        return values?.isRegularFile == true
            && FileManager.default.isExecutableFile(atPath: resolved.path)
    }

    private func expectedConfiguration() -> StatusLineConfiguration {
        StatusLineConfiguration(
            type: "command",
            command: [
                shellQuoted(paths.helperURL.path),
                "--cache",
                shellQuoted(paths.cacheURL.path),
                "--enabled-marker",
                shellQuoted(paths.enabledMarkerURL.path)
            ].joined(separator: " "),
            padding: 0
        )
    }

    private func ownedConfigurationData() throws -> Set<Data> {
        var result: Set<Data> = [try canonicalData(expectedConfiguration())]
        if let record = installRecord() {
            result.insert(try canonicalData(record.configuration))
        }
        return result
    }

    private func installRecord() -> InstallRecord? {
        guard let data = try? checkedData(at: paths.installRecordURL),
              let record = try? JSONDecoder().decode(
                  InstallRecord.self,
                  from: data
              ), record.version == 1,
              record.settingsPath
                == paths.settingsURL.standardizedFileURL.path else {
            return nil
        }
        return record
    }

    private func storedStatusLine() throws -> StoredStatusLine {
        guard FileManager.default.fileExists(atPath: paths.settingsURL.path) else {
            return .absent
        }
        let object = try settingsObject()
        guard let value = object["statusLine"] else { return .absent }
        guard JSONSerialization.isValidJSONObject(value) else {
            throw SetupError.invalidSettings
        }
        return .value(try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ))
    }

    private func writeStatusLine(
        _ configuration: StatusLineConfiguration
    ) throws {
        var object = try settingsObject(ifMissing: [:])
        object["statusLine"] = try JSONSerialization.jsonObject(
            with: canonicalData(configuration)
        )
        try writeSettings(object)
    }

    private func removeStatusLine() throws {
        var object = try settingsObject()
        object.removeValue(forKey: "statusLine")
        if object.isEmpty, installRecord()?.createdSettingsFile == true {
            try FileManager.default.removeItem(at: paths.settingsURL)
        } else {
            try writeSettings(object)
        }
    }

    private func removeEmptyCreatedSettingsFile() throws {
        guard installRecord()?.createdSettingsFile == true,
              FileManager.default.fileExists(atPath: paths.settingsURL.path),
              try settingsObject().isEmpty else {
            return
        }
        try FileManager.default.removeItem(at: paths.settingsURL)
    }

    private func settingsObject(
        ifMissing fallback: [String: Any]? = nil
    ) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: paths.settingsURL.path) else {
            if let fallback { return fallback }
            throw SetupError.invalidSettings
        }
        let object = try JSONSerialization.jsonObject(
            with: checkedData(at: paths.settingsURL)
        )
        guard let dictionary = object as? [String: Any] else {
            throw SetupError.invalidSettings
        }
        return dictionary
    }

    private func writeSettings(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw SetupError.invalidSettings
        }
        try FileManager.default.createDirectory(
            at: paths.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard data.count <= Self.maximumSettingsBytes else {
            throw SetupError.invalidSettings
        }
        try writePrivate(data, to: paths.settingsURL)
    }

    private func canonicalData(
        _ configuration: StatusLineConfiguration
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(configuration)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private func checkedData(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumSettingsBytes else {
            throw SetupError.invalidSettings
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumSettingsBytes else {
            throw SetupError.invalidSettings
        }
        return data
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
final class ClaudeCodeIntegrationStore: ObservableObject {
    private struct DemandRequest: Equatable {
        let lifecycle: UInt64
        let demand: UInt64
    }

    @Published private(set) var readiness: ClaudeCodeReadiness
    @Published private(set) var snapshot: ClaudeAllowanceSnapshot?
    @Published private(set) var history: [AllowanceObservation] = []
    @Published private(set) var overview: UsageOverviewSnapshot?
    @Published private(set) var historyIssue: String?
    @Published private(set) var hasStoredData = false
    @Published private(set) var displayNow = Date()

    var displayFreshness: ClaudeAllowanceSnapshot.DisplayFreshness? {
        guard let snapshot else { return nil }
        let freshness = snapshot.displayFreshness(now: displayNow)
        guard freshness == .fresh else { return freshness }
        switch readiness {
        case .notFound, .setUp, .conflict, .updateRequired,
             .manualCleanupRequired, .failed:
            return .stale
        default:
            return freshness
        }
    }

    private let service: ClaudeCodeSetupService
    private let integrationWorkCoordinator: IntegrationWorkCoordinator
    private var enabled: Bool
    private var menuBarSourceActive: Bool
    private var visible = false
    private var historyVisible = false
    private var overviewSafetyBuffer: Double = 3
    private var lifecycleGeneration: UInt64 = 0
    private var demandGeneration: UInt64 = 0
    private var notificationObserver: NSObjectProtocol?
    private var boundaryTask: Task<Void, Never>?
    private var readinessRefreshRequest: DemandRequest?
    private var snapshotReadRequest: DemandRequest?
    private var snapshotReadPending = false

    init(
        isEnabled: Bool,
        menuBarSourceActive: Bool = true,
        service: ClaudeCodeSetupService = ClaudeCodeSetupService(),
        integrationWorkCoordinator: IntegrationWorkCoordinator =
            IntegrationWorkCoordinator()
    ) {
        enabled = isEnabled
        self.menuBarSourceActive = menuBarSourceActive
        self.service = service
        self.integrationWorkCoordinator = integrationWorkCoordinator
        readiness = isEnabled ? .checking : .disabled
        if isEnabled {
            observeSnapshots()
            if menuBarSourceActive {
                Task { [weak self] in
                    await self?.refreshReadiness(priority: .automatic)
                }
            }
        }
    }

    func settingsPresented() async {
        let generation = lifecycleGeneration
        let expectedEnabled = enabled
        if expectedEnabled {
            await refreshReadiness(priority: .settings)
            return
        }
        await integrationWorkCoordinator.run(priority: .settings) {
            @MainActor [weak self] in
            guard let self,
                  self.isCurrent(generation, enabled: expectedEnabled) else {
                return
            }
            let hasStoredData = await self.service.hasStoredData()
            guard self.isCurrent(generation, enabled: false) else {
                return
            }
            self.hasStoredData = hasStoredData
            if hasStoredData {
                let snapshot = await self.service.readSnapshot()
                guard self.isCurrent(generation, enabled: false) else {
                    return
                }
                self.setSnapshot(snapshot)
            }
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        if enabled {
            readiness = .checking
            observeSnapshots()
            await refreshReadiness(priority: .explicit)
        } else {
            history = []
            overview = nil
            historyVisible = false
            snapshotReadPending = false
            stopObservingSnapshots()
            boundaryTask?.cancel()
            boundaryTask = nil
            await service.stopWrites()
            guard isCurrent(generation, enabled: false) else { return }
            await integrationWorkCoordinator.run(priority: .explicit) {
                @MainActor [weak self] in
                guard let self,
                      self.isCurrent(generation, enabled: false) else {
                    return
                }
                let removed = await self.service.deactivate()
                guard self.isCurrent(generation, enabled: false) else { return }
                let hasStoredData = await self.service.hasStoredData()
                guard self.isCurrent(generation, enabled: false) else { return }
                self.hasStoredData = hasStoredData
                self.readiness = removed
                    ? .disabled
                    : .manualCleanupRequired
            }
        }
    }

    func setMenuBarSourceActive(_ active: Bool) async {
        guard active != menuBarSourceActive else { return }
        menuBarSourceActive = active
        demandGeneration &+= 1
        scheduleNextBoundary()
        if active {
            await refreshReadiness(priority: .automatic)
        }
    }

    func setVisible(_ visible: Bool, includeHistory: Bool = true, safetyBuffer: Double = 3) async {
        guard !Task.isCancelled else { return }
        let historyVisible = visible && includeHistory
        let buffer = SafetyBufferPolicy.normalized(safetyBuffer)
        guard visible != self.visible || historyVisible != self.historyVisible
                || buffer != overviewSafetyBuffer else { return }
        self.visible = visible
        self.historyVisible = historyVisible
        overviewSafetyBuffer = buffer
        overview = nil
        if !historyVisible { history = [] }
        demandGeneration &+= 1
        scheduleNextBoundary()
        if visible {
            await refreshReadiness(priority: .visible)
        }
    }

    func setUp() async {
        guard enabled else { return }
        let generation = lifecycleGeneration
        readiness = .checking
        await integrationWorkCoordinator.run(priority: .explicit) {
            @MainActor [weak self] in
            guard let self,
                  self.isCurrent(generation, enabled: true) else {
                return
            }
            do {
                let inspection = try await self.service.setUp()
                guard self.isCurrent(generation, enabled: true) else { return }
                self.apply(inspection)
                self.hasStoredData = true
                await self.refreshHistory(for: DemandRequest(
                    lifecycle: generation, demand: self.demandGeneration
                ))
            } catch ClaudeCodeSetupService.SetupError.notFound {
                guard self.isCurrent(generation, enabled: true) else { return }
                self.readiness = .notFound
            } catch ClaudeCodeSetupService.SetupError.conflict {
                guard self.isCurrent(generation, enabled: true) else { return }
                self.readiness = .conflict
            } catch ClaudeCodeSetupService.SetupError.updateRequired {
                guard self.isCurrent(generation, enabled: true) else { return }
                self.readiness = .updateRequired
            } catch {
                guard self.isCurrent(generation, enabled: true) else { return }
                self.readiness = .failed
            }
        }
    }

    func selectExecutable(_ url: URL) async -> Bool {
        guard enabled else { return false }
        let generation = lifecycleGeneration
        readiness = .checking
        await integrationWorkCoordinator.run(priority: .explicit) {
            @MainActor [weak self] in
            guard let self,
                  self.isCurrent(generation, enabled: true) else {
                return
            }
            guard let inspection = await self.service.selectExecutable(url) else {
                self.readiness = .notFound
                return
            }
            guard self.isCurrent(generation, enabled: true) else { return }
            let hasStoredData = await self.service.hasStoredData()
            guard self.isCurrent(generation, enabled: true) else { return }
            self.apply(inspection)
            self.hasStoredData = hasStoredData
            await self.refreshHistory(for: DemandRequest(
                lifecycle: generation, demand: self.demandGeneration
            ))
        }
        return isCurrent(generation, enabled: true)
            && readiness != .checking
            && readiness != .notFound
    }

    func checkForNewObservation(
        priority: IntegrationWorkPriority = .explicit
    ) async {
        guard enabled else { return }
        let generation = lifecycleGeneration
        let request = DemandRequest(
            lifecycle: generation,
            demand: demandGeneration
        )
        guard demandIsCurrent(request, priority: priority) else { return }
        if snapshotReadRequest == request {
            if priority == .automatic { snapshotReadPending = true }
            return
        }
        snapshotReadRequest = request
        defer {
            if snapshotReadRequest == request {
                snapshotReadRequest = nil
                if snapshotReadPending {
                    snapshotReadPending = false
                    Task { @MainActor [weak self] in
                        await self?.readAutomaticSnapshotIfDemanded()
                    }
                }
            }
        }
        await integrationWorkCoordinator.run(priority: priority) {
            @MainActor [weak self] in
            guard let self,
                  self.isCurrent(generation, enabled: true),
                  self.demandIsCurrent(request, priority: priority) else {
                return
            }
            let snapshot = await self.service.readSnapshot()
            guard self.isCurrent(generation, enabled: true),
                  self.demandIsCurrent(request, priority: priority) else {
                return
            }
            self.setSnapshot(snapshot)
            if snapshot != nil {
                switch self.readiness {
                case .ready, .waitingForData, .failed, .checking:
                    self.readiness = .ready
                default:
                    break
                }
            } else if self.snapshot != nil {
                self.readiness = .failed
            } else if self.readiness == .ready {
                self.readiness = .waitingForData
            }
            await self.refreshHistory(for: request)
        }
    }

    func deleteData() async {
        enabled = false
        menuBarSourceActive = false
        visible = false
        historyVisible = false
        overview = nil
        snapshotReadPending = false
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        stopObservingSnapshots()
        boundaryTask?.cancel()
        boundaryTask = nil
        await service.stopWrites()
        guard isCurrent(generation, enabled: false) else { return }
        await integrationWorkCoordinator.run(priority: .explicit) {
            @MainActor [weak self] in
            guard let self,
                  self.isCurrent(generation, enabled: false) else {
                return
            }
            let removed = await self.service.deleteData()
            guard self.isCurrent(generation, enabled: false) else { return }
            let hasStoredData = await self.service.hasStoredData()
            guard self.isCurrent(generation, enabled: false) else { return }
            self.snapshot = nil
            self.history = []
            self.overview = nil
            self.historyIssue = nil
            self.hasStoredData = hasStoredData
            self.displayNow = Date()
            self.readiness = removed
                ? .disabled
                : .manualCleanupRequired
        }
    }

    private func refreshReadiness(
        priority: IntegrationWorkPriority
    ) async {
        guard enabled else { return }
        let generation = lifecycleGeneration
        let request = DemandRequest(
            lifecycle: generation,
            demand: demandGeneration
        )
        guard readinessRefreshRequest != request,
              demandIsCurrent(request, priority: priority) else { return }
        readinessRefreshRequest = request
        defer {
            if readinessRefreshRequest == request {
                readinessRefreshRequest = nil
            }
        }
        readiness = .checking
        await integrationWorkCoordinator.run(priority: priority) {
            @MainActor [weak self] in
            guard let self,
                  self.isCurrent(generation, enabled: true),
                  self.demandIsCurrent(request, priority: priority) else {
                return
            }
            let inspection = await self.service.inspect()
            guard self.isCurrent(generation, enabled: true),
                  self.demandIsCurrent(request, priority: priority) else {
                return
            }
            let hasStoredData = await self.service.hasStoredData()
            guard self.isCurrent(generation, enabled: true) else { return }
            self.apply(inspection)
            self.hasStoredData = hasStoredData
            await self.refreshHistory(for: request)
        }
    }

    private func refreshHistory(for request: DemandRequest) async {
        guard !Task.isCancelled, visible, isCurrent(request.lifecycle, enabled: true),
              request.demand == demandGeneration else { return }
        if !historyVisible {
            let result = await service.readOverview(
                current: snapshot?.historyObservations.first { $0.metric == "claude-seven-day" },
                now: displayNow, safetyBuffer: overviewSafetyBuffer
            )
            guard !Task.isCancelled, visible, !historyVisible, isCurrent(request.lifecycle, enabled: true),
                  request.demand == demandGeneration else { return }
            overview = result.snapshot
            historyIssue = result.historyReadFailed ? "Claude Code usage history couldn’t be read."
                : snapshot?.historyWriteFailed == true ? "Some Claude Code usage history couldn’t be saved." : nil
            return
        }
        do {
            let history = try await service.readHistory()
            guard historyVisible, isCurrent(request.lifecycle, enabled: true),
                  request.demand == demandGeneration else { return }
            self.history = history
            historyIssue = snapshot?.historyWriteFailed == true
                ? "Some Claude Code usage history couldn’t be saved."
                : nil
        } catch {
            guard historyVisible, isCurrent(request.lifecycle, enabled: true),
                  request.demand == demandGeneration else { return }
            historyIssue = "Claude Code usage history couldn’t be read."
        }
    }

    private func isCurrent(
        _ generation: UInt64,
        enabled: Bool
    ) -> Bool {
        lifecycleGeneration == generation && self.enabled == enabled
    }

    private func demandIsCurrent(
        _ request: DemandRequest,
        priority: IntegrationWorkPriority
    ) -> Bool {
        guard request.lifecycle == lifecycleGeneration else { return false }
        switch priority {
        case .visible:
            return request.demand == demandGeneration && visible
        case .automatic:
            return request.demand == demandGeneration
                && (menuBarSourceActive || visible)
        case .explicit, .settings:
            return true
        }
    }

    private func apply(_ inspection: ClaudeCodeInspection) {
        readiness = inspection.snapshot == nil && snapshot != nil
            && inspection.readiness == .waitingForData
            ? .failed
            : inspection.readiness
        setSnapshot(inspection.snapshot)
        if inspection.snapshot != nil {
            hasStoredData = true
        }
    }

    private func observeSnapshots() {
        guard notificationObserver == nil else { return }
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(
                ClaudeRelay.snapshotChangedNotificationName
            ),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.readAutomaticSnapshotIfDemanded()
            }
        }
    }

    private func readAutomaticSnapshotIfDemanded() async {
        guard menuBarSourceActive || visible else { return }
        await checkForNewObservation(priority: .automatic)
    }

    private func stopObservingSnapshots() {
        guard let notificationObserver else { return }
        DistributedNotificationCenter.default().removeObserver(
            notificationObserver
        )
        self.notificationObserver = nil
    }

    private func setSnapshot(_ snapshot: ClaudeAllowanceSnapshot?) {
        if let snapshot {
            self.snapshot = snapshot
            hasStoredData = true
            if snapshot.historyWriteFailed == true {
                historyIssue = "Some Claude Code usage history couldn’t be saved."
            }
        }
        displayNow = Date()
        if let overview, overview.range.end <= displayNow { self.overview = nil }
        scheduleNextBoundary()
    }

    private func scheduleNextBoundary() {
        boundaryTask?.cancel()
        guard enabled, menuBarSourceActive || visible, let snapshot else {
            boundaryTask = nil
            return
        }
        let now = Date()
        let candidates = [
            snapshot.observedAt.addingTimeInterval(30 * 60),
            snapshot.fiveHour?.resetsAt,
            snapshot.sevenDay?.resetsAt
        ].compactMap { $0 }.filter { $0 > now }.sorted()
        guard let boundary = candidates.first else {
            boundaryTask = nil
            return
        }
        boundaryTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(boundary.timeIntervalSinceNow)
                )
            } catch {
                return
            }
            guard let self else { return }
            displayNow = Date()
            if let overview, overview.range.end <= displayNow { self.overview = nil }
            scheduleNextBoundary()
        }
    }

    deinit {
        boundaryTask?.cancel()
        if let notificationObserver {
            DistributedNotificationCenter.default().removeObserver(
                notificationObserver
            )
        }
    }
}

extension ClaudeAllowanceSnapshot {
    enum DisplayFreshness: Equatable {
        case fresh
        case stale
        case expired
    }

    func displayFreshness(now: Date) -> DisplayFreshness {
        if let primaryReset = sevenDay?.resetsAt ?? fiveHour?.resetsAt,
           primaryReset <= now {
            return .expired
        }
        return (-AllowanceHistory.maximumObservationClockSkew ... 30 * 60).contains(now.timeIntervalSince(observedAt))
            ? .fresh
            : .stale
    }

    func sevenDayMenuBarText(now: Date) -> String {
        guard let sevenDay, sevenDay.resetsAt > now else { return "—" }
        return "\(Int(sevenDay.remainingPercent.rounded()))%"
    }
}
