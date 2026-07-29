import Foundation

extension Notification.Name {
    static let codexAssistedHistoryDeleted = Notification.Name(
        "CodexAssistedHistoryDeleted"
    )
}

let codexAssistedHistoryDeletionCutoffKey = "cutoff"

struct CodexAssistedHistoryResult: Codable, Equatable, Sendable {
    let id: UUID
    let accountPartitionID: String
    let scopeFingerprint: String
    let sourceSelectionFingerprint: String?
    let sourceCategories: [String]?
    let result: CodexAssistedAnalysisResult
}

struct CodexAssistedHistoryOverhead: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
        case cancelled
    }

    let id: UUID
    let accountPartitionID: String
    let observedAt: Date
    let outcome: Outcome
    let overhead: CodexAnalyticsOverhead
}

actor CodexAssistedHistory {
    static let shared = CodexAssistedHistory(fileURL: defaultFileURL())

    private struct File: Codable {
        let version: Int
        var results: [CodexAssistedHistoryResult]
        var overhead: [CodexAssistedHistoryOverhead]
    }

    private struct DeletionMarker: Codable {
        let cutoff: Date
    }

    private enum DeletionMarkerRestore {
        case missing
        case valid(Date)
        case invalid
    }

    private static let version = 1
    private static let maximumMarkerBytes = 1_048_576

    private enum HistoryError: Error {
        case unreadableHistory
    }
    private let fileURL: URL
    private let deletionMarkerURL: URL
    private var file: File?
    private var didLoad = false
    private var loadFailed = false

    init(
        fileURL: URL,
        deletionMarkerURL: URL? = nil
    ) {
        self.fileURL = fileURL
        self.deletionMarkerURL = deletionMarkerURL
            ?? fileURL.appendingPathExtension("deleting")
    }

    func results(
        accountPartitionID: String
    ) -> [CodexAssistedHistoryResult] {
        guard loadIfNeeded() else { return [] }
        return file?.results.filter {
            $0.accountPartitionID == accountPartitionID
        } ?? []
    }

    func overhead(
        accountPartitionID: String
    ) -> [CodexAssistedHistoryOverhead] {
        guard loadIfNeeded() else { return [] }
        return file?.overhead.filter {
            $0.accountPartitionID == accountPartitionID
        } ?? []
    }

    func recordAnalysis(
        result: CodexAssistedAnalysisResult?,
        overhead: CodexAnalyticsOverhead,
        outcome: CodexAssistedHistoryOverhead.Outcome,
        scope: CodexAssistedAnalysisScope,
        observedAt: Date = Date()
    ) throws {
        guard let accountPartitionID = scope.accountPartitionID else {
            return
        }
        guard loadIfNeeded() else {
            throw HistoryError.unreadableHistory
        }
        let previous = file
        file?.overhead.append(
            CodexAssistedHistoryOverhead(
                id: UUID(),
                accountPartitionID: accountPartitionID,
                observedAt: observedAt,
                outcome: outcome,
                overhead: overhead
            )
        )
        if let result, !scope.fingerprint.isEmpty {
            file?.results.append(
                CodexAssistedHistoryResult(
                    id: UUID(),
                    accountPartitionID: accountPartitionID,
                    scopeFingerprint: scope.fingerprint,
                    sourceSelectionFingerprint:
                        scope.sourceSelectionFingerprint,
                    sourceCategories: scope.sourceCategories,
                    result: result
                )
            )
        }
        do {
            try persist()
        } catch {
            file = previous
            throw error
        }
    }

    func deleteAll(upTo cutoff: Date = Date()) throws {
        guard loadIfNeeded() else {
            try writeDeletionMarker(cutoff)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            if FileManager.default.fileExists(
                atPath: deletionMarkerURL.path
            ) {
                try FileManager.default.removeItem(at: deletionMarkerURL)
            }
            file = File(version: Self.version, results: [], overhead: [])
            loadFailed = false
            return
        }
        try writeDeletionMarker(cutoff)
        file?.results.removeAll {
            $0.result.observedAt <= cutoff
        }
        file?.overhead.removeAll {
            $0.observedAt <= cutoff
        }
        do {
            if file?.results.isEmpty == true,
               file?.overhead.isEmpty == true {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } else {
                try persist()
            }
            if FileManager.default.fileExists(
                atPath: deletionMarkerURL.path
            ) {
                try FileManager.default.removeItem(at: deletionMarkerURL)
            }
        } catch {
            throw error
        }
    }

    @discardableResult
    private func loadIfNeeded() -> Bool {
        if didLoad { return !loadFailed }
        didLoad = true
        let deletionCutoff: Date?
        switch deletionMarker() {
        case .missing:
            deletionCutoff = nil
        case let .valid(cutoff):
            deletionCutoff = cutoff
        case .invalid:
            loadFailed = true
            return false
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            file = File(version: Self.version, results: [], overhead: [])
            return true
        }
        // ponytail: v1 is one JSON document; map its bytes until a
        // future file version can decode records one at a time.
        guard let data = try? Data(
            contentsOf: fileURL,
            options: .mappedIfSafe
        ),
              let decoded = try? JSONDecoder().decode(File.self, from: data),
              decoded.version == Self.version else {
            loadFailed = true
            return false
        }
        var filtered = decoded
        if let deletionCutoff {
            filtered.results.removeAll {
                $0.result.observedAt <= deletionCutoff
            }
            filtered.overhead.removeAll {
                $0.observedAt <= deletionCutoff
            }
        }
        file = filtered
        return true
    }

    private func persist() throws {
        guard let file else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    private func writeDeletionMarker(_ cutoff: Date) throws {
        try FileManager.default.createDirectory(
            at: deletionMarkerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            DeletionMarker(cutoff: cutoff)
        )
        try data.write(to: deletionMarkerURL, options: .atomic)
    }

    private func deletionMarker() -> DeletionMarkerRestore {
        guard FileManager.default.fileExists(
            atPath: deletionMarkerURL.path
        ) else {
            return .missing
        }
        guard let data = Self.readData(
            at: deletionMarkerURL,
            maximumBytes: Self.maximumMarkerBytes
        ),
              let marker = try? JSONDecoder().decode(
                  DeletionMarker.self,
                  from: data
              ) else {
            return .invalid
        }
        return .valid(marker.cutoff)
    }

    private static func readData(
        at url: URL,
        maximumBytes: Int
    ) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(
            upToCount: maximumBytes + 1
        ),
        data.count <= maximumBytes else {
            return nil
        }
        return data
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(
                "com.github.thrr87.CodexLimits",
                isDirectory: true
            )
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent(
                "codex-assisted-history.json",
                isDirectory: false
            )
    }
}
