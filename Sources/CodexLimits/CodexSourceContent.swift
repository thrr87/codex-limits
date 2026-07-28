import CryptoKit
import Foundation

enum CodexSourceContentCategory: String, CaseIterable, Codable, Sendable {
    case prompts
    case responses
    case code
    case paths
    case commands
    case toolOutput = "tool_output"

    var displayName: String {
        switch self {
        case .prompts: "Prompts"
        case .responses: "Responses"
        case .code: "Code"
        case .paths: "Paths"
        case .commands: "Commands"
        case .toolOutput: "Tool output"
        }
    }
}

struct CodexSourceSelection: Equatable, Sendable {
    let interval: DateInterval
    let rootTaskIDs: [String]
    let taskIDs: [String]
    let projectLabel: String?
    let turnIDsByTask: [String: [String]]

    init(
        interval: DateInterval,
        rootTaskIDs: [String],
        taskIDs: [String],
        projectLabel: String?,
        turnIDsByTask: [String: [String]] = [:]
    ) {
        self.interval = interval
        self.rootTaskIDs = rootTaskIDs
        self.taskIDs = taskIDs
        self.projectLabel = projectLabel
        self.turnIDsByTask = turnIDsByTask
    }

    var fingerprint: String {
        StableIdentity(
            start: Int64(interval.start.timeIntervalSince1970),
            end: Int64(interval.end.timeIntervalSince1970),
            rootTaskIDs: rootTaskIDs.sorted(),
            taskIDs: taskIDs.sorted(),
            projectLabel: projectLabel,
            turnIDsByTask: turnIDsByTask.mapValues { $0.sorted() }
        ).fingerprint
    }

    static func make(
        reader: UsageReaderSnapshot,
        exploration: AnalyticsExplorationState
    ) -> CodexSourceSelection? {
        let metadata = CodexMetadataAnalysisPayload.make(
            reader: reader,
            exploration: exploration
        )
        guard let range = metadata.range,
              range.end > range.start else {
            return nil
        }
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(range.start)),
            end: Date(timeIntervalSince1970: TimeInterval(range.end))
        )
        let receipts = reader.usageReceipts.slice(
            in: interval,
            filters: exploration.filters
        ).receipts
        let roots = Array(Set(receipts.map(\.rootTaskID))).sorted()
        let turns = Dictionary(
            receipts.flatMap { selectedTurns(in: $0.taskTree) },
            uniquingKeysWith: { first, second in
                Array(Set(first).union(second)).sorted()
            }
        )
        let tasks = turns.keys.sorted()
        guard !roots.isEmpty, !tasks.isEmpty, tasks.count <= 20 else {
            return nil
        }
        let projects = Set(receipts.compactMap(\.projectLabel))
        return CodexSourceSelection(
            interval: interval,
            rootTaskIDs: roots,
            taskIDs: tasks,
            projectLabel: projects.count == 1 ? projects.first : nil,
            turnIDsByTask: turns
        )
    }

    private static func selectedTurns(
        in node: UsageReceiptTaskNode
    ) -> [(String, [String])] {
        let current = node.turns.isEmpty
            ? []
            : [(node.taskID, node.turns.map(\.turnID))]
        return current + node.children.flatMap(selectedTurns)
    }

    private struct StableIdentity: Codable {
        let start: Int64
        let end: Int64
        let rootTaskIDs: [String]
        let taskIDs: [String]
        let projectLabel: String?
        let turnIDsByTask: [String: [String]]

        var fingerprint: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self) else {
                return ""
            }
            return SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }
}

struct CodexSourceContentDraft: Equatable, Sendable {
    let selection: CodexSourceSelection
    let values: [CodexSourceContentCategory: [String]]

    var availableCategories: [CodexSourceContentCategory] {
        CodexSourceContentCategory.allCases.filter {
            values[$0]?.isEmpty == false
        }
    }
}

enum CodexSourceContentError: Error, Equatable {
    case emptyScope
    case scopeTooLarge
    case invalidCategories
    case invalidResponse
}

struct CodexSourceAnalysisPayload: Codable, Equatable, Sendable {
    struct Scope: Codable, Equatable, Sendable {
        let start: Int64
        let end: Int64
        let project: String?
        let taskTreeCount: Int
        let taskCount: Int
    }

    let schemaVersion: Int
    let scope: Scope
    let sourceContent: [String: [String]]

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return ""
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    init(
        draft: CodexSourceContentDraft,
        categories: Set<CodexSourceContentCategory>
    ) throws {
        let accepted = categories.intersection(draft.availableCategories)
        guard !accepted.isEmpty, accepted == categories else {
            throw CodexSourceContentError.invalidCategories
        }
        schemaVersion = 1
        scope = Scope(
            start: Self.epoch(draft.selection.interval.start),
            end: Self.epoch(draft.selection.interval.end),
            project: draft.selection.projectLabel,
            taskTreeCount: draft.selection.rootTaskIDs.count,
            taskCount: draft.selection.taskIDs.count
        )
        sourceContent = Dictionary(
            uniqueKeysWithValues: accepted.map {
                ($0.rawValue, draft.values[$0] ?? [])
            }
        )
    }

    private static func epoch(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.towardZero))
    }
}

enum CodexSourceInsightKind: String, Codable, CaseIterable, Sendable {
    case repeatedWork = "repeated_work"
    case verificationGap = "verification_gap"
    case repeatedToolSteps = "repeated_tool_steps"
    case longExchanges = "long_exchanges"
    case checksAfterChanges = "checks_after_changes"

    var title: String {
        switch self {
        case .repeatedWork: "Repeated work"
        case .verificationGap: "Verification gap"
        case .repeatedToolSteps: "Repeated tool steps"
        case .longExchanges: "Long exchanges"
        case .checksAfterChanges: "Checks followed changes"
        }
    }

    var summary: String {
        switch self {
        case .repeatedWork:
            "Codex found the same work in more than one selected item."
        case .verificationGap:
            "Codex found changes or completion claims without matching checks in the selected items."
        case .repeatedToolSteps:
            "Codex found tool or command steps that needed more than one attempt."
        case .longExchanges:
            "Codex found long or repeated exchanges that may work better as a smaller task."
        case .checksAfterChanges:
            "Codex found checks that followed changes in the selected items."
        }
    }
}

struct CodexSourceEvidenceReference: Codable, Equatable, Sendable {
    let category: CodexSourceContentCategory
    let itemNumbers: [Int]
}

struct CodexSourceInsightSelection: Codable, Equatable, Sendable {
    let sourceInsightKind: CodexSourceInsightKind
    let evidence: [CodexSourceEvidenceReference]
}

enum CodexSourceResultDecoder {
    static func decode(
        _ text: String,
        payload: CodexSourceAnalysisPayload,
        metadata: CodexMetadataAnalysisPayload
    ) throws -> CodexAssistedEvidenceEnvelope {
        let data = Data(text.utf8)
        guard let object = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
              Set(object.keys) == ["sourceInsightKind", "evidence"] else {
            throw CodexAssistedRequestError.invalidResult
        }
        let decoded = try JSONDecoder().decode(
            CodexSourceInsightSelection.self,
            from: data
        )
        guard decoded.evidence.count >= 2,
              decoded.evidence.count <= 6 else {
            throw CodexAssistedRequestError.invalidResult
        }
        var labels: [String] = []
        var seen = Set<String>()
        for reference in decoded.evidence {
            guard let values = payload.sourceContent[
                reference.category.rawValue
            ],
            !reference.itemNumbers.isEmpty,
            reference.itemNumbers.count <= 4,
            Set(reference.itemNumbers).count
                == reference.itemNumbers.count,
            reference.itemNumbers.allSatisfy({
                $0 > 0 && $0 <= values.count
            }) else {
                throw CodexAssistedRequestError.invalidResult
            }
            let key = reference.category.rawValue + ":"
                + reference.itemNumbers.sorted()
                .map(String.init)
                .joined(separator: ",")
            guard seen.insert(key).inserted else {
                throw CodexAssistedRequestError.invalidResult
            }
            let items = reference.itemNumbers.sorted()
                .map(String.init)
                .joined(separator: ", ")
            labels.append(
                "\(reference.category.displayName) · "
                    + "\(reference.itemNumbers.count == 1 ? "item" : "items") "
                    + items
            )
        }
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(
                payload.scope.start
            )),
            end: Date(timeIntervalSince1970: TimeInterval(
                payload.scope.end
            ))
        )
        guard interval.end > interval.start else {
            throw CodexAssistedRequestError.invalidResult
        }
        return CodexAssistedEvidenceEnvelope(
            title: decoded.sourceInsightKind.title,
            summary: decoded.sourceInsightKind.summary,
            evidence: labels,
            intervals: [interval],
            freshness: UsageFreshness(
                rawValue: metadata.evidence.freshness
            ) ?? .unavailable,
            coverage: .high,
            confidence: .high
        )
    }
}

protocol CodexSourceContentReading: Sendable {
    func prepare(
        selection: CodexSourceSelection
    ) async throws -> CodexSourceContentDraft
}

actor CodexSourceContentReader: CodexSourceContentReading {
    typealias Request = @Sendable (ThreadProjectionReadRequest) async throws -> Data

    private let request: Request

    init(
        request: @escaping Request = {
            try await CodexClient.shared.threadProjectionResponse(for: $0)
        }
    ) {
        self.request = request
    }

    func prepare(
        selection: CodexSourceSelection
    ) async throws -> CodexSourceContentDraft {
        let taskIDs = Array(Set(selection.taskIDs)).sorted()
        guard !taskIDs.isEmpty, taskIDs.count <= 20 else {
            throw CodexSourceContentError.emptyScope
        }
        var values: [CodexSourceContentCategory: [String]] = [:]
        var characterBudget = 12_000
        for taskID in taskIDs {
            try Task.checkCancellation()
            let data = try await request(
                .read(threadID: taskID, includeTurns: true)
            )
            let extracted = try Self.extract(
                data,
                taskID: taskID,
                interval: selection.interval,
                allowedTurnIDs: Set(
                    selection.turnIDsByTask[taskID] ?? []
                )
            )
            for category in CodexSourceContentCategory.allCases {
                for value in extracted[category] ?? [] {
                    guard value.count <= 2_000,
                          value.count <= characterBudget else {
                        throw CodexSourceContentError.scopeTooLarge
                    }
                    values[category, default: []].append(value)
                    characterBudget -= value.count
                }
            }
        }
        guard !values.isEmpty else {
            throw CodexSourceContentError.emptyScope
        }
        let draft = CodexSourceContentDraft(
            selection: selection,
            values: values
        )
        guard let payload = try? CodexSourceAnalysisPayload(
            draft: draft,
            categories: Set(draft.availableCategories)
        ), (try? CodexAssistedRequestFactory.sourceData(payload)) != nil else {
            throw CodexSourceContentError.scopeTooLarge
        }
        return draft
    }

    private static func extract(
        _ data: Data,
        taskID: String,
        interval: DateInterval,
        allowedTurnIDs: Set<String>
    ) throws -> [CodexSourceContentCategory: [String]] {
        guard let response = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let result = response["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              thread["id"] as? String == taskID,
              let turns = thread["turns"] as? [[String: Any]] else {
            throw CodexSourceContentError.invalidResponse
        }
        var values: [CodexSourceContentCategory: [String]] = [:]
        for turn in turns
        where intersects(turn, interval: interval)
            && (
                allowedTurnIDs.isEmpty
                    || (turn["id"] as? String).map(
                        allowedTurnIDs.contains
                    ) == true
            ) {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                append(item, to: &values)
            }
        }
        return values
    }

    private static func intersects(
        _ turn: [String: Any],
        interval: DateInterval
    ) -> Bool {
        guard let startValue = turn["startedAt"] as? NSNumber else {
            return false
        }
        let start = Date(timeIntervalSince1970: startValue.doubleValue)
        let end = (turn["completedAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        } ?? start
        return start < interval.end && end > interval.start
    }

    private static func append(
        _ item: [String: Any],
        to values: inout [CodexSourceContentCategory: [String]]
    ) {
        switch item["type"] as? String {
        case "userMessage":
            for input in item["content"] as? [[String: Any]] ?? [] {
                if input["type"] as? String == "text" {
                    add(input["text"], as: .prompts, to: &values)
                } else {
                    add(input["path"] ?? input["url"], as: .paths, to: &values)
                }
            }
        case "agentMessage":
            add(item["text"], as: .responses, to: &values)
        case "commandExecution":
            add(item["command"], as: .commands, to: &values)
            add(item["cwd"], as: .paths, to: &values)
            add(item["aggregatedOutput"], as: .toolOutput, to: &values)
        case "fileChange":
            for change in item["changes"] as? [[String: Any]] ?? [] {
                add(change["path"], as: .paths, to: &values)
                add(change["diff"], as: .code, to: &values)
            }
        case "mcpToolCall":
            add(item["result"], as: .toolOutput, to: &values)
            add(item["error"], as: .toolOutput, to: &values)
        case "dynamicToolCall":
            for content in item["contentItems"] as? [[String: Any]] ?? [] {
                add(content["text"], as: .toolOutput, to: &values)
            }
        case "imageView":
            add(item["path"], as: .paths, to: &values)
        case "collabAgentToolCall":
            add(item["prompt"], as: .prompts, to: &values)
        case "webSearch":
            add(item["results"], as: .toolOutput, to: &values)
        default:
            break
        }
    }

    private static func add(
        _ raw: Any?,
        as category: CodexSourceContentCategory,
        to values: inout [CodexSourceContentCategory: [String]]
    ) {
        let value: String?
        if let string = raw as? String {
            value = string
        } else if let raw,
                  JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(
                      withJSONObject: raw,
                      options: [.sortedKeys, .withoutEscapingSlashes]
                  ) {
            value = String(data: data, encoding: .utf8)
        } else {
            value = nil
        }
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return
        }
        values[category, default: []].append(value)
    }
}
