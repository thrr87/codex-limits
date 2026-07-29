import Foundation
import SwiftUI
import XCTest
@testable import CodexLimits

@MainActor
final class CodexSourceAnalysisTests: XCTestCase {
    func testCatalogSelectsTheNearestExplicitlyAdvertisedStrongerProfile() {
        let selected = CodexAssistedModelCatalog.selectStrongerProfile(
            from: [
                CodexAdvertisedModel(
                    id: "gpt-5.6-luna",
                    model: "gpt-5.6-luna",
                    hidden: false,
                    supportedReasoningEfforts: [
                        "medium",
                        "high",
                        "xhigh"
                    ]
                )
            ]
        )

        XCTAssertEqual(
            selected,
            CodexAssistedModelProfile(
                id: "gpt-5.6-luna",
                model: "gpt-5.6-luna",
                reasoningEffort: "high"
            )
        )
    }

    func testReaderReturnsOnlyPresentCategoriesFromTheSelectedTaskAndRange() async throws {
        let recorder = SourceRequestRecorder()
        let reader = CodexSourceContentReader { request in
            try await recorder.response(for: request)
        }
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        let draft = try await reader.prepare(
            selection: CodexSourceSelection(
                interval: interval,
                rootTaskIDs: ["root-task"],
                taskIDs: ["child-task"],
                projectLabel: "atlas",
                turnIDsByTask: ["child-task": ["selected"]]
            )
        )

        let requests = await recorder.snapshot()
        XCTAssertEqual(
            requests,
            [.read(threadID: "child-task", includeTurns: true)]
        )
        XCTAssertEqual(
            draft.availableCategories,
            [.prompts, .responses, .code, .paths, .commands, .toolOutput]
        )
        XCTAssertEqual(draft.values[.prompts], ["Build the report"])
        XCTAssertEqual(draft.values[.responses], ["Done"])
        XCTAssertEqual(draft.values[.code], ["+let answer = 42"])
        XCTAssertEqual(
            draft.values[.paths],
            ["/synthetic/atlas", "/synthetic/atlas/App.swift"]
        )
        XCTAssertEqual(draft.values[.commands], ["swift test"])
        XCTAssertEqual(draft.values[.toolOutput], ["All tests passed"])
        XCTAssertFalse(draft.values.values.flatMap { $0 }.contains("Too old"))
        XCTAssertFalse(
            draft.values.values.flatMap { $0 }.contains("Other model")
        )
    }

    func testAcceptedCategoriesProduceTheExactBoundedPayload() throws {
        let selection = CodexSourceSelection(
            interval: DateInterval(
                start: Date(timeIntervalSince1970: 1_000),
                end: Date(timeIntervalSince1970: 2_000)
            ),
            rootTaskIDs: ["root-task"],
            taskIDs: ["root-task", "child-task"],
            projectLabel: "atlas"
        )
        let draft = CodexSourceContentDraft(
            selection: selection,
            values: [
                .prompts: ["Build the report"],
                .responses: ["Done"],
                .code: ["+let answer = 42"],
                .paths: ["/synthetic/atlas/App.swift"]
            ]
        )

        let payload = try CodexSourceAnalysisPayload(
            draft: draft,
            categories: [.prompts, .code]
        )
        let data = try CodexAssistedRequestFactory.sourceData(payload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let content = try XCTUnwrap(
            object["sourceContent"] as? [String: [String]]
        )
        let scope = try XCTUnwrap(object["scope"] as? [String: Any])

        XCTAssertEqual(Set(content.keys), ["prompts", "code"])
        XCTAssertEqual(content["prompts"], ["Build the report"])
        XCTAssertEqual(content["code"], ["+let answer = 42"])
        XCTAssertEqual(scope["project"] as? String, "atlas")
        XCTAssertEqual(scope["taskTreeCount"] as? Int, 1)
        XCTAssertEqual(scope["taskCount"] as? Int, 2)
        XCTAssertNil(object["metadata"])
        XCTAssertNil(scope["rootTaskIDs"])
        XCTAssertNil(scope["taskIDs"])
        XCTAssertLessThanOrEqual(data.count, 65_536)
    }

    func testSourceScopeDoesNotReplaceMetadataOrHashSourceContent() {
        let metadataScope = analysisScope()
        let firstSourceScope = metadataScope.sourceBacked(
            selection: sourceSelection(),
            categories: [.prompts]
        )
        let secondSourceScope = metadataScope.sourceBacked(
            selection: sourceSelection(),
            categories: [.prompts]
        )

        XCTAssertNotEqual(firstSourceScope.fingerprint, metadataScope.fingerprint)
        XCTAssertEqual(
            firstSourceScope.fingerprint,
            secondSourceScope.fingerprint
        )
        XCTAssertEqual(
            firstSourceScope.sourceSelectionFingerprint,
            sourceSelection().fingerprint
        )
    }

    func testSourceResultUsesOnlyValidatedReferencesAndDerivedCopy() throws {
        let draft = CodexSourceContentDraft(
            selection: sourceSelection(),
            values: [
                .prompts: ["Private prompt", "Follow-up"],
                .commands: ["swift test"]
            ]
        )
        let payload = try CodexSourceAnalysisPayload(
            draft: draft,
            categories: [.prompts, .commands]
        )

        let result = try CodexSourceResultDecoder.decode(
            """
            {
              "sourceInsightKind":"repeated_work",
              "evidence":[
                {"category":"prompts","itemNumbers":[1,2]},
                {"category":"commands","itemNumbers":[1]}
              ]
            }
            """,
            payload: payload,
            metadata: metadataPayload()
        )

        XCTAssertEqual(result.title, "Repeated work")
        XCTAssertEqual(
            result.evidence,
            ["Prompts · items 1, 2", "Commands · item 1"]
        )
        XCTAssertEqual(result.confidence, .high)
        XCTAssertFalse(result.summary.contains("Private prompt"))
        XCTAssertFalse(result.evidence.joined().contains("swift test"))
    }

    func testSourceResultRejectsMissingOrOutOfRangeEvidence() throws {
        let payload = try CodexSourceAnalysisPayload(
            draft: CodexSourceContentDraft(
                selection: sourceSelection(),
                values: [.prompts: ["Only item"]]
            ),
            categories: [.prompts]
        )

        XCTAssertThrowsError(
            try CodexSourceResultDecoder.decode(
                """
                {
                  "sourceInsightKind":"repeated_work",
                  "evidence":[
                    {"category":"prompts","itemNumbers":[1]},
                    {"category":"prompts","itemNumbers":[2]}
                  ]
                }
                """,
                payload: payload,
                metadata: metadataPayload()
            )
        )
    }

    func testEmptyScopeReadsNothing() async {
        let recorder = SourceRequestRecorder()
        let reader = CodexSourceContentReader { request in
            try await recorder.response(for: request)
        }

        do {
            _ = try await reader.prepare(
                selection: CodexSourceSelection(
                    interval: DateInterval(
                        start: Date(timeIntervalSince1970: 1_000),
                        end: Date(timeIntervalSince1970: 2_000)
                    ),
                    rootTaskIDs: [],
                    taskIDs: [],
                    projectLabel: nil
                )
            )
            XCTFail("Expected an empty scope error")
        } catch {
            XCTAssertEqual(error as? CodexSourceContentError, .emptyScope)
        }
        let requests = await recorder.snapshot()
        XCTAssertEqual(requests, [])
    }

    func testOversizedSourceFailsInsteadOfSendingPartialCoverage() async {
        let oversized = String(repeating: "a", count: 2_001)
        let reader = CodexSourceContentReader { request in
            let taskID: String
            switch request {
            case let .read(threadID, _):
                taskID = threadID
            default:
                throw CodexSourceContentError.invalidResponse
            }
            return try JSONSerialization.data(
                withJSONObject: [
                    "result": [
                        "thread": [
                            "id": taskID,
                            "turns": [[
                                "id": "turn",
                                "startedAt": 1_100,
                                "completedAt": 1_200,
                                "items": [[
                                    "type": "userMessage",
                                    "content": [[
                                        "type": "text",
                                        "text": oversized
                                    ]]
                                ]]
                            ]]
                        ]
                    ]
                ]
            )
        }

        do {
            _ = try await reader.prepare(selection: sourceSelection())
            XCTFail("Expected the source scope to be withheld")
        } catch {
            XCTAssertEqual(
                error as? CodexSourceContentError,
                .scopeTooLarge
            )
        }
    }

    func testExactCharacterBudgetDoesNotSkipLaterSourceItems() async {
        let item = String(repeating: "a", count: 2_000)
        let content = (0 ..< 7).map { index in
            [
                "type": "text",
                "text": index == 6 ? "b" : item
            ]
        }
        let reader = CodexSourceContentReader { request in
            let taskID: String
            switch request {
            case let .read(threadID, _):
                taskID = threadID
            default:
                throw CodexSourceContentError.invalidResponse
            }
            return try JSONSerialization.data(
                withJSONObject: [
                    "result": [
                        "thread": [
                            "id": taskID,
                            "turns": [[
                                "id": "turn",
                                "startedAt": 1_100,
                                "completedAt": 1_200,
                                "items": [[
                                    "type": "userMessage",
                                    "content": content
                                ]]
                            ]]
                        ]
                    ]
                ]
            )
        }

        do {
            _ = try await reader.prepare(selection: sourceSelection())
            XCTFail("Expected the complete source scope to be withheld")
        } catch {
            XCTAssertEqual(
                error as? CodexSourceContentError,
                .scopeTooLarge
            )
        }
    }

    func testPreflightCancelSendsNothingAndAcceptSendsExactPayload() async throws {
        let selection = sourceSelection()
        let draft = CodexSourceContentDraft(
            selection: selection,
            values: [
                .prompts: ["Build the report"],
                .responses: ["Done"]
            ]
        )
        let reader = SourceReaderFixture(result: .success(draft))
        let service = SourceAnalysisServiceFixture()
        let store = CodexAssistedInsightStore(
            service: service,
            sourceReader: reader
        )
        await store.checkAvailability()

        await store.prepareSourceAnalysis(selection: selection)
        XCTAssertNotNil(store.sourcePreflight)
        let callsBeforeCancel = await service.sourceCalls()
        XCTAssertEqual(callsBeforeCancel, [])

        store.cancelSourcePreflight()
        XCTAssertNil(store.sourcePreflight)
        let callsAfterCancel = await service.sourceCalls()
        XCTAssertEqual(callsAfterCancel, [])

        await store.prepareSourceAnalysis(selection: selection)
        let started = await store.startSourceAnalysis(
            metadata: metadataPayload(),
            scope: analysisScope(),
            selection: selection,
            categories: [.prompts]
        )
        XCTAssertTrue(started)
        await store.waitForAnalysis()

        let calls = await service.sourceCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls.first?.payload.sourceContent,
            ["prompts": ["Build the report"]]
        )
        XCTAssertEqual(calls.first?.profile.reasoningEffort, "medium")
    }

    func testChangedScopeInvalidatesThePreparedSourceContent() async {
        let selection = sourceSelection()
        let reader = SourceReaderFixture(
            result: .success(
                CodexSourceContentDraft(
                    selection: selection,
                    values: [.prompts: ["Build the report"]]
                )
            )
        )
        let store = CodexAssistedInsightStore(
            service: SourceAnalysisServiceFixture(),
            sourceReader: reader
        )
        await store.checkAvailability()
        await store.prepareSourceAnalysis(selection: selection)

        store.invalidateSourcePreflight(
            for: CodexSourceSelection(
                interval: DateInterval(
                    start: selection.interval.start,
                    end: selection.interval.end.addingTimeInterval(60)
                ),
                rootTaskIDs: selection.rootTaskIDs,
                taskIDs: selection.taskIDs,
                projectLabel: selection.projectLabel
            )
        )

        XCTAssertNil(store.sourcePreflight)
    }

    func testChangedScopeWhileReadingCannotPublishAStalePreflight() async {
        let selection = sourceSelection()
        let reader = DelayedSourceReaderFixture(
            draft: CodexSourceContentDraft(
                selection: selection,
                values: [.prompts: ["Build the report"]]
            )
        )
        let store = CodexAssistedInsightStore(
            service: SourceAnalysisServiceFixture(),
            sourceReader: reader
        )
        await store.checkAvailability()

        let preparation = Task {
            await store.prepareSourceAnalysis(selection: selection)
        }
        await Task.yield()
        store.invalidateSourcePreflight(
            for: CodexSourceSelection(
                interval: DateInterval(
                    start: selection.interval.start,
                    end: selection.interval.end.addingTimeInterval(60)
                ),
                rootTaskIDs: selection.rootTaskIDs,
                taskIDs: selection.taskIDs,
                projectLabel: selection.projectLabel
            )
        )
        await preparation.value

        XCTAssertNil(store.sourcePreflight)
        XCTAssertFalse(store.isPreparingSource)
    }

    func testCancellingPreflightStopsTheSourceRead() async {
        let selection = sourceSelection()
        let reader = CancellableSourceReaderFixture(
            draft: CodexSourceContentDraft(
                selection: selection,
                values: [.prompts: ["Build the report"]]
            )
        )
        let store = CodexAssistedInsightStore(
            service: SourceAnalysisServiceFixture(),
            sourceReader: reader
        )
        await store.checkAvailability()

        let preparation = Task {
            await store.prepareSourceAnalysis(selection: selection)
        }
        try? await Task.sleep(for: .milliseconds(20))
        store.cancelSourcePreflight()
        await preparation.value

        let wasCancelled = await reader.wasCancelled()
        XCTAssertTrue(wasCancelled)
        XCTAssertNil(store.sourcePreflight)
        XCTAssertFalse(store.isPreparingSource)
    }

    func testProfileDisappearanceStopsTheAcceptedSourceRequest() async {
        let selection = sourceSelection()
        let profile = eligibleProfile(effort: "medium")
        let service = SourceAnalysisServiceFixture(
            primaryProfiles: [profile, nil]
        )
        let store = CodexAssistedInsightStore(
            service: service,
            sourceReader: SourceReaderFixture(
                result: .success(
                    CodexSourceContentDraft(
                        selection: selection,
                        values: [.prompts: ["Build the report"]]
                    )
                )
            )
        )
        await store.checkAvailability()
        await store.prepareSourceAnalysis(selection: selection)

        let started = await store.startSourceAnalysis(
            metadata: metadataPayload(),
            scope: analysisScope(),
            selection: selection,
            categories: [.prompts]
        )

        XCTAssertFalse(started)
        let calls = await service.sourceCalls()
        XCTAssertEqual(calls, [])
        XCTAssertFalse(store.showsAnalyzeAction)
    }

    func testStrongerRetryRequiresAnotherActionAndUsesTheAdvertisedProfile() async {
        let selection = sourceSelection()
        let service = SourceAnalysisServiceFixture(
            primaryProfiles: [
                eligibleProfile(effort: "medium"),
                eligibleProfile(effort: "medium")
            ],
            strongerProfile: eligibleProfile(effort: "high")
        )
        let store = CodexAssistedInsightStore(
            service: service,
            sourceReader: SourceReaderFixture(
                result: .success(
                    CodexSourceContentDraft(
                        selection: selection,
                        values: [.prompts: ["Build the report"]]
                    )
                )
            )
        )
        await store.checkAvailability()
        await store.prepareSourceAnalysis(selection: selection)
        _ = await store.startSourceAnalysis(
            metadata: metadataPayload(),
            scope: analysisScope(),
            selection: selection,
            categories: [.prompts]
        )
        await store.waitForAnalysis()

        var calls = await service.sourceCalls()
        XCTAssertEqual(calls.map(\.profile.reasoningEffort), ["medium"])
        XCTAssertTrue(store.showsStrongerRetry)

        let retried = await store.retrySourceWithStrongerProfile()
        XCTAssertTrue(retried)
        await store.waitForAnalysis()
        calls = await service.sourceCalls()
        XCTAssertEqual(
            calls.map(\.profile.reasoningEffort),
            ["medium", "high"]
        )
    }

    func testChangedSelectionInvalidatesTheStrongerRetryPayload() async {
        let selection = sourceSelection()
        let service = SourceAnalysisServiceFixture(
            primaryProfiles: [
                eligibleProfile(effort: "medium"),
                eligibleProfile(effort: "medium")
            ],
            strongerProfile: eligibleProfile(effort: "high")
        )
        let store = CodexAssistedInsightStore(
            service: service,
            sourceReader: SourceReaderFixture(
                result: .success(
                    CodexSourceContentDraft(
                        selection: selection,
                        values: [.prompts: ["Build the report"]]
                    )
                )
            )
        )
        await store.checkAvailability()
        await store.prepareSourceAnalysis(selection: selection)
        _ = await store.startSourceAnalysis(
            metadata: metadataPayload(),
            scope: analysisScope(),
            selection: selection,
            categories: [.prompts]
        )
        await store.waitForAnalysis()
        XCTAssertTrue(store.showsStrongerRetry)

        store.invalidateSourcePreflight(
            for: CodexSourceSelection(
                interval: DateInterval(
                    start: selection.interval.start,
                    end: selection.interval.end.addingTimeInterval(60)
                ),
                rootTaskIDs: selection.rootTaskIDs,
                taskIDs: selection.taskIDs,
                projectLabel: selection.projectLabel
            )
        )

        XCTAssertFalse(store.showsStrongerRetry)
        let retried = await store.retrySourceWithStrongerProfile()
        XCTAssertFalse(retried)
        let calls = await service.sourceCalls()
        XCTAssertEqual(calls.map(\.profile.reasoningEffort), ["medium"])
    }

    func testMissingSelectionInvalidatesTheStrongerRetryPayload() async {
        let selection = sourceSelection()
        let service = SourceAnalysisServiceFixture(
            primaryProfiles: [
                eligibleProfile(effort: "medium"),
                eligibleProfile(effort: "medium")
            ],
            strongerProfile: eligibleProfile(effort: "high")
        )
        let store = CodexAssistedInsightStore(
            service: service,
            sourceReader: SourceReaderFixture(
                result: .success(
                    CodexSourceContentDraft(
                        selection: selection,
                        values: [.prompts: ["Build the report"]]
                    )
                )
            )
        )
        await store.checkAvailability()
        await store.prepareSourceAnalysis(selection: selection)
        _ = await store.startSourceAnalysis(
            metadata: metadataPayload(),
            scope: analysisScope(),
            selection: selection,
            categories: [.prompts]
        )
        await store.waitForAnalysis()
        XCTAssertTrue(store.showsStrongerRetry)

        store.invalidateSourcePreflight(for: nil)

        XCTAssertFalse(store.showsStrongerRetry)
        let retried = await store.retrySourceWithStrongerProfile()
        XCTAssertFalse(retried)
    }

    func testMissingMediumProfileBlocksTheStrongerRetry() async {
        let selection = sourceSelection()
        let service = SourceAnalysisServiceFixture(
            primaryProfiles: [
                eligibleProfile(effort: "medium"),
                eligibleProfile(effort: "medium"),
                nil
            ],
            strongerProfile: eligibleProfile(effort: "high")
        )
        let store = CodexAssistedInsightStore(
            service: service,
            sourceReader: SourceReaderFixture(
                result: .success(
                    CodexSourceContentDraft(
                        selection: selection,
                        values: [.prompts: ["Build the report"]]
                    )
                )
            )
        )
        await store.checkAvailability()
        await store.prepareSourceAnalysis(selection: selection)
        _ = await store.startSourceAnalysis(
            metadata: metadataPayload(),
            scope: analysisScope(),
            selection: selection,
            categories: [.prompts]
        )
        await store.waitForAnalysis()

        let retried = await store.retrySourceWithStrongerProfile()
        XCTAssertFalse(retried)
        XCTAssertFalse(store.showsAnalyzeAction)
        let calls = await service.sourceCalls()
        XCTAssertEqual(calls.map(\.profile.reasoningEffort), ["medium"])
    }

    func testSelectionChangeDuringMediumCheckStopsInitialSend() async {
        let selection = sourceSelection()
        let service = SourceAnalysisServiceFixture(
            primaryProfiles: [
                eligibleProfile(effort: "medium"),
                eligibleProfile(effort: "medium")
            ],
            delayedPrimaryCalls: [2]
        )
        let store = CodexAssistedInsightStore(
            service: service,
            sourceReader: SourceReaderFixture(
                result: .success(
                    CodexSourceContentDraft(
                        selection: selection,
                        values: [.prompts: ["Build the report"]]
                    )
                )
            )
        )
        await store.checkAvailability()
        await store.prepareSourceAnalysis(selection: selection)

        let start = Task {
            await store.startSourceAnalysis(
                metadata: metadataPayload(),
                scope: analysisScope(),
                selection: selection,
                categories: [.prompts]
            )
        }
        try? await Task.sleep(for: .milliseconds(20))
        store.invalidateSourcePreflight(for: changed(selection))

        let started = await start.value
        let calls = await service.sourceCalls()
        XCTAssertFalse(started)
        XCTAssertEqual(calls, [])
    }

    func testSelectionChangeDuringRetryChecksStopsOldPayload() async {
        let selection = sourceSelection()
        let service = SourceAnalysisServiceFixture(
            primaryProfiles: [
                eligibleProfile(effort: "medium"),
                eligibleProfile(effort: "medium"),
                eligibleProfile(effort: "medium")
            ],
            strongerProfile: eligibleProfile(effort: "high"),
            delayedPrimaryCalls: [3]
        )
        let store = CodexAssistedInsightStore(
            service: service,
            sourceReader: SourceReaderFixture(
                result: .success(
                    CodexSourceContentDraft(
                        selection: selection,
                        values: [.prompts: ["Build the report"]]
                    )
                )
            )
        )
        await store.checkAvailability()
        await store.prepareSourceAnalysis(selection: selection)
        _ = await store.startSourceAnalysis(
            metadata: metadataPayload(),
            scope: analysisScope(),
            selection: selection,
            categories: [.prompts]
        )
        await store.waitForAnalysis()

        let retry = Task {
            await store.retrySourceWithStrongerProfile()
        }
        try? await Task.sleep(for: .milliseconds(20))
        store.invalidateSourcePreflight(for: changed(selection))

        let retried = await retry.value
        let calls = await service.sourceCalls()
        XCTAssertFalse(retried)
        XCTAssertEqual(calls.map(\.profile.reasoningEffort), ["medium"])
    }

    func testSourceTurnUsesTheAcceptedPayloadAndKeepsTheIsolatedProfile() throws {
        let draft = CodexSourceContentDraft(
            selection: sourceSelection(),
            values: [
                .prompts: ["Build the report"],
                .responses: ["Done"],
                .code: ["+let answer = 42"]
            ]
        )
        let payload = try CodexSourceAnalysisPayload(
            draft: draft,
            categories: [.prompts, .code]
        )
        let profile = CodexAssistedModelProfile(
            id: "gpt-5.6-luna",
            model: "gpt-5.6-luna",
            reasoningEffort: "medium"
        )

        let request = try CodexAssistedRequestFactory.sourceTurnStart(
            id: 8,
            threadID: "analysis-thread",
            profile: profile,
            payload: payload
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        let text = try XCTUnwrap(input.first?["text"] as? String)
        let sandbox = try XCTUnwrap(
            params["sandboxPolicy"] as? [String: Any]
        )
        let outputSchema = try XCTUnwrap(
            params["outputSchema"] as? [String: Any]
        )
        let properties = try XCTUnwrap(
            outputSchema["properties"] as? [String: Any]
        )

        XCTAssertEqual(params["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(params["effort"] as? String, "medium")
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertEqual(sandbox["type"] as? String, "readOnly")
        XCTAssertEqual(sandbox["networkAccess"] as? Bool, false)
        XCTAssertTrue(text.contains("Build the report"))
        XCTAssertTrue(text.contains("+let answer = 42"))
        XCTAssertFalse(text.contains("\"responses\""))
        XCTAssertFalse(text.contains("\"paths\""))
        XCTAssertFalse(text.contains("\"metadata\""))
        XCTAssertNotNil(properties["sourceInsightKind"])
        XCTAssertNotNil(properties["evidence"])
        XCTAssertNil(properties["insightKind"])
    }

    func testPreflightRendersWithNativeCategoryControls() {
        let draft = CodexSourceContentDraft(
            selection: sourceSelection(),
            values: [
                .prompts: ["Build the report"],
                .responses: ["Done"],
                .code: ["+let answer = 42"],
                .paths: ["/synthetic/atlas/App.swift"],
                .commands: ["swift test"],
                .toolOutput: ["All tests passed"]
            ]
        )
        let renderer = ImageRenderer(
            content: SourceAnalysisPreflightView(
                draft: draft,
                cancel: {},
                analyze: { _ in }
            )
        )
        renderer.proposedSize = ProposedViewSize(
            width: 460,
            height: 640
        )

        XCTAssertNotNil(renderer.nsImage)
    }

    func testSourceContentNeverEntersAnalyticsHistory() async throws {
        let fileURL = temporaryDirectory()
            .appendingPathComponent("history.json")
        let selection = sourceSelection()
        let history = CodexAssistedHistory(fileURL: fileURL)
        let result = CodexAssistedAnalysisResult(
            title: "Usage remaining",
            summary: "Measured account evidence is available.",
            evidence: ["Usage remaining: 37%."],
            confidence: .high,
            observedAt: Date(timeIntervalSince1970: 2_100),
            intervals: [selection.interval],
            freshness: .fresh,
            coverage: .high,
            overhead: CodexAnalyticsOverhead(
                durationSeconds: 1,
                accountMovement: nil
            )
        )
        let sourceDraft = CodexSourceContentDraft(
            selection: selection,
            values: [
                .prompts: ["SOURCE-CONTENT-MUST-NOT-PERSIST"]
            ]
        )
        let sourcePayload = try CodexSourceAnalysisPayload(
            draft: sourceDraft,
            categories: [.prompts]
        )
        let store = CodexAssistedInsightStore(
            service: SourceAnalysisServiceFixture(
                sourceOutcome: .succeeded(result)
            ),
            sourceReader: SourceReaderFixture(
                result: .success(sourceDraft)
            ),
            history: history
        )
        await store.checkAvailability(accountPartitionID: "account")
        await store.prepareSourceAnalysis(selection: selection)
        _ = await store.startSourceAnalysis(
            metadata: metadataPayload(),
            scope: CodexAssistedAnalysisScope(
                exploration: .initial,
                accountPartitionID: "account",
                payload: metadataPayload()
            ),
            selection: selection,
            categories: [.prompts]
        )
        await store.waitForAnalysis()

        let data = try Data(contentsOf: fileURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("SOURCE-CONTENT-MUST-NOT-PERSIST"))
        XCTAssertFalse(text.contains(sourcePayload.fingerprint))
        let savedResults = await history.results(
            accountPartitionID: "account"
        )
        XCTAssertEqual(savedResults.count, 1)
        XCTAssertEqual(
            savedResults.first?.sourceSelectionFingerprint,
            selection.fingerprint
        )
        XCTAssertEqual(savedResults.first?.sourceCategories, ["prompts"])

        let restoredStore = CodexAssistedInsightStore(
            service: SourceAnalysisServiceFixture(),
            history: history
        )
        await restoredStore.checkAvailability(
            accountPartitionID: "account"
        )
        let restored = restoredStore.result(
            for: CodexAssistedAnalysisScope(
                exploration: .initial,
                accountPartitionID: "account",
                payload: metadataPayload()
            ),
            sourceSelection: selection
        )
        let changedResult = restoredStore.result(
            for: CodexAssistedAnalysisScope(
                exploration: .initial,
                accountPartitionID: "account",
                payload: metadataPayload()
            ),
            sourceSelection: changed(selection)
        )
        XCTAssertEqual(restored, result)
        XCTAssertNil(changedResult)
    }

    func testLatestMatchingResultWinsWhenMetadataAndSourceCoexist() async throws {
        let fileURL = temporaryDirectory()
            .appendingPathComponent("history.json")
        let history = CodexAssistedHistory(fileURL: fileURL)
        let metadataScope = CodexAssistedAnalysisScope(
            exploration: .initial,
            accountPartitionID: "account",
            payload: metadataPayload()
        )
        let sourceScope = metadataScope.sourceBacked(
            selection: sourceSelection(),
            categories: [.prompts]
        )
        let metadataResult = resultFixture(
            title: "Metadata result",
            observedAt: 2_000
        )
        let sourceResult = resultFixture(
            title: "Source result",
            observedAt: 2_100
        )
        try await history.recordResult(metadataResult, scope: metadataScope)
        try await history.recordResult(sourceResult, scope: sourceScope)
        let store = CodexAssistedInsightStore(
            service: SourceAnalysisServiceFixture(),
            history: history
        )
        await store.checkAvailability(accountPartitionID: "account")

        let restored = store.result(
            for: metadataScope,
            sourceSelection: sourceSelection()
        )

        XCTAssertEqual(restored?.title, "Source result")
    }

    private func metadataPayload() -> CodexMetadataAnalysisPayload {
        CodexMetadataAnalysisPayload(
            schemaVersion: 1,
            generatedAt: 2_000,
            range: .init(start: 1_000, end: 2_000),
            usageRemaining: .init(percent: 37, interval: nil),
            weeklyResetAt: 2_000,
            evidence: .init(
                freshness: "fresh",
                coverage: "high",
                confidence: "high"
            ),
            accountTokenActivity: .init(
                tokens: 1_000,
                state: "exact",
                interval: nil
            ),
            localTokenActivity: .init(
                tokens: 900,
                coverage: "high",
                interval: nil
            ),
            activity: .init(
                activeSeconds: 120,
                peakConcurrentTasks: 2,
                coverage: "high",
                interval: nil
            ),
            usagePerToken: .init(
                multiplier: nil,
                coverage: "unavailable",
                confidence: "unavailable",
                currentInterval: nil,
                referenceInterval: nil
            ),
            activeTimeAvailable: .init(
                lowerSeconds: nil,
                upperSeconds: nil,
                coverage: "unavailable",
                confidence: "unavailable",
                observedInterval: nil
            ),
            scope: .init(
                accountMetrics: "account",
                localMetrics: "selected_local_activity",
                filtersApplied: .init(
                    project: true,
                    taskTree: true,
                    model: false,
                    reasoning: false
                )
            )
        )
    }

    private func sourceSelection() -> CodexSourceSelection {
        CodexSourceSelection(
            interval: DateInterval(
                start: Date(timeIntervalSince1970: 1_000),
                end: Date(timeIntervalSince1970: 2_000)
            ),
            rootTaskIDs: ["root-task"],
            taskIDs: ["root-task", "child-task"],
            projectLabel: "atlas"
        )
    }

    private func analysisScope() -> CodexAssistedAnalysisScope {
        CodexAssistedAnalysisScope(
            exploration: .initial,
            payload: metadataPayload()
        )
    }

    private func changed(
        _ selection: CodexSourceSelection
    ) -> CodexSourceSelection {
        CodexSourceSelection(
            interval: DateInterval(
                start: selection.interval.start,
                end: selection.interval.end.addingTimeInterval(60)
            ),
            rootTaskIDs: selection.rootTaskIDs,
            taskIDs: selection.taskIDs,
            projectLabel: selection.projectLabel,
            turnIDsByTask: selection.turnIDsByTask
        )
    }

    private func eligibleProfile(
        effort: String
    ) -> CodexAssistedModelProfile {
        CodexAssistedModelProfile(
            id: "gpt-5.6-luna",
            model: "gpt-5.6-luna",
            reasoningEffort: effort
        )
    }

    private func resultFixture(
        title: String,
        observedAt: TimeInterval
    ) -> CodexAssistedAnalysisResult {
        CodexAssistedAnalysisResult(
            title: title,
            summary: "Derived summary",
            evidence: ["Prompts · items 1, 2"],
            confidence: .high,
            observedAt: Date(timeIntervalSince1970: observedAt),
            intervals: [sourceSelection().interval],
            freshness: .fresh,
            coverage: .high,
            overhead: CodexAnalyticsOverhead(
                durationSeconds: 1,
                accountMovement: nil
            )
        )
    }
}

private actor SourceRequestRecorder {
    private(set) var requests: [ThreadProjectionReadRequest] = []

    func response(for request: ThreadProjectionReadRequest) throws -> Data {
        requests.append(request)
        return Data(
            #"""
            {"result":{"thread":{
              "id":"child-task",
              "turns":[
                {
                  "id":"old",
                  "startedAt":900,
                  "completedAt":950,
                  "status":"completed",
                  "items":[
                    {"id":"old-user","type":"userMessage","content":[{"type":"text","text":"Too old"}]}
                  ]
                },
                {
                  "id":"boundary",
                  "startedAt":900,
                  "completedAt":1000,
                  "status":"completed",
                  "items":[
                    {"id":"boundary-user","type":"userMessage","content":[{"type":"text","text":"Ends at boundary"}]}
                  ]
                },
                {
                  "id":"selected",
                  "startedAt":1100,
                  "completedAt":1200,
                  "status":"completed",
                  "items":[
                    {"id":"user","type":"userMessage","content":[{"type":"text","text":"Build the report"}]},
                    {"id":"agent","type":"agentMessage","text":"Done"},
                    {"id":"command","type":"commandExecution","command":"swift test","cwd":"/synthetic/atlas","aggregatedOutput":"All tests passed","commandActions":[],"status":"completed"},
                    {"id":"change","type":"fileChange","status":"completed","changes":[{"path":"/synthetic/atlas/App.swift","kind":"update","diff":"+let answer = 42"}]}
                  ]
                },
                {
                  "id":"other-model",
                  "startedAt":1300,
                  "completedAt":1400,
                  "status":"completed",
                  "items":[
                    {"id":"other-user","type":"userMessage","content":[{"type":"text","text":"Other model"}]}
                  ]
                }
              ]
            }}}
            """#.utf8
        )
    }

    func snapshot() -> [ThreadProjectionReadRequest] {
        requests
    }
}

private actor SourceReaderFixture: CodexSourceContentReading {
    let result: Result<CodexSourceContentDraft, Error>

    init(result: Result<CodexSourceContentDraft, Error>) {
        self.result = result
    }

    func prepare(
        selection _: CodexSourceSelection
    ) async throws -> CodexSourceContentDraft {
        try result.get()
    }
}

private actor DelayedSourceReaderFixture: CodexSourceContentReading {
    let draft: CodexSourceContentDraft

    init(draft: CodexSourceContentDraft) {
        self.draft = draft
    }

    func prepare(
        selection _: CodexSourceSelection
    ) async throws -> CodexSourceContentDraft {
        try await Task.sleep(for: .milliseconds(30))
        return draft
    }
}

private actor CancellableSourceReaderFixture: CodexSourceContentReading {
    let draft: CodexSourceContentDraft
    private var cancelled = false

    init(draft: CodexSourceContentDraft) {
        self.draft = draft
    }

    func prepare(
        selection _: CodexSourceSelection
    ) async throws -> CodexSourceContentDraft {
        do {
            try await Task.sleep(for: .seconds(1))
            return draft
        } catch {
            cancelled = true
            throw error
        }
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

private actor SourceAnalysisServiceFixture: CodexAssistedInsightServicing {
    struct Call: Equatable, Sendable {
        let payload: CodexSourceAnalysisPayload
        let profile: CodexAssistedModelProfile
    }

    private var calls: [Call] = []
    private var primaryProfiles: [CodexAssistedModelProfile?]
    private let advertisedStrongerProfile: CodexAssistedModelProfile?
    private let sourceOutcome: CodexAssistedAnalysisOutcome
    private let delayedPrimaryCalls: Set<Int>
    private var primaryCallCount = 0

    init(
        primaryProfiles: [CodexAssistedModelProfile?] = [
            CodexAssistedModelProfile(
                id: "gpt-5.6-luna",
                model: "gpt-5.6-luna",
                reasoningEffort: "medium"
            )
        ],
        strongerProfile: CodexAssistedModelProfile? = nil,
        delayedPrimaryCalls: Set<Int> = [],
        sourceOutcome: CodexAssistedAnalysisOutcome = .failed(
            CodexAnalyticsOverhead(
                durationSeconds: 0,
                accountMovement: nil
            )
        )
    ) {
        self.primaryProfiles = primaryProfiles
        advertisedStrongerProfile = strongerProfile
        self.delayedPrimaryCalls = delayedPrimaryCalls
        self.sourceOutcome = sourceOutcome
    }

    func eligibleProfile() async throws -> CodexAssistedModelProfile? {
        primaryCallCount += 1
        if delayedPrimaryCalls.contains(primaryCallCount) {
            try await Task.sleep(for: .milliseconds(80))
        }
        guard !primaryProfiles.isEmpty else { return nil }
        return primaryProfiles.count == 1
            ? primaryProfiles[0]
            : primaryProfiles.removeFirst()
    }

    func eligibleStrongerProfile() async throws -> CodexAssistedModelProfile? {
        advertisedStrongerProfile
    }

    func analyze(
        payload _: CodexMetadataAnalysisPayload,
        profile _: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome {
        .failed(CodexAnalyticsOverhead(durationSeconds: 0, accountMovement: nil))
    }

    func analyzeSource(
        payload: CodexSourceAnalysisPayload,
        metadata _: CodexMetadataAnalysisPayload,
        profile: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome {
        calls.append(Call(payload: payload, profile: profile))
        return sourceOutcome
    }

    func cancelAnalysis() async {}

    func sourceCalls() -> [Call] {
        calls
    }
}
