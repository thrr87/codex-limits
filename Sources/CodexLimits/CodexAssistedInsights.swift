import Combine
import CryptoKit
import Foundation

struct CodexAdvertisedModel: Equatable, Sendable {
    let id: String
    let model: String
    let hidden: Bool
    let supportedReasoningEfforts: [String]
}

struct CodexAssistedModelProfile: Equatable, Sendable {
    let id: String
    let model: String
    let reasoningEffort: String
}

enum CodexAssistedModelCatalog {
    static let modelID = "gpt-5.6-luna"

    static func selectProfile(
        from models: [CodexAdvertisedModel]
    ) -> CodexAssistedModelProfile? {
        selectProfile(from: models, preferredEfforts: ["medium"])
    }

    static func selectStrongerProfile(
        from models: [CodexAdvertisedModel]
    ) -> CodexAssistedModelProfile? {
        selectProfile(
            from: models,
            preferredEfforts: ["high", "xhigh", "max", "ultra"]
        )
    }

    private static func selectProfile(
        from models: [CodexAdvertisedModel],
        preferredEfforts: [String]
    ) -> CodexAssistedModelProfile? {
        guard let model = models.first(where: {
            !$0.hidden
                && $0.id.caseInsensitiveCompare(modelID) == .orderedSame
                && $0.model.caseInsensitiveCompare(modelID) == .orderedSame
        }) else {
            return nil
        }
        let effort = preferredEfforts.first { candidate in
            model.supportedReasoningEfforts.contains {
                $0.caseInsensitiveCompare(candidate) == .orderedSame
            }
        }
        return effort.map {
            CodexAssistedModelProfile(
                id: model.id,
                model: model.model,
                reasoningEffort: $0
            )
        }
    }
}

enum CodexMetadataEvidenceField: String, Codable, CaseIterable, Sendable {
    case usageRemaining = "usage_remaining"
    case paceGuidance = "pace_guidance"
    case accountTokenActivity = "account_token_activity"
    case localTokenActivity = "local_token_activity"
    case activity
    case usagePerToken = "usage_per_token"
    case activeTimeAvailable = "active_time_available"
}

enum CodexAssistedResponseStatus: String, Codable, Sendable {
    case insight
    case insufficientEvidence = "insufficient_evidence"
}

struct CodexAssistedNarrative: Codable, Equatable, Sendable {
    let status: CodexAssistedResponseStatus
    let title: String
    let finding: String
    let whyItMatters: String
    let recommendation: String

    var isValid: Bool {
        switch status {
        case .insight:
            return Self.isText(title, maximumLength: 80)
                && Self.isText(finding, maximumLength: 360)
                && Self.isText(whyItMatters, maximumLength: 360)
                && Self.isText(recommendation, maximumLength: 360)
                && !containsUnsupportedClaim
        case .insufficientEvidence:
            return title == "Not enough evidence"
                && Self.isText(finding, maximumLength: 360)
                && whyItMatters.isEmpty
                && recommendation.isEmpty
        }
    }

    private var containsUnsupportedClaim: Bool {
        let words = Set(
            [title, finding, whyItMatters, recommendation]
                .joined(separator: " ")
                .lowercased()
                .split { !$0.isLetter }
                .map(String.init)
        )
        return !words.isDisjoint(with: [
            "because", "billing", "caused", "causes", "cost",
            "efficiency", "efficient", "price", "pricing", "proves",
            "quality", "waste", "will"
        ])
    }

    private static func isText(
        _ text: String,
        maximumLength: Int
    ) -> Bool {
        !text.isEmpty
            && text.count <= maximumLength
            && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && text.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.decimalDigits.contains($0)
            }
    }
}

struct CodexMetadataAnalysisPayload: Codable, Equatable, Sendable {
    struct EpochRange: Codable, Equatable, Sendable {
        let start: Int64
        let end: Int64
    }

    struct UsageRemaining: Codable, Equatable, Sendable {
        let percent: Double?
        let interval: EpochRange?
    }

    struct Evidence: Codable, Equatable, Sendable {
        let freshness: String
        let coverage: String
        let confidence: String
    }

    struct AccountTokens: Codable, Equatable, Sendable {
        let tokens: Int64?
        let state: String
        let interval: EpochRange?
    }

    struct LocalTokens: Codable, Equatable, Sendable {
        let tokens: Int64?
        let coverage: String
        let interval: EpochRange?
    }

    struct Activity: Codable, Equatable, Sendable {
        let activeSeconds: Double?
        let peakConcurrentTasks: Int?
        let coverage: String
        let interval: EpochRange?
    }

    struct UsagePerToken: Codable, Equatable, Sendable {
        let multiplier: Double?
        let coverage: String
        let confidence: String
        let currentInterval: EpochRange?
        let referenceInterval: EpochRange?
    }

    struct ActiveTimeAvailable: Codable, Equatable, Sendable {
        let lowerSeconds: Double?
        let upperSeconds: Double?
        let coverage: String
        let confidence: String
        let observedInterval: EpochRange?
    }

    struct PaceGuidance: Codable, Equatable, Sendable {
        let status: String
        let expectedRemainingAtReset: Double
        let safetyRemainingAtReset: Double
        let recommendedPercentPerDay: Double
        let currentPercentPerDay: Double
        let historicalPercentPerDay: Double?
        let historicalReferenceSource: String?
        let coverage: String
        let confidence: String
    }

    struct AppliedFilters: Codable, Equatable, Sendable {
        let project: Bool
        let taskTree: Bool
        let model: Bool
        let reasoning: Bool
    }

    struct Scope: Codable, Equatable, Sendable {
        let accountMetrics: String
        let localMetrics: String
        let filtersApplied: AppliedFilters
    }

    let schemaVersion: Int
    let generatedAt: Int64
    let range: EpochRange?
    let usageRemaining: UsageRemaining
    let weeklyResetAt: Int64?
    let evidence: Evidence
    let paceGuidance: PaceGuidance?
    let accountTokenActivity: AccountTokens
    let localTokenActivity: LocalTokens
    let activity: Activity
    let usagePerToken: UsagePerToken
    let activeTimeAvailable: ActiveTimeAvailable
    let scope: Scope

    var fingerprint: String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self),
              var object = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any] else {
            return ""
        }
        object.removeValue(forKey: "generatedAt")
        guard let stableData = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else {
            return ""
        }
        return SHA256.hash(data: stableData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func make(
        reader: UsageReaderSnapshot,
        exploration: AnalyticsExplorationState,
        now: Date = Date()
    ) -> CodexMetadataAnalysisPayload {
        let deterministicInput = DeterministicInsightInput(
            reader: reader,
            exploration: exploration,
            now: now
        )
        let selectedUsage = deterministicInput.usagePerToken
        let range = deterministicInput.selectedRange ?? reader.interval.map {
            DateInterval(start: $0.startsAt, end: $0.resetsAt)
        } ?? reader.localTokenActivity.interval
        let localRange = range
        let local: LocalTokenActivitySlice
        if exploration.filters.isEmpty {
            local = reader.localTokenActivity.slice(in: localRange)
        } else {
            local = reader.usageReceipts.localTokenSlice(
                in: localRange,
                filters: exploration.filters
            )
        }
        let activity = reader.activityTimeline.slice(
            in: localRange,
            filters: exploration.filters
        )
        let estimate = reader.activeTimeAvailability.estimate
        return CodexMetadataAnalysisPayload(
            schemaVersion: 1,
            generatedAt: epoch(reader.fetchedAt ?? now),
            range: epochRange(range),
            usageRemaining: UsageRemaining(
                percent: finite(
                    reader.weeklyUsageRemaining?.window.remainingPercent
                ),
                interval: reader.weeklyUsageRemaining.map {
                    epochRange(
                        DateInterval(
                            start: $0.window.startsAt,
                            end: $0.window.resetsAt
                        )
                    )
                }
            ),
            weeklyResetAt: reader.weeklyUsageRemaining.map {
                epoch($0.window.resetsAt)
            },
            evidence: Evidence(
                freshness: reader.freshness.rawValue,
                coverage: reader.evidence.coverage.rawValue,
                confidence: reader.evidence.confidence.rawValue
            ),
            paceGuidance: reader.guidance.flatMap { guidance in
                let forecast = guidance.forecast
                let values = [
                    forecast.expectedRemainingAtReset,
                    forecast.safetyRemainingAtReset,
                    forecast.recommendedPercentPerDay,
                    forecast.currentPercentPerDay
                ]
                guard values.allSatisfy(\.isFinite),
                      forecast.historicalReference?.percentPerDay.isFinite
                        ?? true else {
                    return nil
                }
                return PaceGuidance(
                    status: forecast.status.rawValue,
                    expectedRemainingAtReset: forecast.expectedRemainingAtReset,
                    safetyRemainingAtReset: forecast.safetyRemainingAtReset,
                    recommendedPercentPerDay: forecast.recommendedPercentPerDay,
                    currentPercentPerDay: forecast.currentPercentPerDay,
                    historicalPercentPerDay: forecast
                        .historicalReference?.percentPerDay,
                    historicalReferenceSource: forecast
                        .historicalReferenceSource?.rawValue,
                    coverage: reader.evidence.coverage.rawValue,
                    confidence: reader.evidence.confidence.rawValue
                )
            },
            accountTokenActivity: AccountTokens(
                tokens: reader.accountTokenActivity.tokens,
                state: reader.accountTokenActivity.state.rawValue,
                interval: reader.accountTokenActivity.interval.map(epochRange)
            ),
            localTokenActivity: LocalTokens(
                tokens: local.tokens,
                coverage: local.coverage.rawValue,
                interval: epochRange(localRange)
            ),
            activity: Activity(
                activeSeconds: finite(activity.activeTime),
                peakConcurrentTasks: activity.maximumConcurrency,
                coverage: activity.coverage.rawValue,
                interval: epochRange(localRange)
            ),
            usagePerToken: UsagePerToken(
                multiplier: finite(
                    selectedUsage.comparison?.multiplier
                ),
                coverage: selectedUsage.current?
                    .coverage.rawValue
                    ?? CoverageLevel.unavailable.rawValue,
                confidence: selectedUsage.comparison?
                    .confidence.rawValue
                    ?? ConfidenceLevel.unavailable.rawValue,
                currentInterval: selectedUsage.current.map {
                    epochRange($0.interval)
                },
                referenceInterval: selectedUsage.comparison.map {
                    epochRange($0.baseline.interval)
                }
            ),
            activeTimeAvailable: ActiveTimeAvailable(
                lowerSeconds: finite(estimate?.lowerSeconds),
                upperSeconds: finite(estimate?.upperSeconds),
                coverage: estimate?.coverage.rawValue
                    ?? CoverageLevel.unavailable.rawValue,
                confidence: estimate?.confidence.rawValue
                    ?? ConfidenceLevel.unavailable.rawValue,
                observedInterval: reader.activeTimeAvailability
                    .observedInterval.map(epochRange)
            ),
            scope: Scope(
                accountMetrics: "account",
                localMetrics: exploration.filters.isEmpty
                    ? "all_local_activity"
                    : "selected_local_activity",
                filtersApplied: AppliedFilters(
                    project: exploration.filters.projectID != nil,
                    taskTree: exploration.filters.taskTreeID != nil,
                    model: exploration.filters.model != nil,
                    reasoning: exploration.filters.reasoning != nil
                )
            )
        )
    }

    private static func epoch(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.towardZero))
    }

    private static func epochRange(
        _ interval: DateInterval
    ) -> EpochRange {
        EpochRange(
            start: epoch(interval.start),
            end: epoch(interval.end)
        )
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

enum CodexAssistedCopy {
    static let informationTip =
        "Sends the metadata shown here to Codex using GPT-5.6 Luna with Medium reasoning. This uses your Codex allowance."
}

enum CodexAssistedRequestError: Error {
    case payloadTooLarge
    case invalidResult
}

enum CodexAssistedRequestFactory {
    static let maximumMetadataBytes = 8_192
    static let maximumSourceBytes = 65_536

    static func modelList(id: Int, cursor: String? = nil) -> [String: Any] {
        return [
            "id": id,
            "method": "model/list",
            "params": [
                "cursor": cursor as Any,
                "includeHidden": false,
                "limit": 100
            ]
        ]
    }

    static func threadStart(
        id: Int,
        profile: CodexAssistedModelProfile,
        disabledFeatureNames: [String],
        disabledMCPServerNames: [String]
    ) -> [String: Any] {
        let disabledFeatures = Dictionary(
            uniqueKeysWithValues: disabledFeatureNames.map { ($0, false) }
        )
        let disabledMCPServers = Dictionary(
            uniqueKeysWithValues: disabledMCPServerNames.map {
                ($0, ["enabled": false])
            }
        )
        return [
            "id": id,
            "method": "thread/start",
            "params": [
                "model": profile.model,
                "allowProviderModelFallback": false,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "cwd": "/private/var/empty",
                "ephemeral": true,
                "dynamicTools": [String](),
                "environments": [String](),
                "runtimeWorkspaceRoots": [String](),
                "selectedCapabilityRoots": [String](),
                "experimentalRawEvents": false,
                "baseInstructions": baseInstructions,
                "developerInstructions": developerInstructions,
                "config": [
                    "apps": [
                        "_default": [
                            "enabled": false,
                            "open_world_enabled": false,
                            "destructive_enabled": false
                        ]
                    ],
                    "features": disabledFeatures,
                    "mcp_servers": disabledMCPServers,
                    "project_doc_max_bytes": 0,
                    "tools": [
                        "experimental_request_user_input": [
                            "enabled": false
                        ],
                        "update_plan": [
                            "enabled": false
                        ]
                    ],
                    "web_search": "disabled"
                ]
            ]
        ]
    }

    static func turnStart(
        id: Int,
        threadID: String,
        profile: CodexAssistedModelProfile,
        payload: CodexMetadataAnalysisPayload
    ) throws -> [String: Any] {
        let data = try metadataData(payload)
        let metadata = String(decoding: data, as: UTF8.self)
        return turnStart(
            id: id,
            threadID: threadID,
            profile: profile,
            text: requestText(metadata: metadata),
            outputSchema: metadataOutputSchema
        )
    }

    static func sourceTurnStart(
        id: Int,
        threadID: String,
        profile: CodexAssistedModelProfile,
        payload: CodexSourceAnalysisPayload
    ) throws -> [String: Any] {
        let data = try sourceData(payload)
        let source = String(decoding: data, as: UTF8.self)
        return turnStart(
            id: id,
            threadID: threadID,
            profile: profile,
            text: """
            Analyze only this accepted, bounded Codex payload. Source Content categories and scope match the user’s preflight:
            \(source)
            """,
            outputSchema: sourceOutputSchema
        )
    }

    private static func turnStart(
        id: Int,
        threadID: String,
        profile: CodexAssistedModelProfile,
        text: String,
        outputSchema: [String: Any]
    ) -> [String: Any] {
        return [
            "id": id,
            "method": "turn/start",
            "params": [
                "threadId": threadID,
                "input": [[
                    "type": "text",
                    "text": text
                ]],
                "model": profile.model,
                "effort": profile.reasoningEffort,
                "approvalPolicy": "never",
                "sandboxPolicy": [
                    "type": "readOnly",
                    "networkAccess": false
                ],
                "environments": [String](),
                "runtimeWorkspaceRoots": [String](),
                "summary": "none",
                "outputSchema": outputSchema
            ]
        ]
    }

    static func experimentalFeatureList(
        id: Int,
        cursor: String? = nil
    ) -> [String: Any] {
        [
            "id": id,
            "method": "experimentalFeature/list",
            "params": [
                "cursor": cursor as Any,
                "limit": 100
            ]
        ]
    }

    static func configRead(id: Int) -> [String: Any] {
        [
            "id": id,
            "method": "config/read",
            "params": [
                "cwd": "/private/var/empty",
                "includeLayers": false
            ]
        ]
    }

    static func turnInterrupt(
        id: Int,
        threadID: String,
        turnID: String
    ) -> [String: Any] {
        [
            "id": id,
            "method": "turn/interrupt",
            "params": [
                "threadId": threadID,
                "turnId": turnID
            ]
        ]
    }

    static func metadataData(
        _ payload: CodexMetadataAnalysisPayload
    ) throws -> Data {
        try encode(payload, maximumBytes: maximumMetadataBytes)
    }

    static func sourceData(
        _ payload: CodexSourceAnalysisPayload
    ) throws -> Data {
        try encode(payload, maximumBytes: maximumSourceBytes)
    }

    private static func encode<T: Encodable>(
        _ payload: T,
        maximumBytes: Int
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        guard data.count <= maximumBytes else {
            throw CodexAssistedRequestError.payloadTooLarge
        }
        return data
    }

    private static let baseInstructions =
        "Analyze only the JSON supplied in the user message. Do not use tools, files, commands, network access, other tasks, or outside knowledge."

    private static let developerInstructions = """
        Return only the current output schema. For Metadata analysis, the app preflights metadata for usefulness. When pace_guidance and usage_remaining are available, return insight with exactly those two evidence fields; explain what the current pace implies, why that matters before reset, and one concrete conditional adjustment, calibrated to their confidence even when coverage is Low or Partial. Otherwise, produce a Metadata insight only when at least two available High- or Complete-coverage evidence fields support a useful relationship. Keep title, finding, whyItMatters, and recommendation free of digits and the words because, billing, caused, causes, cost, efficiency, efficient, price, pricing, proves, quality, waste, will. Do not merely restate visible values or dates in prose, invent facts, claim causality, judge task quality or efficiency, or make billing, pricing, cost, or exact per-task allowance claims. If Metadata evidence cannot support a useful conclusion, return insufficient_evidence with title \"Not enough evidence\", explain what evidence is missing in finding, and leave the other prose and references empty. For Source Content analysis, require a High-confidence pattern supported by at least two exact category and one-based item references. Never quote or reproduce Source Content.
        """

    private static func requestText(metadata: String) -> String {
        """
        Analyze this bounded Codex usage metadata. It contains no Source Content.
        Use only measured fields and derived evidence in this JSON:
        \(metadata)
        """
    }

    private static let metadataOutputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": [
            "status", "title", "finding", "whyItMatters",
            "recommendation", "evidenceFields"
        ],
        "properties": [
            "status": [
                "type": "string",
                "enum": [
                    CodexAssistedResponseStatus.insight.rawValue,
                    CodexAssistedResponseStatus.insufficientEvidence.rawValue
                ]
            ],
            "title": ["type": "string", "maxLength": 80],
            "finding": ["type": "string", "maxLength": 360],
            "whyItMatters": ["type": "string", "maxLength": 360],
            "recommendation": ["type": "string", "maxLength": 360],
            "evidenceFields": [
                "type": "array",
                "maxItems": 4,
                "items": [
                    "type": "string",
                    "enum": CodexMetadataEvidenceField.allCases
                        .map(\.rawValue)
                ]
            ]
        ]
    ]

    private static let sourceOutputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": [
            "status", "title", "finding", "whyItMatters",
            "recommendation", "evidence"
        ],
        "properties": [
            "status": [
                "type": "string",
                "enum": [
                    CodexAssistedResponseStatus.insight.rawValue,
                    CodexAssistedResponseStatus.insufficientEvidence.rawValue
                ]
            ],
            "title": ["type": "string", "maxLength": 80],
            "finding": ["type": "string", "maxLength": 360],
            "whyItMatters": ["type": "string", "maxLength": 360],
            "recommendation": ["type": "string", "maxLength": 360],
            "evidence": [
                "type": "array",
                "maxItems": 6,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["category", "itemNumbers"],
                    "properties": [
                        "category": [
                            "type": "string",
                            "enum": CodexSourceContentCategory.allCases
                                .map(\.rawValue)
                        ],
                        "itemNumbers": [
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 4,
                            "items": [
                                "type": "integer",
                                "minimum": 1
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

struct CodexAccountMovement: Codable, Equatable, Sendable {
    let startRemainingPercent: Double
    let endRemainingPercent: Double
    let resetAt: Date
}

struct CodexAnalyticsOverhead: Codable, Equatable, Sendable {
    let durationSeconds: TimeInterval
    let accountMovement: CodexAccountMovement?
}

struct CodexAssistedAnalysisResult: Codable, Equatable, Sendable {
    let title: String
    let summary: String
    let evidence: [String]
    let confidence: ConfidenceLevel
    let observedAt: Date
    let intervals: [DateInterval]
    let freshness: UsageFreshness
    let coverage: CoverageLevel
    let overhead: CodexAnalyticsOverhead

    var source: String { "Codex-assisted" }
}

enum CodexAssistedAnalysisOutcome: Equatable, Sendable {
    case succeeded(CodexAssistedAnalysisResult)
    case failed(CodexAnalyticsOverhead)
    case cancelled(CodexAnalyticsOverhead)

    var overhead: CodexAnalyticsOverhead {
        switch self {
        case let .succeeded(result): result.overhead
        case let .failed(overhead), let .cancelled(overhead): overhead
        }
    }
}

struct CodexAssistedAnalysisScope: Equatable, Sendable {
    let accountPartitionID: String?
    let payload: CodexMetadataAnalysisPayload
    let sourceSelectionFingerprint: String?
    let sourceCategories: [String]?
    let timeRange: AnalyticsTimeRange
    let visibleRange: DateInterval?
    let filters: WorkspaceFilters
    let pinnedUsageBaselineID: String?
    let pinnedUsageBaselineAccountPartitionID: String?

    init(
        exploration: AnalyticsExplorationState,
        accountPartitionID: String? = nil,
        payload: CodexMetadataAnalysisPayload
    ) {
        self.accountPartitionID = accountPartitionID
        self.payload = payload
        sourceSelectionFingerprint = nil
        sourceCategories = nil
        timeRange = exploration.timeRange
        visibleRange = exploration.visibleRange
        filters = exploration.filters
        pinnedUsageBaselineID = exploration.pinnedUsageBaselineID
        pinnedUsageBaselineAccountPartitionID =
            exploration.pinnedUsageBaselineAccountPartitionID
    }

    var fingerprint: String {
        let identity = Identity(
            analysisContractVersion: 2,
            accountPartitionID: accountPartitionID,
            currentWindowResetAt: timeRange == .currentWindow
                ? payload.weeklyResetAt
                : nil,
            sourceSelectionFingerprint: sourceSelectionFingerprint,
            sourceCategories: sourceCategories,
            timeRange: timeRange,
            visibleRange: visibleRange,
            filters: filters,
            pinnedUsageBaselineID: pinnedUsageBaselineID,
            pinnedUsageBaselineAccountPartitionID:
                pinnedUsageBaselineAccountPartitionID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(identity) else {
            return ""
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func sourceBacked(
        selection: CodexSourceSelection,
        categories: Set<CodexSourceContentCategory>
    ) -> CodexAssistedAnalysisScope {
        CodexAssistedAnalysisScope(
            accountPartitionID: accountPartitionID,
            payload: self.payload,
            sourceSelectionFingerprint: selection.fingerprint,
            sourceCategories: categories.map(\.rawValue).sorted(),
            timeRange: timeRange,
            visibleRange: visibleRange,
            filters: filters,
            pinnedUsageBaselineID: pinnedUsageBaselineID,
            pinnedUsageBaselineAccountPartitionID:
                pinnedUsageBaselineAccountPartitionID
        )
    }

    private init(
        accountPartitionID: String?,
        payload: CodexMetadataAnalysisPayload,
        sourceSelectionFingerprint: String?,
        sourceCategories: [String]?,
        timeRange: AnalyticsTimeRange,
        visibleRange: DateInterval?,
        filters: WorkspaceFilters,
        pinnedUsageBaselineID: String?,
        pinnedUsageBaselineAccountPartitionID: String?
    ) {
        self.accountPartitionID = accountPartitionID
        self.payload = payload
        self.sourceSelectionFingerprint = sourceSelectionFingerprint
        self.sourceCategories = sourceCategories
        self.timeRange = timeRange
        self.visibleRange = visibleRange
        self.filters = filters
        self.pinnedUsageBaselineID = pinnedUsageBaselineID
        self.pinnedUsageBaselineAccountPartitionID =
            pinnedUsageBaselineAccountPartitionID
    }

    private struct Identity: Codable {
        let analysisContractVersion: Int
        let accountPartitionID: String?
        let currentWindowResetAt: Int64?
        let sourceSelectionFingerprint: String?
        let sourceCategories: [String]?
        let timeRange: AnalyticsTimeRange
        let visibleRange: DateInterval?
        let filters: WorkspaceFilters
        let pinnedUsageBaselineID: String?
        let pinnedUsageBaselineAccountPartitionID: String?
    }
}

struct CodexMetadataInsightSelection: Decodable, Equatable, Sendable {
    let status: CodexAssistedResponseStatus
    let title: String
    let finding: String
    let whyItMatters: String
    let recommendation: String
    let evidenceFields: [CodexMetadataEvidenceField]

    var narrative: CodexAssistedNarrative {
        CodexAssistedNarrative(
            status: status,
            title: title,
            finding: finding,
            whyItMatters: whyItMatters,
            recommendation: recommendation
        )
    }
}

enum CodexAssistedResultDecoder {
    static func decode(
        _ text: String
    ) throws -> CodexMetadataInsightSelection {
        let data = Data(text.utf8)
        guard let object = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
              Set(object.keys) == [
                  "status", "title", "finding", "whyItMatters",
                  "recommendation", "evidenceFields"
              ] else {
            throw CodexAssistedRequestError.invalidResult
        }
        let decoded = try JSONDecoder().decode(
            CodexMetadataInsightSelection.self,
            from: data
        )
        guard decoded.narrative.isValid,
              decoded.status == .insufficientEvidence
                ? decoded.evidenceFields.isEmpty
                : (2 ... 4).contains(decoded.evidenceFields.count),
              Set(decoded.evidenceFields).count
                == decoded.evidenceFields.count else {
            throw CodexAssistedRequestError.invalidResult
        }
        return decoded
    }
}

struct CodexAssistedEvidenceEnvelope: Equatable, Sendable {
    let title: String
    let summary: String
    let evidence: [String]
    let intervals: [DateInterval]
    let freshness: UsageFreshness
    let coverage: CoverageLevel
    let confidence: ConfidenceLevel
}

enum CodexAssistedEvidenceResolver {
    private struct Item {
        let evidence: String
        let intervals: [DateInterval]
        let coverage: CoverageLevel
    }

    static func canAnalyze(
        payload: CodexMetadataAnalysisPayload
    ) -> Bool {
        guard UsageFreshness(rawValue: payload.evidence.freshness) == .fresh else {
            return false
        }
        let available = Dictionary(
            uniqueKeysWithValues: CodexMetadataEvidenceField.allCases.compactMap {
                field in item(for: field, payload: payload).map { (field, $0) }
            }
        )
        if available[.paceGuidance] != nil,
           available[.usageRemaining] != nil {
            return true
        }
        return available.values.filter {
            $0.coverage == .complete || $0.coverage == .high
        }.count >= 2
    }

    static func resolve(
        selection: CodexMetadataInsightSelection,
        payload: CodexMetadataAnalysisPayload
    ) -> CodexAssistedEvidenceEnvelope? {
        if selection.status == .insufficientEvidence {
            return CodexAssistedEvidenceEnvelope(
                title: selection.title,
                summary: selection.finding,
                evidence: [],
                intervals: [],
                freshness: UsageFreshness(
                    rawValue: payload.evidence.freshness
                ) ?? .unavailable,
                coverage: .unavailable,
                confidence: .unavailable
            )
        }
        guard UsageFreshness(rawValue: payload.evidence.freshness) == .fresh,
              selection.narrative.isValid else {
            return nil
        }
        let items = selection.evidenceFields.compactMap {
            item(for: $0, payload: payload)
        }
        let usesPaceGuidance = selection.evidenceFields.contains(.paceGuidance)
            && selection.evidenceFields.contains(.usageRemaining)
        guard items.count == selection.evidenceFields.count,
              usesPaceGuidance || items.allSatisfy({
                  $0.coverage == .complete || $0.coverage == .high
              }) else {
            return nil
        }
        let intervals = items.flatMap(\.intervals).reduce(
            into: [DateInterval]()
        ) {
            if !$0.contains($1) { $0.append($1) }
        }
        return CodexAssistedEvidenceEnvelope(
            title: selection.title,
            summary: selection.finding,
            evidence: [
                "Why it matters: \(selection.whyItMatters)",
                "Try next: \(selection.recommendation)"
            ] + items.map(\.evidence),
            intervals: intervals,
            freshness: .fresh,
            coverage: usesPaceGuidance
                ? CoverageLevel(
                    rawValue: payload.paceGuidance?.coverage ?? ""
                ) ?? .unavailable
                : items.allSatisfy({ $0.coverage == .complete })
                    ? .complete
                    : .high,
            confidence: usesPaceGuidance
                ? ConfidenceLevel(
                    rawValue: payload.paceGuidance?.confidence ?? ""
                ) ?? .unavailable
                : .high
        )
    }

    private static func item(
        for field: CodexMetadataEvidenceField,
        payload: CodexMetadataAnalysisPayload
    ) -> Item? {
        switch field {
        case .usageRemaining:
            guard let percent = payload.usageRemaining.percent,
                  let interval = dateInterval(
                      payload.usageRemaining.interval
                  ) else {
                return nil
            }
            return Item(
                evidence: "Usage remaining: \(number(percent))%.",
                intervals: [interval],
                coverage: .complete
            )
        case .paceGuidance:
            guard let guidance = payload.paceGuidance,
                  let status = PaceStatus(rawValue: guidance.status),
                  let coverage = CoverageLevel(rawValue: guidance.coverage),
                  let confidence = ConfidenceLevel(
                      rawValue: guidance.confidence
                  ),
                  coverage != .unavailable,
                  coverage != .notApplicable,
                  confidence != .unavailable,
                  let interval = dateInterval(payload.usageRemaining.interval),
                  [
                      guidance.expectedRemainingAtReset,
                      guidance.safetyRemainingAtReset,
                      guidance.recommendedPercentPerDay,
                      guidance.currentPercentPerDay
                  ].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                return nil
            }
            guard guidance.historicalPercentPerDay.map({
                $0.isFinite && $0 >= 0
            }) ?? true else {
                return nil
            }
            return Item(
                evidence: "Pace guidance: \(paceTitle(status)); current \(number(guidance.currentPercentPerDay))% per day, recommended up to \(number(guidance.recommendedPercentPerDay))% per day, expected \(number(guidance.expectedRemainingAtReset))% left at reset.",
                intervals: [interval],
                coverage: coverage
            )
        case .accountTokenActivity:
            guard payload.accountTokenActivity.state == "exact",
                  let tokens = payload.accountTokenActivity.tokens,
                  let interval = dateInterval(
                      payload.accountTokenActivity.interval
                  ) else {
                return nil
            }
            return Item(
                evidence: "Account Token Activity: \(tokens.formatted()) tokens.",
                intervals: [interval],
                coverage: .complete
            )
        case .localTokenActivity:
            guard let tokens = payload.localTokenActivity.tokens,
                  let coverage = CoverageLevel(
                      rawValue: payload.localTokenActivity.coverage
                  ),
                  let interval = dateInterval(
                      payload.localTokenActivity.interval
                  ) else {
                return nil
            }
            return Item(
                evidence: "Local Token Activity: \(tokens.formatted()) tokens.",
                intervals: [interval],
                coverage: coverage
            )
        case .activity:
            guard let activeSeconds = payload.activity.activeSeconds,
                  let coverage = CoverageLevel(
                      rawValue: payload.activity.coverage
                  ),
                  let interval = dateInterval(payload.activity.interval) else {
                return nil
            }
            let peak = payload.activity.peakConcurrentTasks.map {
                " Peak concurrent Tasks: \($0)."
            } ?? ""
            return Item(
                evidence: "Active time: \(Int(activeSeconds.rounded()).formatted()) seconds.\(peak)",
                intervals: [interval],
                coverage: coverage
            )
        case .usagePerToken:
            guard let multiplier = payload.usagePerToken.multiplier,
                  payload.usagePerToken.confidence
                    == ConfidenceLevel.high.rawValue,
                  let coverage = CoverageLevel(
                      rawValue: payload.usagePerToken.coverage
                  ),
                  let current = dateInterval(
                      payload.usagePerToken.currentInterval
                  ),
                  let reference = dateInterval(
                      payload.usagePerToken.referenceInterval
                  ) else {
                return nil
            }
            return Item(
                evidence: "Usage per token: \(number(multiplier))× the reference.",
                intervals: [current, reference],
                coverage: coverage
            )
        case .activeTimeAvailable:
            guard let lower = payload.activeTimeAvailable.lowerSeconds,
                  let upper = payload.activeTimeAvailable.upperSeconds,
                  payload.activeTimeAvailable.confidence
                    == ConfidenceLevel.high.rawValue,
                  let coverage = CoverageLevel(
                      rawValue: payload.activeTimeAvailable.coverage
                  ),
                  let interval = dateInterval(
                      payload.activeTimeAvailable.observedInterval
                  ) else {
                return nil
            }
            return Item(
                evidence: "Estimated active time available: \(Int(lower.rounded()).formatted())–\(Int(upper.rounded()).formatted()) seconds.",
                intervals: [interval],
                coverage: coverage
            )
        }
    }

    private static func paceTitle(_ status: PaceStatus) -> String {
        switch status {
        case .slowDown: "above the sustainable pace"
        case .onTrack: "on track"
        case .roomToUseMore: "below the available pace"
        }
    }

    private static func dateInterval(
        _ range: CodexMetadataAnalysisPayload.EpochRange?
    ) -> DateInterval? {
        guard let range, range.end > range.start else { return nil }
        return DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(range.start)),
            end: Date(timeIntervalSince1970: TimeInterval(range.end))
        )
    }

    private static func number(_ value: Double) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(0 ... 2))
                .locale(Locale(identifier: "en_US"))
        )
    }
}

protocol CodexAssistedInsightServicing: Sendable {
    func eligibleProfile() async throws -> CodexAssistedModelProfile?
    func eligibleStrongerProfile() async throws -> CodexAssistedModelProfile?
    func analyze(
        payload: CodexMetadataAnalysisPayload,
        profile: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome
    func analyzeSource(
        payload: CodexSourceAnalysisPayload,
        metadata: CodexMetadataAnalysisPayload,
        profile: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome
    func cancelAnalysis() async
}

extension CodexAssistedInsightServicing {
    func eligibleStrongerProfile() async throws -> CodexAssistedModelProfile? {
        nil
    }

    func analyzeSource(
        payload _: CodexSourceAnalysisPayload,
        metadata _: CodexMetadataAnalysisPayload,
        profile _: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome {
        .failed(
            CodexAnalyticsOverhead(
                durationSeconds: 0,
                accountMovement: nil
            )
        )
    }
}

enum CodexAssistedRunState: Equatable, Sendable {
    case idle
    case running
    case succeeded(CodexAssistedAnalysisResult)
    case failed(CodexAnalyticsOverhead)
    case cancelled(CodexAnalyticsOverhead)
}

@MainActor
final class CodexAssistedInsightStore: ObservableObject {
    @Published private(set) var showsAnalyzeAction = false
    @Published private(set) var runState: CodexAssistedRunState = .idle
    @Published private(set) var isCancelling = false
    @Published private(set) var sourcePreflight: CodexSourceContentDraft?
    @Published private(set) var isPreparingSource = false
    @Published private(set) var sourcePreparationError: String?

    private let service: any CodexAssistedInsightServicing
    private let sourceReader: any CodexSourceContentReading
    private let history: CodexAssistedHistory?
    private var profile: CodexAssistedModelProfile?
    private var strongerProfile: CodexAssistedModelProfile?
    private var lastSourceRequest: (
        payload: CodexSourceAnalysisPayload,
        metadata: CodexMetadataAnalysisPayload,
        scope: CodexAssistedAnalysisScope,
        selection: CodexSourceSelection
    )?
    private var didCheckAvailability = false
    private var availabilityAccountPartitionID: String?
    private var analysisTask: Task<Void, Never>?
    private var resultScope: CodexAssistedAnalysisScope?
    private var persistedResults: [CodexAssistedHistoryResult] = []
    private var deletionCancellable: AnyCancellable?
    private var storageWriteFailed = false
    private var analysisID: UUID?
    private var analysisStartedAt: Date?
    private var latestDeletionCutoff = Date.distantPast
    private var analysisUsesSource = false
    private var sourcePreparationID: UUID?
    private var sourcePreparationSelection: CodexSourceSelection?
    private var sourcePreparationTask:
        Task<CodexSourceContentDraft, Error>?

    init(
        service: any CodexAssistedInsightServicing,
        sourceReader: any CodexSourceContentReading = CodexSourceContentReader(),
        history: CodexAssistedHistory? = nil
    ) {
        self.service = service
        self.sourceReader = sourceReader
        self.history = history
        deletionCancellable = NotificationCenter.default.publisher(
            for: .codexAssistedHistoryDeleted
        )
        .sink { [weak self] notification in
            MainActor.assumeIsolated {
                self?.clearDeletedHistory(
                    cutoff: notification.userInfo?[
                        codexAssistedHistoryDeletionCutoffKey
                    ] as? Date ?? Date()
                )
            }
        }
    }

    convenience init() {
        self.init(
            service: CodexAssistedClient.shared,
            sourceReader: CodexSourceContentReader(),
            history: CodexAssistedHistory.shared
        )
    }

    var result: CodexAssistedAnalysisResult? {
        guard case let .succeeded(result) = runState else { return nil }
        return result
    }

    var isRunning: Bool {
        runState == .running
    }

    var wasCancelled: Bool {
        guard case .cancelled = runState else { return false }
        return true
    }

    var errorMessage: String? {
        guard case .failed = runState else { return nil }
        if storageWriteFailed {
            return "Codex finished, but the analysis could not be saved. Try again when you choose."
        }
        return analysisUsesSource
            ? "Codex could not analyze this selection. Try again when you choose."
            : "Codex could not analyze this metadata. Try again when you choose."
    }

    var progressText: String {
        analysisUsesSource
            ? "Codex is analyzing the selected Source Content."
            : "Codex is analyzing metadata."
    }

    var overhead: CodexAnalyticsOverhead? {
        switch runState {
        case .idle, .running:
            return nil
        case let .succeeded(result):
            return result.overhead
        case let .failed(overhead), let .cancelled(overhead):
            return overhead
        }
    }

    var showsStrongerRetry: Bool {
        guard case .failed = runState else { return false }
        return lastSourceRequest != nil
            && strongerProfile != nil
            && analysisTask == nil
    }

    var strongerRetryLabel: String? {
        strongerProfile.map {
            "Retry with Luna \($0.reasoningEffort.capitalized)"
        }
    }

    var showsCard: Bool {
        showsAnalyzeAction
            || isRunning
            || overhead != nil
            || !persistedResults.isEmpty
    }

    func showsCard(for scope: CodexAssistedAnalysisScope) -> Bool {
        showsAnalyzeAction
            || isRunning
            || overhead != nil
            || result(for: scope) != nil
    }

    func showsCard(
        for scope: CodexAssistedAnalysisScope,
        sourceSelection: CodexSourceSelection?
    ) -> Bool {
        showsAnalyzeAction
            || isRunning
            || overhead != nil
            || result(
                for: scope,
                sourceSelection: sourceSelection
            ) != nil
    }

    func result(
        for scope: CodexAssistedAnalysisScope
    ) -> CodexAssistedAnalysisResult? {
        if resultScope?.fingerprint == scope.fingerprint, let result {
            return result
        }
        return persistedResults.last {
            $0.scopeFingerprint == scope.fingerprint
        }?.result
    }

    func result(
        for scope: CodexAssistedAnalysisScope,
        sourceSelection: CodexSourceSelection?
    ) -> CodexAssistedAnalysisResult? {
        let selectionFingerprint = sourceSelection?.fingerprint
        var candidates: [CodexAssistedAnalysisResult] = []
        if let result,
           resultScope?.fingerprint == scope.fingerprint
            || (
                selectionFingerprint != nil
                    && resultScope?.sourceSelectionFingerprint
                    == selectionFingerprint
            ) {
            candidates.append(result)
        }
        candidates.append(
            contentsOf: persistedResults.compactMap {
                guard $0.scopeFingerprint == scope.fingerprint
                    || (
                        selectionFingerprint != nil
                            && $0.sourceSelectionFingerprint
                            == selectionFingerprint
                    ) else {
                    return nil
                }
                return $0.result
            }
        )
        return candidates.max {
            $0.observedAt < $1.observedAt
        }
    }

    func checkAvailability(
        accountPartitionID: String? = nil
    ) async {
        guard !didCheckAvailability
            || availabilityAccountPartitionID != accountPartitionID else {
            return
        }
        if availabilityAccountPartitionID != accountPartitionID {
            await resetForAccountChange()
        }
        availabilityAccountPartitionID = accountPartitionID
        if let accountPartitionID, let history {
            persistedResults = await history.results(
                accountPartitionID: accountPartitionID
            )
        }
        do {
            let eligible = try await service.eligibleProfile()
            try Task.checkCancellation()
            profile = eligible
            strongerProfile = eligible == nil
                ? nil
                : try? await service.eligibleStrongerProfile()
            showsAnalyzeAction = profile != nil
            didCheckAvailability = true
        } catch is CancellationError {
            profile = nil
            strongerProfile = nil
            showsAnalyzeAction = false
            didCheckAvailability = false
        } catch {
            guard !Task.isCancelled else {
                profile = nil
                strongerProfile = nil
                showsAnalyzeAction = false
                didCheckAvailability = false
                return
            }
            profile = nil
            strongerProfile = nil
            showsAnalyzeAction = false
            didCheckAvailability = true
        }
    }

    func startAnalysis(
        payload: CodexMetadataAnalysisPayload,
        scope: CodexAssistedAnalysisScope
    ) {
        guard analysisTask == nil,
              let profile,
              showsAnalyzeAction,
              CodexAssistedEvidenceResolver.canAnalyze(payload: payload) else {
            return
        }
        lastSourceRequest = nil
        analysisUsesSource = false
        start(scope: scope) { [service] in
            await service.analyze(
                payload: payload,
                profile: profile
            )
        }
    }

    func prepareSourceAnalysis(
        selection: CodexSourceSelection
    ) async {
        guard showsAnalyzeAction, !isRunning, !isPreparingSource else {
            return
        }
        lastSourceRequest = nil
        isPreparingSource = true
        let preparationID = UUID()
        sourcePreparationID = preparationID
        sourcePreparationSelection = selection
        sourcePreparationError = nil
        sourcePreflight = nil
        let preparationTask = Task { [sourceReader] in
            try await sourceReader.prepare(selection: selection)
        }
        sourcePreparationTask = preparationTask
        do {
            let draft = try await preparationTask.value
            try Task.checkCancellation()
            guard sourcePreparationID == preparationID else { return }
            sourcePreflight = draft
        } catch is CancellationError {
            guard sourcePreparationID == preparationID else { return }
            sourcePreflight = nil
        } catch {
            guard sourcePreparationID == preparationID else { return }
            sourcePreflight = nil
            sourcePreparationError =
                "Source Content is unavailable for this selection."
        }
        if sourcePreparationID == preparationID {
            sourcePreparationID = nil
            sourcePreparationSelection = nil
            sourcePreparationTask = nil
            isPreparingSource = false
        }
    }

    func cancelSourcePreflight() {
        sourcePreparationTask?.cancel()
        sourcePreparationTask = nil
        sourcePreparationID = nil
        sourcePreparationSelection = nil
        isPreparingSource = false
        sourcePreflight = nil
        sourcePreparationError = nil
    }

    func invalidateSourcePreflight(
        for selection: CodexSourceSelection?
    ) {
        guard let selection else {
            lastSourceRequest = nil
            cancelSourcePreflight()
            return
        }
        if lastSourceRequest?.selection != selection {
            lastSourceRequest = nil
        }
        if sourcePreflight?.selection == selection
            || sourcePreparationSelection == selection {
            return
        }
        cancelSourcePreflight()
    }

    @discardableResult
    func startSourceAnalysis(
        metadata: CodexMetadataAnalysisPayload,
        scope: CodexAssistedAnalysisScope,
        selection: CodexSourceSelection,
        categories: Set<CodexSourceContentCategory>
    ) async -> Bool {
        guard analysisTask == nil,
              let profile,
              showsAnalyzeAction,
              let draft = sourcePreflight,
              draft.selection == selection,
              let payload = try? CodexSourceAnalysisPayload(
                  draft: draft,
                  categories: categories
              ) else {
            return false
        }
        guard (try? await service.eligibleProfile()) == profile else {
            self.profile = nil
            strongerProfile = nil
            showsAnalyzeAction = false
            sourcePreflight = nil
            return false
        }
        guard sourcePreflight == draft,
              draft.selection == selection else {
            return false
        }
        sourcePreflight = nil
        sourcePreparationError = nil
        let sourceScope = scope.sourceBacked(
            selection: selection,
            categories: categories
        )
        lastSourceRequest = (
            payload,
            metadata,
            sourceScope,
            selection
        )
        analysisUsesSource = true
        start(
            scope: sourceScope
        ) { [service] in
            await service.analyzeSource(
                payload: payload,
                metadata: metadata,
                profile: profile
            )
        }
        return true
    }

    @discardableResult
    func retrySourceWithStrongerProfile() async -> Bool {
        guard showsStrongerRetry,
              let lastSourceRequest else {
            return false
        }
        guard (try? await service.eligibleProfile()) == profile else {
            profile = nil
            strongerProfile = nil
            showsAnalyzeAction = false
            self.lastSourceRequest = nil
            return false
        }
        guard
              let advertised = try? await service.eligibleStrongerProfile(),
              advertised == strongerProfile else {
            strongerProfile = nil
            self.lastSourceRequest = nil
            return false
        }
        guard self.lastSourceRequest?.payload.fingerprint
            == lastSourceRequest.payload.fingerprint,
              self.lastSourceRequest?.selection
            == lastSourceRequest.selection else {
            return false
        }
        analysisUsesSource = true
        start(scope: lastSourceRequest.scope) { [service] in
            await service.analyzeSource(
                payload: lastSourceRequest.payload,
                metadata: lastSourceRequest.metadata,
                profile: advertised
            )
        }
        return true
    }

    func cancelAnalysis() async {
        guard runState == .running,
              let task = analysisTask else {
            return
        }
        isCancelling = true
        task.cancel()
        await service.cancelAnalysis()
        await task.value
    }

    func waitForAnalysis() async {
        let task = analysisTask
        await task?.value
    }

    private func resetForAccountChange() async {
        resultScope = nil
        if let task = analysisTask {
            task.cancel()
            await service.cancelAnalysis()
            await task.value
        }
        analysisTask = nil
        analysisID = nil
        analysisStartedAt = nil
        profile = nil
        strongerProfile = nil
        lastSourceRequest = nil
        didCheckAvailability = false
        showsAnalyzeAction = false
        runState = .idle
        isCancelling = false
        storageWriteFailed = false
        analysisUsesSource = false
        persistedResults = []
        sourcePreflight = nil
        sourcePreparationError = nil
        isPreparingSource = false
        sourcePreparationID = nil
        sourcePreparationSelection = nil
        sourcePreparationTask?.cancel()
        sourcePreparationTask = nil
    }

    private func start(
        scope: CodexAssistedAnalysisScope,
        operation: @escaping @Sendable () async -> CodexAssistedAnalysisOutcome
    ) {
        resultScope = scope
        let currentAnalysisID = UUID()
        let startedAt = Date()
        analysisID = currentAnalysisID
        analysisStartedAt = startedAt
        storageWriteFailed = false
        isCancelling = false
        runState = .running
        analysisTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await operation()
            guard analysisID == currentAnalysisID,
                  startedAt > latestDeletionCutoff else {
                return
            }
            do {
                try await persist(outcome: outcome, scope: scope)
            } catch {
                guard resultScope == scope else { return }
                storageWriteFailed = true
                runState = .failed(outcome.overhead)
                isCancelling = false
                analysisTask = nil
                analysisID = nil
                analysisStartedAt = nil
                return
            }
            guard resultScope == scope else { return }
            switch outcome {
            case let .succeeded(result):
                runState = .succeeded(result)
                lastSourceRequest = nil
            case let .failed(overhead):
                runState = .failed(overhead)
            case let .cancelled(overhead):
                runState = .cancelled(overhead)
                lastSourceRequest = nil
            }
            isCancelling = false
            analysisTask = nil
            analysisID = nil
            analysisStartedAt = nil
        }
    }

    private func persist(
        outcome: CodexAssistedAnalysisOutcome,
        scope: CodexAssistedAnalysisScope
    ) async throws {
        guard let history,
              let accountPartitionID = scope.accountPartitionID else {
            return
        }
        let result: CodexAssistedAnalysisResult?
        let historyOutcome: CodexAssistedHistoryOverhead.Outcome
        switch outcome {
        case let .succeeded(value):
            result = value
            historyOutcome = .succeeded
        case .failed:
            result = nil
            historyOutcome = .failed
        case .cancelled:
            result = nil
            historyOutcome = .cancelled
        }
        try await history.recordAnalysis(
            result: result,
            overhead: outcome.overhead,
            outcome: historyOutcome,
            scope: scope
        )
        if result != nil {
            if availabilityAccountPartitionID == accountPartitionID {
                persistedResults = await history.results(
                    accountPartitionID: accountPartitionID
                )
            }
        }
    }

    private func clearDeletedHistory(cutoff: Date) {
        latestDeletionCutoff = max(latestDeletionCutoff, cutoff)
        cancelSourcePreflight()
        lastSourceRequest = nil
        persistedResults.removeAll {
            $0.result.observedAt <= cutoff
        }
        if !isRunning {
            resultScope = nil
            runState = .idle
            storageWriteFailed = false
        }
        guard let task = analysisTask,
              let currentAnalysisID = analysisID,
              let analysisStartedAt,
              analysisStartedAt <= cutoff else {
            return
        }
        task.cancel()
        isCancelling = true
        Task { [weak self, service] in
            await service.cancelAnalysis()
            await task.value
            guard let self,
                  analysisID == currentAnalysisID else {
                return
            }
            analysisTask = nil
            analysisID = nil
            self.analysisStartedAt = nil
            resultScope = nil
            runState = .idle
            isCancelling = false
            storageWriteFailed = false
        }
    }
}

enum CodexAssistedClientError: Error {
    case invalidResponse
    case connectionLost
    case timedOut
    case toolUseBlocked
    case analysisFailed
}

actor CodexAssistedClient: CodexAssistedInsightServicing {
    static let shared = CodexAssistedClient()

    private struct ActiveAnalysis {
        let connection: CodexAppServerConnection
        let threadID: String
        let turnID: String
    }

    private enum AnalysisPayload {
        case metadata(CodexMetadataAnalysisPayload)
        case source(CodexSourceAnalysisPayload)
    }

    private let makeConnection: @Sendable () throws -> CodexAppServerConnection
    private let timeoutNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private var nextRequestID = 1
    private var activeAnalysis: ActiveAnalysis?

    init(
        makeConnection: @escaping @Sendable () throws -> CodexAppServerConnection =
            { try CodexClient.liveIsolatedConnection() },
        timeout: TimeInterval = 180,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeConnection = makeConnection
        timeoutNanoseconds = UInt64(max(timeout, 0.001) * 1_000_000_000)
        self.now = now
    }

    func eligibleProfile() async throws -> CodexAssistedModelProfile? {
        try await eligibleProfile(
            selecting: CodexAssistedModelCatalog.selectProfile
        )
    }

    func eligibleStrongerProfile() async throws -> CodexAssistedModelProfile? {
        try await eligibleProfile(
            selecting: CodexAssistedModelCatalog.selectStrongerProfile
        )
    }

    private func eligibleProfile(
        selecting: ([CodexAdvertisedModel]) -> CodexAssistedModelProfile?
    ) async throws -> CodexAssistedModelProfile? {
        try Task.checkCancellation()
        let connection = try makeConnection()
        defer { connection.stop() }
        try await initialize(connection)

        var cursor: String?
        var models: [CodexAdvertisedModel] = []
        for _ in 0 ..< 20 {
            let response = try await request(
                CodexAssistedRequestFactory.modelList(
                    id: requestID(),
                    cursor: cursor
                ),
                on: connection
            )
            try Task.checkCancellation()
            guard let result = response["result"] as? [String: Any],
                  let page = result["data"] as? [[String: Any]] else {
                throw CodexAssistedClientError.invalidResponse
            }
            models.append(contentsOf: page.compactMap(Self.decodeModel))
            if let profile = selecting(models) {
                return try await hasRunnableAccount(on: connection)
                    ? profile
                    : nil
            }
            cursor = result["nextCursor"] as? String
            if cursor == nil {
                return nil
            }
        }
        throw CodexAssistedClientError.invalidResponse
    }

    func analyze(
        payload: CodexMetadataAnalysisPayload,
        profile: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome {
        await analyze(
            requestPayload: .metadata(payload),
            evidencePayload: payload,
            profile: profile
        )
    }

    func analyzeSource(
        payload: CodexSourceAnalysisPayload,
        metadata: CodexMetadataAnalysisPayload,
        profile: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome {
        await analyze(
            requestPayload: .source(payload),
            evidencePayload: metadata,
            profile: profile
        )
    }

    private func analyze(
        requestPayload: AnalysisPayload,
        evidencePayload: CodexMetadataAnalysisPayload,
        profile: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome {
        let startedAt = now()
        let connection: CodexAppServerConnection
        do {
            switch requestPayload {
            case let .metadata(payload):
                _ = try CodexAssistedRequestFactory.metadataData(payload)
            case let .source(payload):
                _ = try CodexAssistedRequestFactory.sourceData(payload)
            }
            connection = try makeConnection()
        } catch {
            return .failed(
                CodexAnalyticsOverhead(
                    durationSeconds: max(
                        now().timeIntervalSince(startedAt),
                        0
                    ),
                    accountMovement: nil
                )
            )
        }
        var startLimit: LimitReading?
        defer {
            activeAnalysis = nil
            connection.stop()
        }
        do {
            try await initialize(connection)
            startLimit = try? await weeklyLimit(on: connection)
            let isolation = try await isolationConfiguration(on: connection)

            let threadResponse = try await request(
                CodexAssistedRequestFactory.threadStart(
                    id: requestID(),
                    profile: profile,
                    disabledFeatureNames: isolation.featureNames,
                    disabledMCPServerNames: isolation.mcpServerNames
                ),
                on: connection
            )
            guard let threadResult =
                    threadResponse["result"] as? [String: Any],
                  threadResult["model"] as? String == profile.model,
                  let thread = threadResult["thread"] as? [String: Any],
                  let threadID = thread["id"] as? String,
                  !threadID.isEmpty,
                  let cwd = threadResult["cwd"] as? String,
                  cwd == "/private/var/empty",
                  threadResult["approvalPolicy"] as? String == "never",
                  let sandbox = threadResult["sandbox"]
                    as? [String: Any],
                  sandbox["type"] as? String == "readOnly",
                  let instructionSources =
                    threadResult["instructionSources"] as? [String],
                  instructionSources.isEmpty else {
                throw CodexAssistedClientError.invalidResponse
            }

            let turnRequest: [String: Any]
            switch requestPayload {
            case let .metadata(payload):
                turnRequest = try CodexAssistedRequestFactory.turnStart(
                    id: requestID(),
                    threadID: threadID,
                    profile: profile,
                    payload: payload
                )
            case let .source(payload):
                turnRequest = try CodexAssistedRequestFactory.sourceTurnStart(
                    id: requestID(),
                    threadID: threadID,
                    profile: profile,
                    payload: payload
                )
            }
            let turnResponse = try await request(turnRequest, on: connection)
            guard let turnResult =
                    turnResponse["result"] as? [String: Any],
                  let turn = turnResult["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String,
                  !turnID.isEmpty else {
                throw CodexAssistedClientError.invalidResponse
            }
            activeAnalysis = ActiveAnalysis(
                connection: connection,
                threadID: threadID,
                turnID: turnID
            )
            let responseText = try await readResult(
                from: connection,
                threadID: threadID,
                turnID: turnID
            )
            let evidence: CodexAssistedEvidenceEnvelope
            switch requestPayload {
            case .metadata:
                let decoded = try CodexAssistedResultDecoder.decode(
                    responseText
                )
                guard let resolved = CodexAssistedEvidenceResolver.resolve(
                    selection: decoded,
                    payload: evidencePayload
                ) else {
                    throw CodexAssistedRequestError.invalidResult
                }
                evidence = resolved
            case let .source(payload):
                evidence = try CodexSourceResultDecoder.decode(
                    responseText,
                    payload: payload,
                    metadata: evidencePayload
                )
            }
            let completedAt = now()
            let overhead = await measuredOverhead(
                on: connection,
                startedAt: startedAt,
                completedAt: completedAt,
                startLimit: startLimit
            )
            return .succeeded(
                CodexAssistedAnalysisResult(
                    title: evidence.title,
                    summary: evidence.summary,
                    evidence: evidence.evidence,
                    confidence: evidence.confidence,
                    observedAt: completedAt,
                    intervals: evidence.intervals,
                    freshness: evidence.freshness,
                    coverage: evidence.coverage,
                    overhead: overhead
                )
            )
        } catch is CancellationError {
            return .cancelled(
                await measuredOverhead(
                    on: connection,
                    startedAt: startedAt,
                    completedAt: now(),
                    startLimit: startLimit
                )
            )
        } catch {
            return .failed(
                await measuredOverhead(
                    on: connection,
                    startedAt: startedAt,
                    completedAt: now(),
                    startLimit: startLimit
                )
            )
        }
    }

    func cancelAnalysis() async {
        guard let activeAnalysis else { return }
        try? write(
            CodexAssistedRequestFactory.turnInterrupt(
                id: requestID(),
                threadID: activeAnalysis.threadID,
                turnID: activeAnalysis.turnID
            ),
            to: activeAnalysis.connection
        )
    }

    private func initialize(
        _ connection: CodexAppServerConnection
    ) async throws {
        let id = requestID()
        let response = try await request(
            [
                "id": id,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-limits",
                        "title": "Codex Limits",
                        "version": "0.1.0"
                    ],
                    "capabilities": [
                        "experimentalApi": true
                    ]
                ]
            ],
            on: connection
        )
        guard response["error"] == nil else {
            throw CodexAssistedClientError.invalidResponse
        }
        try write(
            ["method": "initialized"],
            to: connection
        )
    }

    private func weeklyLimit(
        on connection: CodexAppServerConnection
    ) async throws -> LimitReading? {
        let response = try await request(
            [
                "id": requestID(),
                "method": "account/rateLimits/read"
            ],
            on: connection
        )
        let data = try JSONSerialization.data(withJSONObject: response)
        return try CodexClient.decodeWeeklyLimit(rateLimitsResponse: data)
    }

    private func hasRunnableAccount(
        on connection: CodexAppServerConnection
    ) async throws -> Bool {
        let response = try await request(
            [
                "id": requestID(),
                "method": "account/read",
                "params": [
                    "refreshToken": false
                ]
            ],
            on: connection
        )
        guard let result = response["result"] as? [String: Any],
              let account = result["account"] as? [String: Any],
              let type = account["type"] as? String else {
            return false
        }
        return !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isolationConfiguration(
        on connection: CodexAppServerConnection
    ) async throws -> (
        featureNames: [String],
        mcpServerNames: [String]
    ) {
        var cursor: String?
        var featureNames: [String] = []
        for _ in 0 ..< 20 {
            let response = try await request(
                CodexAssistedRequestFactory.experimentalFeatureList(
                    id: requestID(),
                    cursor: cursor
                ),
                on: connection
            )
            guard let result = response["result"] as? [String: Any],
                  let page = result["data"] as? [[String: Any]] else {
                throw CodexAssistedClientError.invalidResponse
            }
            for item in page {
                guard let name = item["name"] as? String,
                      item["enabled"] is Bool else {
                    throw CodexAssistedClientError.invalidResponse
                }
                featureNames.append(name)
            }
            cursor = result["nextCursor"] as? String
            if cursor == nil { break }
        }
        guard !featureNames.isEmpty else {
            throw CodexAssistedClientError.invalidResponse
        }

        let configResponse = try await request(
            CodexAssistedRequestFactory.configRead(id: requestID()),
            on: connection
        )
        guard let result = configResponse["result"] as? [String: Any],
              let config = result["config"] as? [String: Any] else {
            throw CodexAssistedClientError.invalidResponse
        }
        let serverNames = (
            config["mcp_servers"] as? [String: Any]
        )?.keys.sorted() ?? []
        return (
            Array(Set(featureNames)).sorted(),
            serverNames
        )
    }

    private func measuredOverhead(
        on connection: CodexAppServerConnection,
        startedAt: Date,
        completedAt: Date,
        startLimit: LimitReading?
    ) async -> CodexAnalyticsOverhead {
        let endLimit = try? await weeklyLimit(on: connection)
        return CodexAnalyticsOverhead(
            durationSeconds: max(
                completedAt.timeIntervalSince(startedAt),
                0
            ),
            accountMovement: Self.accountMovement(
                from: startLimit,
                to: endLimit
            )
        )
    }

    private func request(
        _ object: [String: Any],
        on connection: CodexAppServerConnection
    ) async throws -> [String: Any] {
        guard let id = object["id"] as? Int else {
            throw CodexAssistedClientError.invalidResponse
        }
        try write(object, to: connection)
        while let response = try await nextObject(from: connection) {
            guard response["id"] as? Int == id else { continue }
            guard response["error"] == nil else {
                throw CodexAssistedClientError.invalidResponse
            }
            return response
        }
        throw CodexAssistedClientError.connectionLost
    }

    private func readResult(
        from connection: CodexAppServerConnection,
        threadID: String,
        turnID: String
    ) async throws -> String {
        var agentMessage: String?
        while let object = try await nextObject(from: connection) {
            try Task.checkCancellation()
            guard let method = object["method"] as? String,
                  let params = object["params"] as? [String: Any] else {
                continue
            }
            if method == "item/started"
                || method == "item/completed",
               params["threadId"] as? String == threadID,
               params["turnId"] as? String == turnID,
               let item = params["item"] as? [String: Any],
               let type = item["type"] as? String {
                guard Self.isAllowedAnalysisItem(type) else {
                    try? write(
                        CodexAssistedRequestFactory.turnInterrupt(
                            id: requestID(),
                            threadID: threadID,
                            turnID: turnID
                        ),
                        to: connection
                    )
                    throw CodexAssistedClientError.toolUseBlocked
                }
                if method == "item/completed",
                   type == "agentMessage" {
                    agentMessage = item["text"] as? String
                }
                continue
            }
            guard method == "turn/completed",
                  params["threadId"] as? String == threadID,
                  let turn = params["turn"] as? [String: Any],
                  turn["id"] as? String == turnID,
                  let status = turn["status"] as? String else {
                continue
            }
            if status == "interrupted" {
                throw CancellationError()
            }
            guard status == "completed",
                  let text = agentMessage
                    ?? Self.agentMessage(in: turn) else {
                throw CodexAssistedClientError.analysisFailed
            }
            return text
        }
        throw CodexAssistedClientError.connectionLost
    }

    private func nextObject(
        from connection: CodexAppServerConnection
    ) async throws -> [String: Any]? {
        try await withThrowingTaskGroup(
            of: Data?.self
        ) { group in
            group.addTask {
                await connection.readLine()
            }
            group.addTask { [timeoutNanoseconds] in
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw CodexAssistedClientError.timedOut
            }
            do {
                let data = try await group.next() ?? nil
                group.cancelAll()
                guard let data else { return nil }
                guard let object = try JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any] else {
                    throw CodexAssistedClientError.invalidResponse
                }
                return object
            } catch {
                connection.stop()
                group.cancelAll()
                throw error
            }
        }
    }

    private func write(
        _ object: [String: Any],
        to connection: CodexAppServerConnection
    ) throws {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            throw CodexAssistedClientError.invalidResponse
        }
        do {
            try connection.input.write(contentsOf: data + Data([0x0A]))
        } catch {
            throw CodexAssistedClientError.connectionLost
        }
    }

    private func requestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private static func decodeModel(
        _ object: [String: Any]
    ) -> CodexAdvertisedModel? {
        guard let id = object["id"] as? String,
              let model = object["model"] as? String,
              let hidden = object["hidden"] as? Bool,
              let options = object["supportedReasoningEfforts"]
                as? [[String: Any]] else {
            return nil
        }
        return CodexAdvertisedModel(
            id: id,
            model: model,
            hidden: hidden,
            supportedReasoningEfforts: options.compactMap {
                $0["reasoningEffort"] as? String
            }
        )
    }

    private static func isAllowedAnalysisItem(_ type: String) -> Bool {
        [
            "agentMessage",
            "plan",
            "reasoning",
            "userMessage"
        ].contains(type)
    }

    private static func agentMessage(
        in turn: [String: Any]
    ) -> String? {
        guard let items = turn["items"] as? [[String: Any]] else {
            return nil
        }
        return items.last {
            $0["type"] as? String == "agentMessage"
        }?["text"] as? String
    }

    private static func accountMovement(
        from start: LimitReading?,
        to end: LimitReading?
    ) -> CodexAccountMovement? {
        guard let start,
              let end,
              start.limitId == end.limitId,
              start.window.resetsAt == end.window.resetsAt,
              start.window.remainingPercent.isFinite,
              end.window.remainingPercent.isFinite else {
            return nil
        }
        return CodexAccountMovement(
            startRemainingPercent: start.window.remainingPercent,
            endRemainingPercent: end.window.remainingPercent,
            resetAt: end.window.resetsAt
        )
    }
}
