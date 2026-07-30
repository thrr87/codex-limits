import Foundation
import SQLite3

final class LocalActivityStore {
    struct TokenFact: Equatable, Sendable {
        let eventID: String
        let occurredAt: Date
        let numericDelta: Int64?
        let reason: String?
        let sourceGeneration: UInt64
        let taskID: String?
        let effectiveModel: String?
        let reasoning: String?

        init(
            eventID: String,
            occurredAt: Date,
            numericDelta: Int64?,
            reason: String?,
            sourceGeneration: UInt64,
            taskID: String? = nil,
            effectiveModel: String? = nil,
            reasoning: String? = nil
        ) {
            self.eventID = eventID
            self.occurredAt = occurredAt
            self.numericDelta = numericDelta
            self.reason = reason
            self.sourceGeneration = sourceGeneration
            self.taskID = taskID
            self.effectiveModel = effectiveModel
            self.reasoning = reasoning
        }
    }

    struct Source: Equatable, Sendable {
        let key: String
        let sourceGeneration: UInt64
        var cursorJSON: Data? = nil
        var normalizationJSON: Data? = nil
        var activityStart: Date? = nil
        var activityEnd: Date? = nil
        var discontinuityAt: Date? = nil
        var hasMalformedRecords = false
        var legacyDevice: UInt64? = nil
        var legacyInode: UInt64? = nil
        var legacyOffset: UInt64? = nil
        var legacySize: UInt64? = nil
        var legacyModificationDate: Date? = nil
        var pendingFactJSON: Data? = nil
    }

    enum StoreError: Swift.Error, Equatable {
        case closed
        case invalidQuery
        case invalidSource
        case sourceGenerationChanged
        case historyCutoffMismatch
        case schemaMismatch
        case tokenTotalOverflow
        case sqlite(String)
    }

    private static let schemaVersion = 2
    private static let taskTreeCTE = """
        WITH RECURSIVE task_tree(
            root_task_id, task_id, project_label, depth
        ) AS (
            SELECT task_id, task_id, project_label, 0
            FROM task_projection
            WHERE parent_task_id IS NULL
            UNION ALL
            SELECT tree.root_task_id,
                   child.task_id,
                   tree.project_label,
                   tree.depth + 1
            FROM task_projection AS child
            JOIN task_tree AS tree
              ON child.parent_task_id = tree.task_id
            WHERE tree.depth < 64
        )
        """
    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private var database: OpaquePointer?
    var testFactProgress: ((Int) -> Void)?

    init(fileURL: URL, historyCutoff: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            fileURL.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = opened.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "Could not open local activity store"
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw StoreError.sqlite(message)
        }
        database = opened
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA cache_size = -4096")
            try execute("PRAGMA mmap_size = 0")
            try execute("PRAGMA temp_store = FILE")
            try execute("PRAGMA busy_timeout = 1000")
            try execute("PRAGMA journal_size_limit = 8388608")
            try installSchema(historyCutoff: historyCutoff)
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    func append(
        _ facts: [LocalActivityFact],
        to source: Source,
        projections: [ThreadProjection] = []
    ) throws {
        guard !source.key.isEmpty else {
            throw StoreError.invalidSource
        }
        try transaction {
            let storeGeneration = try activeStoreGeneration(for: source)
                ?? createActiveSource(source)
            try upsert(projections)
            try appendFacts(
                tokenFacts(from: facts, source: source),
                to: source,
                storeGeneration: storeGeneration
            )
        }
    }

    func appendTokenFacts(
        _ facts: [TokenFact],
        to source: Source,
        projections: [ThreadProjection] = []
    ) throws {
        guard !source.key.isEmpty else {
            throw StoreError.invalidSource
        }
        try transaction {
            let storeGeneration = try activeStoreGeneration(for: source)
                ?? createActiveSource(source)
            try upsert(projections)
            try appendFacts(
                facts,
                to: source,
                storeGeneration: storeGeneration
            )
        }
    }

    @discardableResult
    func beginReplacement(for source: Source) throws -> Int64 {
        guard !source.key.isEmpty else {
            throw StoreError.invalidSource
        }
        return try transaction {
            if let resumed = try importingReplacement(matching: source) {
                return resumed.storeGeneration
            }
            let cleanup = try prepare(
                """
                DELETE FROM source
                WHERE source_key = ?1 AND is_active = 0
                """
            )
            defer { sqlite3_finalize(cleanup) }
            try bind(source.key, at: 1, to: cleanup)
            try stepDone(cleanup)
            let storeGeneration = try nextStoreGeneration(sourceKey: source.key)
            try insertSource(
                source,
                storeGeneration: storeGeneration,
                isActive: false
            )
            try update(source, storeGeneration: storeGeneration)
            return storeGeneration
        }
    }

    func resumableReplacement(
        matching source: Source
    ) throws -> (storeGeneration: Int64, source: Source)? {
        try importingReplacement(matching: source)
    }

    func hasActiveSource(matching source: Source) throws -> Bool {
        let statement = try prepare(
            """
            SELECT EXISTS(
                SELECT 1
                FROM source
                WHERE source_key = ?1
                  AND is_active = 1
                  AND source_generation = ?2
                  AND legacy_device IS ?3
                  AND legacy_inode IS ?4
                  AND legacy_size IS ?5
                  AND legacy_mtime IS ?6
                  AND pending_fact_json IS NULL
                  AND (
                      (
                          legacy_device IS NULL
                          AND legacy_inode IS NULL
                          AND legacy_offset IS NULL
                          AND legacy_size IS NULL
                          AND legacy_mtime IS NULL
                      )
                      OR (
                          legacy_device IS NOT NULL
                          AND legacy_inode IS NOT NULL
                          AND legacy_offset = legacy_size
                          AND legacy_size IS NOT NULL
                          AND legacy_mtime IS NOT NULL
                      )
                  )
            )
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.key, at: 1, to: statement)
        try bind(String(source.sourceGeneration), at: 2, to: statement)
        try bind(source.legacyDevice.map(String.init), at: 3, to: statement)
        try bind(source.legacyInode.map(String.init), at: 4, to: statement)
        try bind(source.legacySize.map(String.init), at: 5, to: statement)
        try bind(source.legacyModificationDate, at: 6, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError.sqlite(errorMessage)
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    func hasActiveSource(key: String) throws -> Bool {
        guard !key.isEmpty else { throw StoreError.invalidSource }
        let statement = try prepare(
            """
            SELECT EXISTS(
                SELECT 1 FROM source
                WHERE source_key = ?1 AND is_active = 1
            )
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError.sqlite(errorMessage)
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    func activeSource(key: String) throws -> Source? {
        guard !key.isEmpty else { throw StoreError.invalidSource }
        let statement = try prepare(
            """
            SELECT source_generation, cursor_json, normalization_json,
                   activity_start, activity_end, discontinuity_at, malformed,
                   legacy_device, legacy_inode, legacy_offset, legacy_size,
                   legacy_mtime, pending_fact_json
            FROM source
            WHERE source_key = ?1 AND is_active = 1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            guard let sourceGeneration = UInt64(
                columnString(statement, at: 0) ?? ""
            ) else {
                throw StoreError.sqlite("Stored source generation is invalid")
            }
            var source = Source(
                key: key,
                sourceGeneration: sourceGeneration
            )
            source.cursorJSON = columnData(statement, at: 1)
            source.normalizationJSON = columnData(statement, at: 2)
            source.activityStart = columnDate(statement, at: 3)
            source.activityEnd = columnDate(statement, at: 4)
            source.discontinuityAt = columnDate(statement, at: 5)
            source.hasMalformedRecords =
                sqlite3_column_int(statement, 6) != 0
            source.legacyDevice = columnUInt64(statement, at: 7)
            source.legacyInode = columnUInt64(statement, at: 8)
            source.legacyOffset = columnUInt64(statement, at: 9)
            source.legacySize = columnUInt64(statement, at: 10)
            source.legacyModificationDate = columnDate(statement, at: 11)
            source.pendingFactJSON = columnData(statement, at: 12)
            return source
        default:
            throw StoreError.sqlite(errorMessage)
        }
    }

    func appendReplacement(
        _ facts: [LocalActivityFact],
        to source: Source,
        storeGeneration: Int64,
        projections: [ThreadProjection] = []
    ) throws {
        try transaction {
            guard try isImporting(
                sourceKey: source.key,
                storeGeneration: storeGeneration,
                sourceGeneration: source.sourceGeneration
            ) else {
                throw StoreError.invalidSource
            }
            try upsert(projections)
            try appendFacts(
                tokenFacts(from: facts, source: source),
                to: source,
                storeGeneration: storeGeneration
            )
        }
    }

    func appendReplacementTokenFacts(
        _ facts: [TokenFact],
        to source: Source,
        storeGeneration: Int64,
        projections: [ThreadProjection] = []
    ) throws {
        try transaction {
            guard try isImporting(
                sourceKey: source.key,
                storeGeneration: storeGeneration,
                sourceGeneration: source.sourceGeneration
            ) else {
                throw StoreError.invalidSource
            }
            try upsert(projections)
            try appendFacts(
                facts,
                to: source,
                storeGeneration: storeGeneration
            )
        }
    }

    func activateReplacement(
        sourceKey: String,
        storeGeneration: Int64
    ) throws {
        try transaction {
            guard try isCompleteImport(
                sourceKey: sourceKey,
                storeGeneration: storeGeneration
            ) else {
                throw StoreError.invalidSource
            }
            let retire = try prepare(
                """
                UPDATE source
                SET is_active = 0
                WHERE source_key = ?1 AND is_active = 1
                """
            )
            defer { sqlite3_finalize(retire) }
            try bind(sourceKey, at: 1, to: retire)
            try stepDone(retire)
            let activate = try prepare(
                """
                UPDATE source
                SET is_active = 1
                WHERE source_key = ?1 AND store_generation = ?2
                """
            )
            defer { sqlite3_finalize(activate) }
            try bind(sourceKey, at: 1, to: activate)
            try bind(storeGeneration, at: 2, to: activate)
            try stepDone(activate)
            try rebuildCanonicalTokens(affectedBy: sourceKey)
            let cleanup = try prepare(
                """
                DELETE FROM source
                WHERE source_key = ?1 AND store_generation != ?2
                """
            )
            defer { sqlite3_finalize(cleanup) }
            try bind(sourceKey, at: 1, to: cleanup)
            try bind(storeGeneration, at: 2, to: cleanup)
            try stepDone(cleanup)
        }
    }

    func rollbackReplacement(
        sourceKey: String,
        storeGeneration: Int64
    ) throws {
        try transaction {
            let statement = try prepare(
                """
                DELETE FROM source
                WHERE source_key = ?1
                  AND store_generation = ?2
                  AND is_active = 0
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(sourceKey, at: 1, to: statement)
            try bind(storeGeneration, at: 2, to: statement)
            try stepDone(statement)
        }
    }

    func tokenActivity(
        in interval: DateInterval,
        filters: WorkspaceFilters = .all,
        observation: LocalActivityObservation,
        maximumPoints: Int = 1_000
    ) throws -> LocalTokenActivitySnapshot {
        guard let database else { throw StoreError.closed }
        try Task.checkCancellation()
        sqlite3_progress_handler(
            database,
            1_000,
            { _ in Task<Never, Never>.isCancelled ? 1 : 0 },
            nil
        )
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        guard maximumPoints > 0, interval.start < interval.end else {
            throw StoreError.invalidQuery
        }
        if case let .unavailable(reason) = observation {
            return .unavailable(reason, interval: interval)
        }
        let bucketWidth = interval.duration / Double(maximumPoints)
        let pointsSQL = Self.taskTreeCTE + """
            , filtered AS (
                SELECT event.*
                FROM canonical_token AS canonical
                JOIN token_fact AS event
                  ON event.source_id = canonical.source_id
                 AND event.event_id = canonical.event_id
                LEFT JOIN task_tree
                  ON task_tree.task_id = event.task_id
                WHERE event.occurred_at >= ?1
                  AND event.occurred_at < ?2
                  AND event.numeric_delta >= 0
                  AND (?5 IS NULL OR task_tree.project_label = ?5)
                  AND (?6 IS NULL OR task_tree.root_task_id = ?6)
                  AND (?7 IS NULL OR event.effective_model = ?7)
                  AND (?8 IS NULL OR event.reasoning = ?8)
            ),
            bucketed AS (
                SELECT MIN(
                           CAST((occurred_at - ?1) / ?3 AS INTEGER),
                           ?4
                       ) AS bucket,
                       MAX(occurred_at) AS occurred_at,
                       SUM(numeric_delta) AS delta
                FROM filtered
                GROUP BY bucket
            ),
            running AS (
                SELECT occurred_at,
                       SUM(delta) OVER (ORDER BY bucket) AS tokens
                FROM bucketed
            )
            SELECT occurred_at, tokens
            FROM running
            ORDER BY occurred_at
            """
        let statement = try prepare(pointsSQL)
        defer { sqlite3_finalize(statement) }
        try bind(interval.start.timeIntervalSince1970, at: 1, to: statement)
        try bind(interval.end.timeIntervalSince1970, at: 2, to: statement)
        try bind(bucketWidth, at: 3, to: statement)
        try bind(Int64(maximumPoints - 1), at: 4, to: statement)
        try bind(filters.projectID, at: 5, to: statement)
        try bind(filters.taskTreeID, at: 6, to: statement)
        try bind(filters.model, at: 7, to: statement)
        try bind(filters.reasoning, at: 8, to: statement)
        var points: [LocalTokenActivityPoint] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                points.append(
                    LocalTokenActivityPoint(
                        date: Date(
                            timeIntervalSince1970:
                                sqlite3_column_double(statement, 0)
                        ),
                        tokens: sqlite3_column_int64(statement, 1)
                    )
                )
            case SQLITE_DONE:
                break
            case SQLITE_INTERRUPT:
                throw CancellationError()
            default:
                let message = errorMessage
                if message.localizedCaseInsensitiveContains("overflow") {
                    throw StoreError.tokenTotalOverflow
                }
                throw StoreError.sqlite(message)
            }
            if sqlite3_data_count(statement) == 0 {
                break
            }
        }
        let hasUnboundedCounter = try scalarBool(
            Self.taskTreeCTE + """
            SELECT EXISTS(
                SELECT 1
                FROM canonical_token AS canonical
                JOIN token_fact AS event
                  ON event.source_id = canonical.source_id
                 AND event.event_id = canonical.event_id
                LEFT JOIN task_tree
                  ON task_tree.task_id = event.task_id
                WHERE event.occurred_at >= ?1
                  AND event.occurred_at < ?2
                  AND event.break_kind != 0
                  AND (
                      event.numeric_delta IS NULL
                      OR event.numeric_delta < 0
                  )
                  AND (?3 IS NULL OR task_tree.project_label = ?3)
                  AND (?4 IS NULL OR task_tree.root_task_id = ?4)
                  AND (?5 IS NULL OR event.effective_model = ?5)
                  AND (?6 IS NULL OR event.reasoning = ?6)
            )
            """,
            interval: interval,
            filters: filters
        )
        let coverage: CoverageLevel
        let reason: String?
        switch observation {
        case .continuous:
            if hasUnboundedCounter {
                coverage = .low
                reason = "Local token activity starts from an unbounded counter"
            } else if points.isEmpty {
                coverage = .notApplicable
                reason = "No local token activity was observed"
            } else {
                coverage = .high
                reason = "Only local activity on this Mac is observed"
            }
        case let .gap(_, _, message):
            coverage = .low
            reason = message
        case let .unavailable(message):
            coverage = .unavailable
            reason = message
        }
        let source: (String?, Date?) = switch observation {
        case let .continuous(version, observedAt),
             let .gap(version, observedAt, _):
            (version, observedAt)
        case .unavailable:
            (nil, nil)
        }
        try Task.checkCancellation()
        return LocalTokenActivitySnapshot(
            tokens: points.last?.tokens ?? 0,
            interval: interval,
            coverage: coverage,
            reason: reason,
            sourceVersion: source.0,
            observedAt: source.1,
            points: points,
            accountComparison: .unavailable
        )
    }

    func filterOptions(
        in interval: DateInterval
    ) throws -> UsageReceiptFilterOptions {
        guard let database else { throw StoreError.closed }
        try Task.checkCancellation()
        sqlite3_progress_handler(
            database,
            1_000,
            { _ in Task<Never, Never>.isCancelled ? 1 : 0 },
            nil
        )
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        guard interval.start < interval.end else {
            throw StoreError.invalidQuery
        }
        let statement = try prepare(
            Self.taskTreeCTE + """
            SELECT DISTINCT
                   task_tree.project_label,
                   task_tree.root_task_id,
                   event.effective_model,
                   event.reasoning
            FROM canonical_token AS canonical
            JOIN token_fact AS event
              ON event.source_id = canonical.source_id
             AND event.event_id = canonical.event_id
            LEFT JOIN task_tree ON task_tree.task_id = event.task_id
            WHERE event.occurred_at >= ?1
              AND event.occurred_at < ?2
              AND event.numeric_delta > 0
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(interval.start, at: 1, to: statement)
        try bind(interval.end, at: 2, to: statement)
        var projects = Set<String>()
        var taskTrees = Set<String>()
        var models = Set<String>()
        var reasoningLevels = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let project = columnString(statement, at: 0) {
                    projects.insert(project)
                }
                if let taskTree = columnString(statement, at: 1) {
                    taskTrees.insert(taskTree)
                }
                if let model = columnString(statement, at: 2) {
                    models.insert(model)
                }
                if let reasoning = columnString(statement, at: 3) {
                    reasoningLevels.insert(reasoning)
                }
            case SQLITE_DONE:
                return UsageReceiptFilterOptions(
                    projects: projects.sorted(),
                    taskTrees: taskTrees.sorted(),
                    models: models.sorted(),
                    reasoningLevels: reasoningLevels.sorted()
                )
            case SQLITE_INTERRUPT:
                throw CancellationError()
            default:
                throw StoreError.sqlite(errorMessage)
            }
        }
    }

    private func installSchema(historyCutoff: Date?) throws {
        let version = try scalarInt("PRAGMA user_version")
        guard version == 0 || version == Self.schemaVersion else {
            throw StoreError.schemaMismatch
        }
        if version == Self.schemaVersion {
            try validateHistoryCutoff(historyCutoff)
            return
        }
        try execute("PRAGMA auto_vacuum = INCREMENTAL")
        try transaction {
            try execute(
                """
                CREATE TABLE store_meta (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    history_cutoff REAL
                )
                """
            )
            let metadata = try prepare(
                "INSERT INTO store_meta (id, history_cutoff) VALUES (1, ?1)"
            )
            defer { sqlite3_finalize(metadata) }
            try bind(historyCutoff, at: 1, to: metadata)
            try stepDone(metadata)
            try execute(
                """
                CREATE TABLE source (
                    id INTEGER PRIMARY KEY,
                    source_key TEXT NOT NULL,
                    store_generation INTEGER NOT NULL,
                    source_generation TEXT NOT NULL,
                    is_active INTEGER NOT NULL,
                    cursor_json BLOB,
                    normalization_json BLOB,
                    activity_start REAL,
                    activity_end REAL,
                    discontinuity_at REAL,
                    malformed INTEGER NOT NULL,
                    legacy_device TEXT,
                    legacy_inode TEXT,
                    legacy_offset TEXT,
                    legacy_size TEXT,
                    legacy_mtime REAL,
                    pending_fact_json BLOB,
                    UNIQUE (source_key, store_generation)
                )
                """
            )
            try execute(
                """
                CREATE UNIQUE INDEX one_active_source
                ON source(source_key)
                WHERE is_active = 1
                """
            )
            try execute(
                """
                CREATE TABLE token_fact (
                    source_id INTEGER NOT NULL,
                    event_id TEXT NOT NULL,
                    occurred_at REAL NOT NULL,
                    numeric_delta INTEGER,
                    break_kind INTEGER NOT NULL,
                    task_id TEXT,
                    effective_model TEXT,
                    reasoning TEXT,
                    PRIMARY KEY (source_id, event_id),
                    FOREIGN KEY (source_id)
                        REFERENCES source(id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID
                """
            )
            try execute(
                """
                CREATE TABLE canonical_token (
                    event_id TEXT PRIMARY KEY,
                    source_id INTEGER NOT NULL,
                    FOREIGN KEY (source_id)
                        REFERENCES source(id)
                        ON DELETE CASCADE
                ) WITHOUT ROWID
                """
            )
            try execute(
                """
                CREATE INDEX token_fact_time
                ON token_fact(occurred_at)
                """
            )
            try execute(
                """
                CREATE TABLE task_projection (
                    task_id TEXT PRIMARY KEY,
                    parent_task_id TEXT,
                    project_label TEXT,
                    created_at REAL,
                    updated_at REAL,
                    source_kind TEXT NOT NULL
                ) WITHOUT ROWID
                """
            )
            try execute(
                """
                CREATE INDEX task_projection_parent
                ON task_projection(parent_task_id)
                """
            )
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    private func validateHistoryCutoff(_ historyCutoff: Date?) throws {
        let statement = try prepare(
            "SELECT history_cutoff FROM store_meta WHERE id = 1"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              columnDate(statement, at: 0) == historyCutoff else {
            throw StoreError.historyCutoffMismatch
        }
    }

    private func activeStoreGeneration(for source: Source) throws -> Int64? {
        let statement = try prepare(
            """
            SELECT store_generation, source_generation
            FROM source
            WHERE source_key = ?1 AND is_active = 1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.key, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            let sourceGeneration = String(
                cString: sqlite3_column_text(statement, 1)
            )
            guard sourceGeneration == String(source.sourceGeneration) else {
                throw StoreError.sourceGenerationChanged
            }
            return sqlite3_column_int64(statement, 0)
        default:
            throw StoreError.sqlite(errorMessage)
        }
    }

    private func sourceRecord(
        sourceKey: String,
        storeGeneration: Int64
    ) throws -> (id: Int64, isActive: Bool) {
        let statement = try prepare(
            """
            SELECT id, is_active
            FROM source
            WHERE source_key = ?1 AND store_generation = ?2
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(sourceKey, at: 1, to: statement)
        try bind(storeGeneration, at: 2, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_INTERRUPT {
            throw CancellationError()
        }
        guard result == SQLITE_ROW else {
            throw StoreError.invalidSource
        }
        return (
            sqlite3_column_int64(statement, 0),
            sqlite3_column_int(statement, 1) != 0
        )
    }

    private func rebuildCanonicalTokens(affectedBy sourceKey: String) throws {
        let delete = try prepare(
            """
            DELETE FROM canonical_token
            WHERE event_id IN (
                SELECT fact.event_id
                FROM token_fact AS fact
                JOIN source ON source.id = fact.source_id
                WHERE source.source_key = ?1
            )
            """
        )
        defer { sqlite3_finalize(delete) }
        try bind(sourceKey, at: 1, to: delete)
        try stepDone(delete)

        let insert = try prepare(
            """
            INSERT INTO canonical_token (event_id, source_id)
            SELECT event_id, source_id
            FROM (
                SELECT fact.event_id,
                       fact.source_id,
                       ROW_NUMBER() OVER (
                           PARTITION BY fact.event_id
                           ORDER BY source.source_key,
                                    source.store_generation
                       ) AS duplicate_order
                FROM token_fact AS fact
                JOIN source ON source.id = fact.source_id
                WHERE source.is_active = 1
                  AND fact.event_id IN (
                      SELECT affected.event_id
                      FROM token_fact AS affected
                      JOIN source AS changed
                        ON changed.id = affected.source_id
                      WHERE changed.source_key = ?1
                  )
            )
            WHERE duplicate_order = 1
            """
        )
        defer { sqlite3_finalize(insert) }
        try bind(sourceKey, at: 1, to: insert)
        try stepDone(insert)
    }

    private func createActiveSource(_ source: Source) throws -> Int64 {
        let storeGeneration = try nextStoreGeneration(sourceKey: source.key)
        try insertSource(
            source,
            storeGeneration: storeGeneration,
            isActive: true
        )
        return storeGeneration
    }

    private func insertSource(
        _ source: Source,
        storeGeneration: Int64,
        isActive: Bool
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO source (
                source_key, store_generation, source_generation,
                is_active, malformed
            ) VALUES (?1, ?2, ?3, ?4, 0)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.key, at: 1, to: statement)
        try bind(storeGeneration, at: 2, to: statement)
        try bind(String(source.sourceGeneration), at: 3, to: statement)
        try bind(isActive ? 1 : 0, at: 4, to: statement)
        try stepDone(statement)
    }

    private func isImporting(
        sourceKey: String,
        storeGeneration: Int64,
        sourceGeneration: UInt64?
    ) throws -> Bool {
        let statement = try prepare(
            """
            SELECT source_generation
            FROM source
            WHERE source_key = ?1
              AND store_generation = ?2
              AND is_active = 0
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(sourceKey, at: 1, to: statement)
        try bind(storeGeneration, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        guard let sourceGeneration else { return true }
        return String(cString: sqlite3_column_text(statement, 0))
            == String(sourceGeneration)
    }

    private func isCompleteImport(
        sourceKey: String,
        storeGeneration: Int64
    ) throws -> Bool {
        let statement = try prepare(
            """
            SELECT EXISTS(
                SELECT 1
                FROM source
                WHERE source_key = ?1
                  AND store_generation = ?2
                  AND is_active = 0
                  AND pending_fact_json IS NULL
                  AND (
                      (
                          legacy_device IS NULL
                          AND legacy_inode IS NULL
                          AND legacy_offset IS NULL
                          AND legacy_size IS NULL
                          AND legacy_mtime IS NULL
                      )
                      OR (
                          legacy_device IS NOT NULL
                          AND legacy_inode IS NOT NULL
                          AND legacy_offset = legacy_size
                          AND legacy_size IS NOT NULL
                          AND legacy_mtime IS NOT NULL
                      )
                  )
            )
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(sourceKey, at: 1, to: statement)
        try bind(storeGeneration, at: 2, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_INTERRUPT {
            throw CancellationError()
        }
        guard result == SQLITE_ROW else {
            throw StoreError.sqlite(errorMessage)
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    private func importingReplacement(
        matching source: Source
    ) throws -> (storeGeneration: Int64, source: Source)? {
        let statement = try prepare(
            """
            SELECT store_generation, source_generation,
                   cursor_json, normalization_json,
                   activity_start, activity_end, discontinuity_at, malformed,
                   legacy_device, legacy_inode, legacy_offset, legacy_size,
                   legacy_mtime, pending_fact_json
            FROM source
            WHERE source_key = ?1
              AND is_active = 0
              AND source_generation = ?2
              AND legacy_device IS ?3
              AND legacy_inode IS ?4
              AND legacy_size IS ?5
              AND legacy_mtime IS ?6
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.key, at: 1, to: statement)
        try bind(String(source.sourceGeneration), at: 2, to: statement)
        try bind(source.legacyDevice.map(String.init), at: 3, to: statement)
        try bind(source.legacyInode.map(String.init), at: 4, to: statement)
        try bind(source.legacySize.map(String.init), at: 5, to: statement)
        try bind(source.legacyModificationDate, at: 6, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let storeGeneration = sqlite3_column_int64(statement, 0)
        guard let sourceGeneration = UInt64(columnString(statement, at: 1) ?? "")
        else {
            throw StoreError.sqlite("Stored source generation is invalid")
        }
        var restored = Source(
            key: source.key,
            sourceGeneration: sourceGeneration
        )
        restored.cursorJSON = columnData(statement, at: 2)
        restored.normalizationJSON = columnData(statement, at: 3)
        restored.activityStart = columnDate(statement, at: 4)
        restored.activityEnd = columnDate(statement, at: 5)
        restored.discontinuityAt = columnDate(statement, at: 6)
        restored.hasMalformedRecords = sqlite3_column_int(statement, 7) != 0
        restored.legacyDevice = columnUInt64(statement, at: 8)
        restored.legacyInode = columnUInt64(statement, at: 9)
        restored.legacyOffset = columnUInt64(statement, at: 10)
        restored.legacySize = columnUInt64(statement, at: 11)
        restored.legacyModificationDate = columnDate(statement, at: 12)
        restored.pendingFactJSON = columnData(statement, at: 13)
        return (storeGeneration, restored)
    }

    private func upsert(_ projections: [ThreadProjection]) throws {
        guard !projections.isEmpty else { return }
        let statement = try prepare(
            """
            INSERT INTO task_projection (
                task_id, parent_task_id, project_label,
                created_at, updated_at, source_kind
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(task_id) DO UPDATE SET
                parent_task_id = excluded.parent_task_id,
                project_label = excluded.project_label,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                source_kind = excluded.source_kind
            WHERE COALESCE(
                      excluded.updated_at,
                      excluded.created_at,
                      0
                  ) >= COALESCE(
                      task_projection.updated_at,
                      task_projection.created_at,
                      0
                  )
            """
        )
        defer { sqlite3_finalize(statement) }
        for projection in projections {
            guard !projection.taskID.isEmpty else { continue }
            try reset(statement)
            try bind(projection.taskID, at: 1, to: statement)
            try bind(projection.parentTaskID, at: 2, to: statement)
            try bind(projection.projectLabel, at: 3, to: statement)
            try bind(projection.createdAt, at: 4, to: statement)
            try bind(projection.updatedAt, at: 5, to: statement)
            try bind(projection.source.source.rawValue, at: 6, to: statement)
            try stepDone(statement)
        }
    }

    private func appendFacts(
        _ facts: [TokenFact],
        to source: Source,
        storeGeneration: Int64
    ) throws {
        try update(source, storeGeneration: storeGeneration)
        let sourceRecord = try sourceRecord(
            sourceKey: source.key,
            storeGeneration: storeGeneration
        )
        let factStatement = try prepare(
            """
            INSERT OR IGNORE INTO token_fact (
                source_id, event_id, occurred_at, numeric_delta, break_kind,
                task_id, effective_model, reasoning
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8
            )
            """
        )
        defer { sqlite3_finalize(factStatement) }
        let canonicalStatement = sourceRecord.isActive
            ? try prepare(
                """
                INSERT INTO canonical_token (event_id, source_id)
                VALUES (?1, ?2)
                ON CONFLICT(event_id) DO UPDATE SET
                    source_id = excluded.source_id
                WHERE (
                    SELECT candidate.source_key < current.source_key
                        OR (
                            candidate.source_key = current.source_key
                            AND candidate.store_generation
                                < current.store_generation
                        )
                    FROM source AS candidate, source AS current
                    WHERE candidate.id = excluded.source_id
                      AND current.id = canonical_token.source_id
                )
                """
            )
            : nil
        defer { sqlite3_finalize(canonicalStatement) }
        for (index, fact) in facts.enumerated() {
            if index.isMultiple(of: 256) {
                try Task.checkCancellation()
                testFactProgress?(index)
            }
            guard fact.sourceGeneration == source.sourceGeneration else {
                throw StoreError.sourceGenerationChanged
            }
            try insertTokenFact(
                fact,
                sourceID: sourceRecord.id,
                statement: factStatement
            )
            guard sqlite3_changes(database) > 0,
                  let canonicalStatement else {
                continue
            }
            try upsertCanonicalToken(
                fact,
                sourceID: sourceRecord.id,
                statement: canonicalStatement
            )
        }
    }

    private func tokenFacts(
        from facts: [LocalActivityFact],
        source: Source
    ) throws -> [TokenFact] {
        let timestampParser = LocalEventTimestampParser()
        var tokens: [TokenFact] = []
        tokens.reserveCapacity(facts.count)
        for fact in facts {
            guard fact.source.sourceGeneration == source.sourceGeneration
            else {
                throw StoreError.sourceGenerationChanged
            }
            guard fact.key == .token,
                  fact.availability == .available,
                  let eventID = fact.eventID,
                  !eventID.isEmpty,
                  let timestamp = fact.eventTimestamp,
                  let occurredAt = timestampParser.date(from: timestamp) else {
                continue
            }
            tokens.append(
                TokenFact(
                    eventID: eventID,
                    occurredAt: occurredAt,
                    numericDelta: fact.numericDelta,
                    reason: fact.reason,
                    sourceGeneration: fact.source.sourceGeneration,
                    taskID: fact.context?.taskID,
                    effectiveModel: fact.context?.effectiveModel,
                    reasoning: fact.context?.reasoning
                )
            )
        }
        return tokens
    }

    private func update(
        _ source: Source,
        storeGeneration: Int64
    ) throws {
        let statement = try prepare(
            """
            UPDATE source
            SET cursor_json = ?3,
                normalization_json = ?4,
                activity_start = ?5,
                activity_end = ?6,
                discontinuity_at = ?7,
                malformed = ?8,
                legacy_device = ?9,
                legacy_inode = ?10,
                legacy_offset = ?11,
                legacy_size = ?12,
                legacy_mtime = ?13,
                pending_fact_json = ?14
            WHERE source_key = ?1 AND store_generation = ?2
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.key, at: 1, to: statement)
        try bind(storeGeneration, at: 2, to: statement)
        try bind(source.cursorJSON, at: 3, to: statement)
        try bind(source.normalizationJSON, at: 4, to: statement)
        try bind(source.activityStart, at: 5, to: statement)
        try bind(source.activityEnd, at: 6, to: statement)
        try bind(source.discontinuityAt, at: 7, to: statement)
        try bind(source.hasMalformedRecords ? 1 : 0, at: 8, to: statement)
        try bind(source.legacyDevice.map(String.init), at: 9, to: statement)
        try bind(source.legacyInode.map(String.init), at: 10, to: statement)
        try bind(source.legacyOffset.map(String.init), at: 11, to: statement)
        try bind(source.legacySize.map(String.init), at: 12, to: statement)
        try bind(source.legacyModificationDate, at: 13, to: statement)
        try bind(source.pendingFactJSON, at: 14, to: statement)
        try stepDone(statement)
    }

    private func nextStoreGeneration(sourceKey: String) throws -> Int64 {
        let statement = try prepare(
            """
            SELECT COALESCE(MAX(store_generation), 0) + 1
            FROM source WHERE source_key = ?1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(sourceKey, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_INTERRUPT {
            throw CancellationError()
        }
        guard result == SQLITE_ROW else {
            throw StoreError.sqlite(errorMessage)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func insertTokenFact(
        _ fact: TokenFact,
        sourceID: Int64,
        statement: OpaquePointer
    ) throws {
        try reset(statement)
        try bind(sourceID, at: 1, to: statement)
        try bind(fact.eventID, at: 2, to: statement)
        try bind(fact.occurredAt, at: 3, to: statement)
        try bind(fact.numericDelta, at: 4, to: statement)
        try bind(breakKind(fact.reason), at: 5, to: statement)
        try bindTokenDetails(fact, to: statement)
        try stepDone(statement)
    }

    private func upsertCanonicalToken(
        _ fact: TokenFact,
        sourceID: Int64,
        statement: OpaquePointer
    ) throws {
        try reset(statement)
        try bind(fact.eventID, at: 1, to: statement)
        try bind(sourceID, at: 2, to: statement)
        try stepDone(statement)
    }

    private func bindTokenDetails(
        _ fact: TokenFact,
        to statement: OpaquePointer
    ) throws {
        try bind(fact.taskID, at: 6, to: statement)
        try bind(fact.effectiveModel, at: 7, to: statement)
        try bind(fact.reasoning, at: 8, to: statement)
    }

    private func breakKind(_ reason: String?) -> Int64 {
        switch reason {
        case "segment-baseline":
            1
        case "source-discontinuity":
            2
        case "cumulative-counter-decreased":
            3
        default:
            0
        }
    }

    private func reset(_ statement: OpaquePointer) throws {
        guard sqlite3_reset(statement) == SQLITE_OK,
              sqlite3_clear_bindings(statement) == SQLITE_OK else {
            throw StoreError.sqlite(errorMessage)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError.sqlite(errorMessage)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func columnString(
        _ statement: OpaquePointer,
        at index: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func columnUInt64(
        _ statement: OpaquePointer,
        at index: Int32
    ) -> UInt64? {
        columnString(statement, at: index).flatMap(UInt64.init)
    }

    private func columnDate(
        _ statement: OpaquePointer,
        at index: Int32
    ) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func columnData(
        _ statement: OpaquePointer,
        at index: Int32
    ) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    private func scalarBool(
        _ sql: String,
        interval: DateInterval,
        filters: WorkspaceFilters = .all
    ) throws -> Bool {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(interval.start.timeIntervalSince1970, at: 1, to: statement)
        try bind(interval.end.timeIntervalSince1970, at: 2, to: statement)
        try bind(filters.projectID, at: 3, to: statement)
        try bind(filters.taskTreeID, at: 4, to: statement)
        try bind(filters.model, at: 5, to: statement)
        try bind(filters.reasoning, at: 6, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_INTERRUPT {
            throw CancellationError()
        }
        guard result == SQLITE_ROW else {
            throw StoreError.sqlite(errorMessage)
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    private func transaction<Value>(
        _ body: () throws -> Value
    ) throws -> Value {
        guard let database else { throw StoreError.closed }
        try Task.checkCancellation()
        sqlite3_progress_handler(
            database,
            1_000,
            { _ in Task<Never, Never>.isCancelled ? 1 : 0 },
            nil
        )
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try Task.checkCancellation()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw StoreError.closed }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(message)
            throw StoreError.sqlite(text)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw StoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.sqlite(errorMessage)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        if result == SQLITE_INTERRUPT {
            throw CancellationError()
        }
        guard result == SQLITE_DONE else {
            throw StoreError.sqlite(errorMessage)
        }
    }

    private func bind(
        _ value: String?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let result = if let value {
            sqlite3_bind_text(
                statement,
                index,
                value,
                -1,
                Self.transient
            )
        } else {
            sqlite3_bind_null(statement, index)
        }
        try checkBinding(result)
    }

    private func bind(
        _ value: Data?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let result = if let value {
            value.withUnsafeBytes {
                sqlite3_bind_blob(
                    statement,
                    index,
                    $0.baseAddress,
                    Int32(value.count),
                    Self.transient
                )
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
        try checkBinding(result)
    }

    private func bind(
        _ value: Date?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        if let value {
            try bind(value.timeIntervalSince1970, at: index, to: statement)
        } else {
            try checkBinding(sqlite3_bind_null(statement, index))
        }
    }

    private func bind(
        _ value: Double,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        try checkBinding(sqlite3_bind_double(statement, index, value))
    }

    private func bind(
        _ value: Int?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        if let value {
            try bind(Int64(value), at: index, to: statement)
        } else {
            try checkBinding(sqlite3_bind_null(statement, index))
        }
    }

    private func bind(
        _ value: Int64?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        if let value {
            try checkBinding(sqlite3_bind_int64(statement, index, value))
        } else {
            try checkBinding(sqlite3_bind_null(statement, index))
        }
    }

    private func checkBinding(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw StoreError.sqlite(errorMessage)
        }
    }

    private var errorMessage: String {
        guard let database else { return "Local activity store is closed" }
        return String(cString: sqlite3_errmsg(database))
    }
}
