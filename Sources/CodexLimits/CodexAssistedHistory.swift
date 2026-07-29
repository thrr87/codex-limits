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

    private static let version = 1
    private let fileURL: URL
    private let deletionMarkerURL: URL
    private var file: File?

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
        loadIfNeeded()
        return file?.results.filter {
            $0.accountPartitionID == accountPartitionID
        } ?? []
    }

    func overhead(
        accountPartitionID: String
    ) -> [CodexAssistedHistoryOverhead] {
        loadIfNeeded()
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
        loadIfNeeded()
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
        loadIfNeeded()
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

    private func loadIfNeeded() {
        guard file == nil else { return }
        let deletionCutoff = deletionMarker()
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(File.self, from: data),
              decoded.version == Self.version else {
            file = File(version: Self.version, results: [], overhead: [])
            return
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

    private func deletionMarker() -> Date? {
        guard let data = try? Data(contentsOf: deletionMarkerURL),
              let marker = try? JSONDecoder().decode(
                  DeletionMarker.self,
                  from: data
              ) else {
            return nil
        }
        return marker.cutoff
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
