import Foundation

actor UsageHistory {
    struct State: Equatable, Sendable {
        let samples: [UsageSample]
        let folderName: String?
        let errorMessage: String?
    }

    private struct Marker: Codable {
        let version: Int
    }

    private struct DailyFile: Codable {
        let version: Int
        let samples: [UsageSample]
    }

    private enum HistoryError: Error {
        case invalidFolder
        case invalidFile
        case unsupportedFileVersion
        case unsupportedFolderVersion
        case unavailableFolder
    }

    private static let formatVersion = 1
    private static let markerName = ".codex-limits-history.json"
    private static let installationsName = "installations"
    private static let retention: TimeInterval = 90 * 86_400
    private static let maximumFileSize = 1_000_000

    private let localDirectory: URL
    private let installationID: String
    private let now: @Sendable () -> Date
    private var syncDirectory: URL?
    private var errorMessage: String?
    private var knownSamples: [UsageSample] = []

    init(
        localDirectory: URL,
        installationID: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.localDirectory = localDirectory
        self.installationID = installationID
        self.now = now
    }

    func load(legacySamples: [UsageSample] = []) -> State {
        do {
            try prepareRoot(localDirectory, createIfMissing: true, coordinated: false)
            let hadCleanupErrors = try removeExpiredOwnFiles(from: localDirectory, coordinated: false)
            try add(legacySamples, to: localDirectory, installationID: installationID, coordinated: false)
            errorMessage = hadCleanupErrors
                ? "Some usage history couldn’t be read."
                : nil
        } catch {
            errorMessage = "Usage history couldn’t be saved."
        }
        return state(fallback: legacySamples)
    }

    func record(_ sample: UsageSample) -> State {
        do {
            try prepareRoot(localDirectory, createIfMissing: true, coordinated: false)
            _ = try removeExpiredOwnFiles(from: localDirectory, coordinated: false)
            try add([sample], to: localDirectory, installationID: installationID, coordinated: false)
            if let syncDirectory {
                try prepareRoot(syncDirectory, createIfMissing: false, coordinated: true)
                _ = try removeExpiredOwnFiles(from: syncDirectory, coordinated: true)
                try add([sample], to: syncDirectory, installationID: installationID, coordinated: true)
            }
            errorMessage = nil
        } catch {
            errorMessage = syncDirectory == nil
                ? "Usage history couldn’t be saved."
                : message(for: error)
        }
        return state()
    }

    func connect(to directory: URL) -> State {
        do {
            try prepareRoot(directory, createIfMissing: false, coordinated: true)
            let existing = readAll(from: localDirectory).samples
            try add(existing, to: localDirectory, installationID: installationID, coordinated: false)
            syncDirectory = directory
            errorMessage = nil
            return synchronize()
        } catch {
            errorMessage = message(for: error)
            return state()
        }
    }

    func disconnect() -> State {
        syncDirectory = nil
        errorMessage = nil
        return state()
    }

    func synchronize() -> State {
        guard let syncDirectory else { return state() }
        do {
            try prepareRoot(syncDirectory, createIfMissing: false, coordinated: true)
            _ = try removeExpiredOwnFiles(from: localDirectory, coordinated: false)
            _ = try removeExpiredOwnFiles(from: syncDirectory, coordinated: true)
            let hadImportErrors = try importHistory(from: syncDirectory)
            try publishOwnHistory(to: syncDirectory)
            errorMessage = hadImportErrors
                ? "Some synced history couldn’t be read."
                : nil
        } catch {
            errorMessage = message(for: error)
        }
        return state()
    }

    private func state(fallback: [UsageSample] = []) -> State {
        let local = readAll(from: localDirectory)
        if local.hadError && errorMessage == nil {
            errorMessage = "Some usage history couldn’t be read."
        }
        let samples = local.hadError || errorMessage != nil
            ? normalized(local.samples + knownSamples + fallback)
            : local.samples
        knownSamples = samples
        return State(
            samples: samples,
            folderName: syncDirectory?.lastPathComponent,
            errorMessage: errorMessage
        )
    }

    private func prepareRoot(_ root: URL, createIfMissing: Bool, coordinated: Bool) throws {
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
            guard value.version == Self.formatVersion else {
                throw HistoryError.unsupportedFolderVersion
            }
        } else {
            let entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard entries.isEmpty else { throw HistoryError.invalidFolder }
            let data = try JSONEncoder().encode(Marker(version: Self.formatVersion))
            try writeData(data, to: marker, coordinated: coordinated)
        }

        try createDirectory(
            at: installationsDirectory(in: root),
            coordinated: coordinated
        )
    }

    private func add(
        _ samples: [UsageSample],
        to root: URL,
        installationID: String,
        coordinated: Bool
    ) throws {
        let valid = normalized(samples)
        guard !valid.isEmpty else { return }
        let grouped = Dictionary(grouping: valid, by: { dayName(for: $0.observedAt) })
        let writerDirectory = installationsDirectory(in: root)
            .appendingPathComponent(installationID, isDirectory: true)
        try createDirectory(at: writerDirectory, coordinated: coordinated)

        for (day, newSamples) in grouped {
            let url = writerDirectory.appendingPathComponent("\(day).json")
            let existing = try readDailyFileIfPresent(at: url, coordinated: coordinated)
            try write(normalized(existing + newSamples), to: url, coordinated: coordinated)
        }
    }

    private func importHistory(from remoteRoot: URL) throws -> Bool {
        let remoteInstallations = installationsDirectory(in: remoteRoot)
        let localInstallations = installationsDirectory(in: localDirectory)
        var hadError = false
        for remoteWriter in try directoryContents(of: remoteInstallations) {
            let localWriter = localInstallations.appendingPathComponent(
                remoteWriter.lastPathComponent,
                isDirectory: true
            )
            try createDirectory(at: localWriter, coordinated: false)
            for remoteFile in try jsonFiles(in: remoteWriter) {
                do {
                    let localFile = localWriter.appendingPathComponent(remoteFile.lastPathComponent)
                    let remoteSamples = try readDailyFileIfPresent(at: remoteFile, coordinated: true)
                    let localSamples = try readDailyFileIfPresent(at: localFile, coordinated: false)
                    try write(
                        normalized(localSamples + remoteSamples),
                        to: localFile,
                        coordinated: false
                    )
                } catch {
                    hadError = true
                }
            }
        }
        return hadError
    }

    private func publishOwnHistory(to remoteRoot: URL) throws {
        let localWriter = installationsDirectory(in: localDirectory)
            .appendingPathComponent(installationID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: localWriter.path) else { return }
        let remoteWriter = installationsDirectory(in: remoteRoot)
            .appendingPathComponent(installationID, isDirectory: true)
        try createDirectory(at: remoteWriter, coordinated: true)
        for localFile in try jsonFiles(in: localWriter) {
            let remoteFile = remoteWriter.appendingPathComponent(localFile.lastPathComponent)
            let localSamples = try readDailyFileIfPresent(at: localFile, coordinated: false)
            let remoteSamples = try readDailyFileIfPresent(at: remoteFile, coordinated: true)
            let merged = normalized(localSamples + remoteSamples)
            try write(merged, to: localFile, coordinated: false)
            try write(merged, to: remoteFile, coordinated: true)
        }
    }

    private func removeExpiredOwnFiles(from root: URL, coordinated: Bool) throws -> Bool {
        let writer = installationsDirectory(in: root)
            .appendingPathComponent(installationID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: writer.path) else { return false }
        var hadReadError = false
        for file in try jsonFiles(in: writer) {
            let existing: [UsageSample]
            do {
                existing = try readDailyFileIfPresent(at: file, coordinated: coordinated)
            } catch {
                hadReadError = true
                continue
            }
            let retained = normalized(existing)
            if retained.isEmpty {
                try removeItem(at: file, coordinated: coordinated)
            } else if retained != existing {
                try write(retained, to: file, coordinated: coordinated)
            }
        }
        return hadReadError
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

    private func readDailyFileIfPresent(at url: URL, coordinated: Bool) throws -> [UsageSample] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let value = try JSONDecoder().decode(
            DailyFile.self,
            from: readData(at: url, coordinated: coordinated)
        )
        guard value.version == Self.formatVersion else {
            throw HistoryError.unsupportedFileVersion
        }
        return value.samples
    }

    private func write(_ samples: [UsageSample], to url: URL, coordinated: Bool) throws {
        let value = DailyFile(version: Self.formatVersion, samples: samples)
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
        return try Data(contentsOf: url)
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
        let cutoff = now().addingTimeInterval(-Self.retention)
        return Array(Set(samples.filter {
            $0.observedAt >= cutoff
                && $0.observedAt <= $0.resetsAt
                && $0.remainingPercent.isFinite
                && (0 ... 100).contains($0.remainingPercent)
        })).sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            if $0.remainingPercent != $1.remainingPercent {
                return $0.remainingPercent > $1.remainingPercent
            }
            return $0.resetsAt < $1.resetsAt
        }
    }

    private func installationsDirectory(in root: URL) -> URL {
        root.appendingPathComponent(Self.installationsName, isDirectory: true)
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

    private func dayName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func message(for error: Error) -> String {
        switch error {
        case HistoryError.invalidFolder:
            "Choose an empty folder or an existing Codex Limits history folder."
        case HistoryError.unsupportedFolderVersion:
            "This history folder was created by a newer version of Codex Limits."
        case HistoryError.unavailableFolder:
            "Sync paused — folder unavailable."
        default:
            "Some synced history couldn’t be read."
        }
    }
}
