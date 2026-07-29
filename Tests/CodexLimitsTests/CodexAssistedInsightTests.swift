import AppKit
import SwiftUI
import XCTest
@testable import CodexLimits

@MainActor
final class CodexAssistedInsightTests: XCTestCase {
    func testCatalogSelectsOnlyVisibleGPT56LunaWithMediumReasoning() {
        let selected = CodexAssistedModelCatalog.selectProfile(
            from: [
                profile(
                    id: "gpt-5.6-luna",
                    efforts: ["low", "medium", "high"]
                )
            ]
        )

        XCTAssertEqual(selected?.id, "gpt-5.6-luna")
        XCTAssertEqual(selected?.model, "gpt-5.6-luna")
        XCTAssertEqual(selected?.reasoningEffort, "medium")
    }

    func testCatalogRejectsMissingHiddenAndIneligibleProfiles() {
        let ineligible = [
            profile(
                id: "gpt-5.5-luna",
                efforts: ["medium"]
            ),
            profile(
                id: "gpt-5.6-sol",
                efforts: ["medium"]
            ),
            profile(
                id: "gpt-5.6-luna",
                efforts: ["high"]
            ),
            profile(
                id: "gpt-5.6-luna",
                efforts: ["medium"],
                hidden: true
            ),
            profile(
                id: "gpt-5.6-luna-preview",
                efforts: ["medium"]
            ),
            profile(
                id: "gpt-5.6-luna",
                model: "gpt-5.6-sol",
                efforts: ["medium"]
            )
        ]

        for candidate in ineligible {
            XCTAssertNil(
                CodexAssistedModelCatalog.selectProfile(from: [candidate])
            )
        }
        XCTAssertNil(CodexAssistedModelCatalog.selectProfile(from: []))
    }

    func testProtocolRequestsDisableFallbackToolsFilesAndNetwork() throws {
        let selected = try XCTUnwrap(
            CodexAssistedModelCatalog.selectProfile(
                from: [
                    profile(
                        id: "gpt-5.6-luna",
                        efforts: ["medium"]
                    )
                ]
            )
        )
        let thread = CodexAssistedRequestFactory.threadStart(
            id: 7,
            profile: selected,
            disabledFeatureNames: ["apps", "multi_agent"],
            disabledMCPServerNames: ["local-server"]
        )
        let threadParams = try params(thread)

        XCTAssertEqual(thread["method"] as? String, "thread/start")
        XCTAssertEqual(
            threadParams["allowProviderModelFallback"] as? Bool,
            false
        )
        XCTAssertEqual(threadParams["approvalPolicy"] as? String, "never")
        XCTAssertEqual(threadParams["sandbox"] as? String, "read-only")
        XCTAssertEqual(threadParams["cwd"] as? String, "/private/var/empty")
        XCTAssertEqual(threadParams["ephemeral"] as? Bool, true)
        XCTAssertNil(threadParams["historyMode"])
        XCTAssertEqual(threadParams["dynamicTools"] as? [String], [])
        XCTAssertEqual(threadParams["environments"] as? [String], [])
        XCTAssertEqual(
            threadParams["runtimeWorkspaceRoots"] as? [String],
            []
        )
        XCTAssertEqual(
            threadParams["selectedCapabilityRoots"] as? [String],
            []
        )
        let config = try XCTUnwrap(threadParams["config"] as? [String: Any])
        let apps = try XCTUnwrap(config["apps"] as? [String: Any])
        let appDefaults = try XCTUnwrap(
            apps["_default"] as? [String: Any]
        )
        XCTAssertEqual(appDefaults["enabled"] as? Bool, false)
        XCTAssertEqual(appDefaults["open_world_enabled"] as? Bool, false)
        let features = try XCTUnwrap(
            config["features"] as? [String: Bool]
        )
        XCTAssertEqual(
            features,
            ["apps": false, "multi_agent": false]
        )
        let mcpServers = try XCTUnwrap(
            config["mcp_servers"] as? [String: [String: Bool]]
        )
        XCTAssertEqual(
            mcpServers,
            ["local-server": ["enabled": false]]
        )
        XCTAssertEqual(config["project_doc_max_bytes"] as? Int, 0)
        let tools = try XCTUnwrap(config["tools"] as? [String: Any])
        XCTAssertEqual(
            (tools["update_plan"] as? [String: Bool])?["enabled"],
            false
        )
        XCTAssertEqual(
            (
                tools["experimental_request_user_input"]
                    as? [String: Bool]
            )?["enabled"],
            false
        )

        let payload = metadataPayload()
        let turn = try CodexAssistedRequestFactory.turnStart(
            id: 8,
            threadID: "analysis-thread",
            profile: selected,
            payload: payload
        )
        let turnParams = try params(turn)
        XCTAssertEqual(turn["method"] as? String, "turn/start")
        XCTAssertEqual(turnParams["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(turnParams["effort"] as? String, "medium")
        XCTAssertEqual(turnParams["approvalPolicy"] as? String, "never")
        XCTAssertEqual(turnParams["environments"] as? [String], [])
        XCTAssertEqual(
            turnParams["runtimeWorkspaceRoots"] as? [String],
            []
        )
        let sandbox = try XCTUnwrap(
            turnParams["sandboxPolicy"] as? [String: Any]
        )
        XCTAssertEqual(sandbox["type"] as? String, "readOnly")
        XCTAssertEqual(sandbox["networkAccess"] as? Bool, false)
        XCTAssertNil(turnParams["multiAgentMode"])
    }

    func testMetadataPayloadIsBoundedAndContainsNoSourceContent() throws {
        let payload = metadataPayload()
        let data = try CodexAssistedRequestFactory.metadataData(payload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["generatedAt"] as? Int64, 2_000)
        let usageRemaining = try XCTUnwrap(
            object["usageRemaining"] as? [String: Any]
        )
        XCTAssertEqual(usageRemaining["percent"] as? Double, 37)
        XCTAssertEqual(
            usageRemaining["interval"] as? [String: Int64],
            ["start": 1_000, "end": 3_000]
        )
        XCTAssertLessThanOrEqual(data.count, 8_192)
        XCTAssertEqual(
            Set(object.keys),
            [
                "schemaVersion",
                "generatedAt",
                "range",
                "usageRemaining",
                "weeklyResetAt",
                "evidence",
                "accountTokenActivity",
                "localTokenActivity",
                "activity",
                "usagePerToken",
                "activeTimeAvailable",
                "scope"
            ]
        )
        let scope = try XCTUnwrap(object["scope"] as? [String: Any])
        XCTAssertEqual(
            Set(scope.keys),
            ["accountMetrics", "localMetrics", "filtersApplied"]
        )
        XCTAssertEqual(scope["accountMetrics"] as? String, "account")
        XCTAssertEqual(
            scope["localMetrics"] as? String,
            "selected_local_activity"
        )
        let filters = try XCTUnwrap(
            scope["filtersApplied"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(filters.keys),
            ["project", "taskTree", "model", "reasoning"]
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            .lowercased()
        for forbidden in [
            "prompt",
            "response",
            "sourcecontent",
            "source_content",
            "code",
            "path",
            "command",
            "tooloutput",
            "tool_output",
            "/users/",
            "task title",
            "project name"
        ] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testInformationTipNamesCodexAndAllowanceUse() {
        XCTAssertEqual(
            CodexAssistedCopy.informationTip,
            "Sends the metadata shown here to Codex using GPT-5.6 Luna with Medium reasoning. This uses your Codex allowance."
        )
    }

    func testAvailabilityCheckNeverStartsAnalysis() async {
        let service = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .succeeded(analysisResult())
        )
        let store = CodexAssistedInsightStore(service: service)

        await store.checkAvailability()

        let calls = await service.snapshot()
        XCTAssertTrue(store.showsAnalyzeAction)
        XCTAssertEqual(calls.catalogCalls, 1)
        XCTAssertEqual(calls.analysisCalls, 0)
    }

    func testMissingProfileAndCatalogFailureHideTheAction() async {
        let missing = AssistedServiceFixture(
            catalogResult: .success(nil),
            analysisResult: .succeeded(analysisResult())
        )
        let failed = AssistedServiceFixture(
            catalogResult: .failure(FixtureError.failed),
            analysisResult: .succeeded(analysisResult())
        )
        let missingStore = CodexAssistedInsightStore(service: missing)
        let failedStore = CodexAssistedInsightStore(service: failed)

        await missingStore.checkAvailability()
        await failedStore.checkAvailability()

        let missingCalls = await missing.snapshot()
        let failedCalls = await failed.snapshot()
        XCTAssertFalse(missingStore.showsAnalyzeAction)
        XCTAssertFalse(failedStore.showsAnalyzeAction)
        XCTAssertEqual(missingCalls.analysisCalls, 0)
        XCTAssertEqual(failedCalls.analysisCalls, 0)
        XCTAssertFalse(missingStore.showsCard)
        XCTAssertFalse(failedStore.showsCard)
    }

    func testCancelledAvailabilityCheckCanRunAgain() async {
        let service = AssistedServiceFixture(
            catalogResult: .delayedThenSuccess(eligibleProfile()),
            analysisResult: .succeeded(analysisResult())
        )
        let store = CodexAssistedInsightStore(service: service)

        let first = Task {
            await store.checkAvailability()
        }
        await Task.yield()
        first.cancel()
        await first.value
        await store.checkAvailability()

        let calls = await service.snapshot()
        XCTAssertEqual(calls.catalogCalls, 2)
        XCTAssertTrue(store.showsAnalyzeAction)
        XCTAssertTrue(store.showsCard)
    }

    func testExplicitAnalysisClickPublishesMarkedResultAndOverhead() async {
        let service = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .succeeded(analysisResult())
        )
        let store = CodexAssistedInsightStore(service: service)
        await store.checkAvailability()

        let scope = analysisScope()
        store.startAnalysis(payload: metadataPayload(), scope: scope)
        await store.waitForAnalysis()

        let insight = try? XCTUnwrap(store.result(for: scope))
        let calls = await service.snapshot()
        XCTAssertEqual(calls.analysisCalls, 1)
        XCTAssertEqual(insight?.source, "Codex-assisted")
        XCTAssertEqual(insight?.confidence, .high)
        XCTAssertEqual(insight?.overhead.durationSeconds, 12)
        XCTAssertEqual(
            insight?.overhead.accountMovement?.startRemainingPercent,
            37
        )
        XCTAssertEqual(
            insight?.overhead.accountMovement?.endRemainingPercent,
            36
        )
        var changed = AnalyticsExplorationState.initial
        changed.timeRange = .threeDays
        XCTAssertNil(
            store.result(
                for: CodexAssistedAnalysisScope(
                    exploration: changed,
                    payload: metadataPayload()
                )
            )
        )
        XCTAssertNil(
            store.result(
                for: analysisScope(
                    payload: metadataPayload(generatedAt: 2_001)
                )
            )
        )
    }

    func testFailureDoesNotRetryOrChangeProfile() async {
        let service = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .failed(failedOverhead())
        )
        let store = CodexAssistedInsightStore(service: service)
        await store.checkAvailability()

        store.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope()
        )
        await store.waitForAnalysis()

        let calls = await service.snapshot()
        XCTAssertEqual(calls.analysisCalls, 1)
        XCTAssertEqual(calls.receivedProfiles, [eligibleProfile()])
        XCTAssertEqual(
            store.errorMessage,
            "Codex could not analyze this metadata. Try again when you choose."
        )
        XCTAssertEqual(store.overhead, failedOverhead())
    }

    func testCancelInterruptsOnceAndDoesNotRetry() async {
        let service = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .delayed
        )
        let store = CodexAssistedInsightStore(service: service)
        await store.checkAvailability()

        store.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope()
        )
        await Task.yield()
        await store.cancelAnalysis()
        await store.waitForAnalysis()

        let calls = await service.snapshot()
        XCTAssertEqual(calls.cancelCalls, 1)
        XCTAssertEqual(calls.analysisCalls, 1)
        XCTAssertTrue(store.wasCancelled)
        XCTAssertNil(store.result)
        XCTAssertEqual(store.overhead, failedOverhead())
    }

    func testCancelStopsTheLocalAnalysisTaskDuringSetup() async {
        let service = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .waitForTaskCancellation
        )
        let store = CodexAssistedInsightStore(service: service)
        await store.checkAvailability(accountPartitionID: "account-a")

        store.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope(accountPartitionID: "account-a")
        )
        await waitUntil {
            await service.snapshot().analysisCalls == 1
        }
        await store.cancelAnalysis()
        await store.waitForAnalysis()

        let calls = await service.snapshot()
        XCTAssertEqual(calls.cancelCalls, 1)
        XCTAssertTrue(calls.taskCancellationObserved)
        XCTAssertTrue(store.wasCancelled)
        XCTAssertNil(store.result)
    }

    func testAccountChangeClearsResultAndRechecksAvailability() async {
        let service = AssistedServiceFixture(
            catalogResult: .sequence([
                eligibleProfile(),
                nil
            ]),
            analysisResult: .succeeded(analysisResult())
        )
        let store = CodexAssistedInsightStore(service: service)
        let firstScope = analysisScope(accountPartitionID: "account-a")

        await store.checkAvailability(accountPartitionID: "account-a")
        store.startAnalysis(
            payload: metadataPayload(),
            scope: firstScope
        )
        await store.waitForAnalysis()

        XCTAssertNotNil(store.result(for: firstScope))
        XCTAssertNil(
            store.result(
                for: analysisScope(accountPartitionID: "account-b")
            )
        )

        await store.checkAvailability(accountPartitionID: "account-b")

        let calls = await service.snapshot()
        XCTAssertEqual(calls.catalogCalls, 2)
        XCTAssertFalse(store.showsAnalyzeAction)
        XCTAssertFalse(store.showsCard)
        XCTAssertNil(store.result)
    }

    func testResultAndOverheadPersistByAccountUntilDeletion() async throws {
        let root = temporaryDirectory()
        let fileURL = root.appendingPathComponent("assisted.json")
        let history = CodexAssistedHistory(fileURL: fileURL)
        let service = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .succeeded(analysisResult())
        )
        let firstStore = CodexAssistedInsightStore(
            service: service,
            history: history
        )
        let scope = analysisScope(accountPartitionID: "account-a")

        await firstStore.checkAvailability(
            accountPartitionID: "account-a"
        )
        firstStore.startAnalysis(
            payload: metadataPayload(),
            scope: scope
        )
        await firstStore.waitForAnalysis()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let accountResults = await history.results(
            accountPartitionID: "account-a"
        )
        let accountOverhead = await history.overhead(
            accountPartitionID: "account-a"
        )
        let otherAccountResults = await history.results(
            accountPartitionID: "account-b"
        )
        XCTAssertEqual(accountResults.count, 1)
        XCTAssertEqual(accountOverhead.count, 1)
        XCTAssertTrue(otherAccountResults.isEmpty)

        let restoredStore = CodexAssistedInsightStore(
            service: service,
            history: history
        )
        await restoredStore.checkAvailability(
            accountPartitionID: "account-a"
        )
        XCTAssertNotNil(restoredStore.result(for: scope))
        var filteredExploration = AnalyticsExplorationState.initial
        filteredExploration.filters.projectID = "another-project"
        let filteredScope = CodexAssistedAnalysisScope(
            exploration: filteredExploration,
            accountPartitionID: "account-a",
            payload: metadataPayload()
        )
        XCTAssertNil(restoredStore.result(for: filteredScope))

        try await history.deleteAll()
        let emptyStore = CodexAssistedInsightStore(
            service: service,
            history: history
        )
        await emptyStore.checkAvailability(
            accountPartitionID: "account-a"
        )
        XCTAssertNil(emptyStore.result(for: scope))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSuccessfulAnalysisFailsClosedWhenHistoryCannotBeSaved() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let blockedParent = root.appendingPathComponent("not-a-folder")
        try Data("blocked".utf8).write(to: blockedParent)
        let history = CodexAssistedHistory(
            fileURL: blockedParent.appendingPathComponent("assisted.json")
        )
        let service = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .succeeded(analysisResult())
        )
        let store = CodexAssistedInsightStore(
            service: service,
            history: history
        )

        await store.checkAvailability(accountPartitionID: "account-a")
        store.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope(accountPartitionID: "account-a")
        )
        await store.waitForAnalysis()

        XCTAssertNil(store.result)
        XCTAssertEqual(
            store.errorMessage,
            "Codex finished, but the analysis could not be saved. Try again when you choose."
        )
        let savedResults = await history.results(
            accountPartitionID: "account-a"
        )
        XCTAssertTrue(savedResults.isEmpty)
    }

    func testDeletionMarkerSuppressesOldRecordsAndKeepsANewGeneration() async throws {
        let root = temporaryDirectory()
        let historyDirectory = root.appendingPathComponent(
            "history",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: true
        )
        let fileURL = historyDirectory.appendingPathComponent("assisted.json")
        let markerURL = root.appendingPathComponent("deleting.json")
        let cutoff = Date(timeIntervalSince1970: 2_500)
        let scope = analysisScope(accountPartitionID: "account-a")
        let history = CodexAssistedHistory(
            fileURL: fileURL,
            deletionMarkerURL: markerURL
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: historyDirectory.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        try await history.recordResult(analysisResult(), scope: scope)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: historyDirectory.path
        )

        do {
            try await history.deleteAll(upTo: cutoff)
            XCTFail("Expected the retained file removal to fail")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: historyDirectory.path
        )
        let restarted = CodexAssistedHistory(
            fileURL: fileURL,
            deletionMarkerURL: markerURL
        )
        let restoredResults = await restarted.results(
            accountPartitionID: "account-a"
        )
        XCTAssertTrue(restoredResults.isEmpty)

        try await restarted.recordResult(
            analysisResult(
                observedAt: Date(timeIntervalSince1970: 3_000)
            ),
            scope: scope
        )
        try await restarted.deleteAll(upTo: cutoff)

        let retained = await restarted.results(
            accountPartitionID: "account-a"
        )
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(
            retained.first?.result.observedAt,
            Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testDeleteAnalyticsHistoryRemovesCodexAssistedRecords() async throws {
        let root = temporaryDirectory()
        let fileURL = root.appendingPathComponent("assisted.json")
        let assistedHistory = CodexAssistedHistory(fileURL: fileURL)
        let scope = analysisScope(accountPartitionID: "account-a")
        try await assistedHistory.recordResult(
            analysisResult(),
            scope: scope
        )
        try await assistedHistory.recordAnalysis(
            result: nil,
            overhead: failedOverhead(),
            outcome: .failed,
            scope: scope
        )
        let defaultsSuiteName =
            "CodexAssistedDelete-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent(
                "usage",
                isDirectory: true
            ),
            startsAutomatically: false,
            codexAssistedHistory: assistedHistory
        )
        defer {
            defaults.removePersistentDomain(
                forName: defaultsSuiteName
            )
            try? FileManager.default.removeItem(at: root)
        }

        await monitor.deleteAnalyticsHistory()

        let results = await assistedHistory.results(
            accountPartitionID: "account-a"
        )
        let overhead = await assistedHistory.overhead(
            accountPartitionID: "account-a"
        )
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(overhead.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDeleteHistoryCancelsAnAnalysisWithoutRecreatingHistory() async {
        let root = temporaryDirectory()
        let fileURL = root.appendingPathComponent("assisted.json")
        let history = CodexAssistedHistory(fileURL: fileURL)
        let defaultsSuite = "DeleteDuringAnalysis-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let monitor = UsageMonitor(
            defaults: defaults,
            historyDirectory: root.appendingPathComponent(
                "usage",
                isDirectory: true
            ),
            startsAutomatically: false,
            codexAssistedHistory: history
        )
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }
        let service = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .waitForTaskCancellation,
            cancelDelay: .milliseconds(50)
        )
        let store = CodexAssistedInsightStore(
            service: service,
            history: history
        )

        await store.checkAvailability(accountPartitionID: "account-a")
        store.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope(accountPartitionID: "account-a")
        )
        await waitUntil {
            await service.snapshot().analysisCalls == 1
        }

        await monitor.deleteAnalyticsHistory()
        await waitUntil {
            await service.snapshot().cancelCalls == 1
        }
        store.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope(accountPartitionID: "account-a")
        )
        let callsWhileStopping = await service.snapshot().analysisCalls
        XCTAssertEqual(callsWhileStopping, 1)
        await waitUntil {
            await service.snapshot().taskCancellationObserved
        }
        await waitUntil {
            await MainActor.run { !store.isRunning }
        }

        XCTAssertFalse(store.isRunning)
        XCTAssertNil(store.overhead)
        let results = await history.results(
            accountPartitionID: "account-a"
        )
        let overhead = await history.overhead(
            accountPartitionID: "account-a"
        )
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(overhead.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        store.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope(accountPartitionID: "account-a")
        )
        await waitUntil {
            await service.snapshot().analysisCalls == 2
        }
        await store.cancelAnalysis()
    }

    func testDeleteHistoryClearsTerminalStateAndOverhead() async {
        let service = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .failed(failedOverhead())
        )
        let store = CodexAssistedInsightStore(service: service)
        await store.checkAvailability(accountPartitionID: "account-a")
        store.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope(accountPartitionID: "account-a")
        )
        await store.waitForAnalysis()
        XCTAssertNotNil(store.overhead)

        NotificationCenter.default.post(
            name: .codexAssistedHistoryDeleted,
            object: nil,
            userInfo: [
                codexAssistedHistoryDeletionCutoffKey: Date()
            ]
        )

        XCTAssertNil(store.overhead)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.wasCancelled)
    }

    func testResultDecoderRejectsWeakOrUnboundedOutput() throws {
        XCTAssertEqual(
            try CodexAssistedResultDecoder.decode(
                #"{"insightKind":"usage_per_token_change"}"#
            ),
            .usagePerToken
        )
        XCTAssertThrowsError(
            try CodexAssistedResultDecoder.decode(
                #"{"insightKind":"unknown"}"#
            )
        )
        XCTAssertThrowsError(
            try CodexAssistedResultDecoder.decode(
                #"{"insightKind":"activity_summary","summary":"Unsupported free text"}"#
            )
        )
        XCTAssertThrowsError(
            try CodexAssistedResultDecoder.decode(
                #"{"title":"Pattern","summary":"A weak guess","evidenceFields":["usage_per_token"]}"#
            )
        )
    }

    func testEvidenceResolverWithholdsWeakOrMismatchedEvidence() {
        var weak = metadataPayload()
        weak = CodexMetadataAnalysisPayload(
            schemaVersion: weak.schemaVersion,
            generatedAt: weak.generatedAt,
            range: weak.range,
            usageRemaining: weak.usageRemaining,
            weeklyResetAt: weak.weeklyResetAt,
            evidence: weak.evidence,
            accountTokenActivity: weak.accountTokenActivity,
            localTokenActivity: .init(
                tokens: weak.localTokenActivity.tokens,
                coverage: "partial",
                interval: weak.localTokenActivity.interval
            ),
            activity: weak.activity,
            usagePerToken: weak.usagePerToken,
            activeTimeAvailable: weak.activeTimeAvailable,
            scope: weak.scope
        )
        XCTAssertNil(
            CodexAssistedEvidenceResolver.resolve(
                kind: .localTokenActivity,
                payload: weak
            )
        )
        let resolved = CodexAssistedEvidenceResolver.resolve(
            kind: .usagePerToken,
            payload: metadataPayload()
        )
        XCTAssertEqual(resolved?.title, "Usage per token")
        XCTAssertEqual(
            resolved?.summary,
            "Usage per token is 1.25× the reference for this period."
        )
    }

    func testLiveClientReadsCatalogAndRunsOneEphemeralAnalysis() async throws {
        let fixture = CodexAssistedProtocolFixture()
        let client = CodexAssistedClient(
            makeConnection: { try fixture.makeConnection() },
            timeout: 1,
            now: { fixture.now() }
        )

        let selected = try await client.eligibleProfile()
        let outcome = await client.analyze(
            payload: metadataPayload(),
            profile: try XCTUnwrap(selected)
        )
        guard case let .succeeded(result) = outcome else {
            return XCTFail("Expected a successful analysis")
        }
        let requests = fixture.snapshot()

        XCTAssertEqual(result.source, "Codex-assisted")
        XCTAssertEqual(result.title, "Usage per token")
        XCTAssertEqual(result.overhead.durationSeconds, 12)
        XCTAssertEqual(
            result.overhead.accountMovement,
            CodexAccountMovement(
                startRemainingPercent: 37,
                endRemainingPercent: 36,
                resetAt: Date(timeIntervalSince1970: 3_000)
            )
        )
        XCTAssertEqual(requests.connectionCount, 2)
        XCTAssertEqual(requests.modelListCount, 1)
        XCTAssertEqual(requests.accountReads, 1)
        XCTAssertEqual(requests.threadStartCount, 1)
        XCTAssertEqual(requests.turnStartCount, 1)
        XCTAssertEqual(requests.rateLimitReads, 2)
        XCTAssertEqual(requests.featureListReads, 1)
        XCTAssertEqual(requests.configReads, 1)
        XCTAssertTrue(requests.isolationVerified)
        XCTAssertEqual(requests.interruptCount, 0)
        XCTAssertFalse(requests.includeHidden)
    }

    func testLiveClientRejectsToolUseAndInterruptsWithoutRetry() async throws {
        let fixture = CodexAssistedProtocolFixture(sendsToolCall: true)
        let client = CodexAssistedClient(
            makeConnection: { try fixture.makeConnection() },
            timeout: 1,
            now: { fixture.now() }
        )
        let selected = try await client.eligibleProfile()

        let outcome = await client.analyze(
            payload: metadataPayload(),
            profile: try XCTUnwrap(selected)
        )
        guard case let .failed(overhead) = outcome else {
            return XCTFail("Expected tool use to be rejected")
        }
        XCTAssertEqual(overhead.durationSeconds, 12)

        try await Task.sleep(nanoseconds: 10_000_000)
        let requests = fixture.snapshot()
        XCTAssertEqual(requests.connectionCount, 2)
        XCTAssertEqual(requests.turnStartCount, 1)
        XCTAssertEqual(requests.interruptCount, 1)
        XCTAssertEqual(requests.rateLimitReads, 2)
    }

    func testLiveClientRejectsUnknownEnabledFeatureBeforeThreadStart() async {
        let fixture = CodexAssistedProtocolFixture(
            addsUnknownEnabledFeature: true
        )
        let client = CodexAssistedClient(
            makeConnection: { try fixture.makeConnection() },
            timeout: 1,
            now: { fixture.now() }
        )

        let outcome = await client.analyze(
            payload: metadataPayload(),
            profile: eligibleProfile()
        )

        guard case .failed = outcome else {
            return XCTFail("Expected an unknown feature to fail closed")
        }
        let requests = fixture.snapshot()
        XCTAssertEqual(requests.threadStartCount, 0)
        XCTAssertEqual(requests.turnStartCount, 0)
    }

    func testLiveClientRequiresAnExplicitEmptyInstructionSourceList() async throws {
        for mode in [
            InstructionSourcesFixture.missing,
            .malformed
        ] {
            let fixture = CodexAssistedProtocolFixture(
                instructionSources: mode
            )
            let client = CodexAssistedClient(
                makeConnection: { try fixture.makeConnection() },
                timeout: 1,
                now: { fixture.now() }
            )
            let selected = try await client.eligibleProfile()

            let outcome = await client.analyze(
                payload: metadataPayload(),
                profile: try XCTUnwrap(selected)
            )

            guard case .failed = outcome else {
                XCTFail("Expected isolation validation to fail")
                continue
            }
            XCTAssertEqual(fixture.snapshot().turnStartCount, 0)
        }
    }

    func testLiveClientRejectsUnknownTurnItemAndInterrupts() async {
        let fixture = CodexAssistedProtocolFixture(sendsUnknownItem: true)
        let client = CodexAssistedClient(
            makeConnection: { try fixture.makeConnection() },
            timeout: 1,
            now: { fixture.now() }
        )

        let outcome = await client.analyze(
            payload: metadataPayload(),
            profile: eligibleProfile()
        )

        guard case .failed = outcome else {
            return XCTFail("Expected an unknown item to fail closed")
        }
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(fixture.snapshot().interruptCount, 1)
    }

    func testCancelBeforeThreadResponsePreventsTurnStart() async {
        let fixture = CodexAssistedProtocolFixture(delaysThreadResponse: true)
        let client = CodexAssistedClient(
            makeConnection: { try fixture.makeConnection() },
            timeout: 1,
            now: { fixture.now() }
        )
        let task = Task {
            await client.analyze(
                payload: metadataPayload(),
                profile: eligibleProfile()
            )
        }
        await waitUntil {
            fixture.snapshot().threadStartCount == 1
        }

        task.cancel()
        let outcome = await task.value

        guard case .cancelled = outcome else {
            return XCTFail("Expected setup cancellation")
        }
        XCTAssertEqual(fixture.snapshot().turnStartCount, 0)
    }

    func testLiveClientDoesNotRetryCatalogConnectionFailure() async {
        let fixture = CodexAssistedProtocolFixture(dropsCatalogConnection: true)
        let client = CodexAssistedClient(
            makeConnection: { try fixture.makeConnection() },
            timeout: 0.05,
            now: { fixture.now() }
        )

        do {
            _ = try await client.eligibleProfile()
            XCTFail("Expected catalog lookup to fail")
        } catch {
        }

        XCTAssertEqual(fixture.snapshot().connectionCount, 1)
    }

    func testLiveCatalogHidesTheActionWithoutASignedInAccount() async throws {
        let fixture = CodexAssistedProtocolFixture(accountIsMissing: true)
        let client = CodexAssistedClient(
            makeConnection: { try fixture.makeConnection() },
            timeout: 1,
            now: { fixture.now() }
        )

        let selected = try await client.eligibleProfile()

        XCTAssertNil(selected)
        XCTAssertEqual(fixture.snapshot().accountReads, 1)
        XCTAssertEqual(fixture.snapshot().turnStartCount, 0)
    }

    func testActionProgressFailureAndResultRenderAtSmallAndLargeSizes() async {
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: nil,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: Date(timeIntervalSince1970: 2_000),
                previousStatus: nil
            )
        )
        let defaults = UserDefaults(
            suiteName: "CodexAssistedInsightTests-\(UUID().uuidString)"
        )!
        let workspace = AnalyticsWorkspaceStore(defaults: defaults)
        workspace.selectSection(.insights)

        let successService = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .succeeded(analysisResult())
        )
        let successStore = CodexAssistedInsightStore(service: successService)
        await successStore.checkAvailability()
        for size in [
            CGSize(width: 420, height: 620),
            CGSize(width: 720, height: 780)
        ] {
            XCTAssertTrue(
                renders(
                    AnalyticsWorkspaceBody(
                        reader: reader,
                        store: workspace,
                        assistedInsights: successStore
                    ),
                    size: size
                )
            )
        }

        successStore.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope()
        )
        await successStore.waitForAnalysis()
        XCTAssertTrue(
            renders(
                AnalyticsWorkspaceBody(
                    reader: reader,
                    store: workspace,
                    assistedInsights: successStore
                ),
                size: CGSize(width: 520, height: 720)
            )
        )

        let delayedService = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .delayed
        )
        let delayedStore = CodexAssistedInsightStore(service: delayedService)
        await delayedStore.checkAvailability()
        delayedStore.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope()
        )
        await Task.yield()
        XCTAssertTrue(
            renders(
                AnalyticsWorkspaceBody(
                    reader: reader,
                    store: workspace,
                    assistedInsights: delayedStore
                ),
                size: CGSize(width: 520, height: 720)
            )
        )
        await delayedStore.cancelAnalysis()
        await delayedStore.waitForAnalysis()

        let failedService = AssistedServiceFixture(
            catalogResult: .success(eligibleProfile()),
            analysisResult: .failed(failedOverhead())
        )
        let failedStore = CodexAssistedInsightStore(service: failedService)
        await failedStore.checkAvailability()
        failedStore.startAnalysis(
            payload: metadataPayload(),
            scope: analysisScope()
        )
        await failedStore.waitForAnalysis()
        XCTAssertTrue(
            renders(
                AnalyticsWorkspaceBody(
                    reader: reader,
                    store: workspace,
                    assistedInsights: failedStore
                ),
                size: CGSize(width: 520, height: 720)
            )
        )
    }

    private func profile(
        id: String,
        model: String? = nil,
        efforts: [String],
        hidden: Bool = false
    ) -> CodexAdvertisedModel {
        CodexAdvertisedModel(
            id: id,
            model: model ?? id,
            hidden: hidden,
            supportedReasoningEfforts: efforts
        )
    }

    private func eligibleProfile() -> CodexAssistedModelProfile {
        CodexAssistedModelProfile(
            id: "gpt-5.6-luna",
            model: "gpt-5.6-luna",
            reasoningEffort: "medium"
        )
    }

    private func metadataPayload(
        generatedAt: Int64 = 2_000
    ) -> CodexMetadataAnalysisPayload {
        CodexMetadataAnalysisPayload(
            schemaVersion: 1,
            generatedAt: generatedAt,
            range: .init(start: 1_000, end: 2_000),
            usageRemaining: .init(
                percent: 37,
                interval: .init(start: 1_000, end: 3_000)
            ),
            weeklyResetAt: 3_000,
            evidence: .init(
                freshness: "fresh",
                coverage: "high",
                confidence: "high"
            ),
            accountTokenActivity: .init(
                tokens: 1_200_000,
                state: "exact",
                interval: .init(start: 1_000, end: 2_000)
            ),
            localTokenActivity: .init(
                tokens: 1_100_000,
                coverage: "high",
                interval: .init(start: 1_000, end: 2_000)
            ),
            activity: .init(
                activeSeconds: 7_200,
                peakConcurrentTasks: 3,
                coverage: "high",
                interval: .init(start: 1_000, end: 2_000)
            ),
            usagePerToken: .init(
                multiplier: 1.25,
                coverage: "high",
                confidence: "high",
                currentInterval: .init(start: 1_000, end: 2_000),
                referenceInterval: .init(start: 0, end: 1_000)
            ),
            activeTimeAvailable: .init(
                lowerSeconds: 3_600,
                upperSeconds: 5_400,
                coverage: "high",
                confidence: "medium",
                observedInterval: .init(start: 1_000, end: 2_000)
            ),
            scope: .init(
                accountMetrics: "account",
                localMetrics: "selected_local_activity",
                filtersApplied: .init(
                    project: true,
                    taskTree: false,
                    model: true,
                    reasoning: false
                )
            )
        )
    }

    private func analysisScope(
        accountPartitionID: String? = nil,
        payload: CodexMetadataAnalysisPayload? = nil
    ) -> CodexAssistedAnalysisScope {
        CodexAssistedAnalysisScope(
            exploration: AnalyticsExplorationState.initial,
            accountPartitionID: accountPartitionID,
            payload: payload ?? metadataPayload()
        )
    }

    private func failedOverhead() -> CodexAnalyticsOverhead {
        CodexAnalyticsOverhead(
            durationSeconds: 4,
            accountMovement: nil
        )
    }

    private func analysisResult(
        observedAt: Date = Date(timeIntervalSince1970: 2_012)
    ) -> CodexAssistedAnalysisResult {
        CodexAssistedAnalysisResult(
            title: "Usage rose against the reference",
            summary: "The measured ratio is above the selected reference.",
            evidence: ["Usage per token is 1.25× the reference."],
            confidence: .high,
            observedAt: observedAt,
            intervals: [
                DateInterval(
                    start: Date(timeIntervalSince1970: 1_000),
                    end: Date(timeIntervalSince1970: 2_000)
                )
            ],
            freshness: .fresh,
            coverage: .high,
            overhead: CodexAnalyticsOverhead(
                durationSeconds: 12,
                accountMovement: CodexAccountMovement(
                    startRemainingPercent: 37,
                    endRemainingPercent: 36,
                    resetAt: Date(timeIntervalSince1970: 3_000)
                )
            )
        )
    }

    private func params(
        _ request: [String: Any]
    ) throws -> [String: Any] {
        try XCTUnwrap(request["params"] as? [String: Any])
    }

    private func renders<V: View>(
        _ view: V,
        size: CGSize
    ) -> Bool {
        let renderer = ImageRenderer(
            content: view.frame(width: size.width, height: size.height)
        )
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.nsImage != nil
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the test condition.")
    }
}

private enum FixtureError: Error {
    case failed
}

private struct AssistedServiceSnapshot: Sendable {
    let catalogCalls: Int
    let analysisCalls: Int
    let cancelCalls: Int
    let taskCancellationObserved: Bool
    let receivedProfiles: [CodexAssistedModelProfile]
}

private actor AssistedServiceFixture: CodexAssistedInsightServicing {
    enum CatalogResult {
        case success(CodexAssistedModelProfile?)
        case failure(Error)
        case delayedThenSuccess(CodexAssistedModelProfile)
        case sequence([CodexAssistedModelProfile?])
    }

    enum AnalysisResult {
        case succeeded(CodexAssistedAnalysisResult)
        case failed(CodexAnalyticsOverhead)
        case delayed
        case waitForTaskCancellation
    }

    private let catalogResult: CatalogResult
    private let analysisResult: AnalysisResult
    private let cancelDelay: Duration
    private(set) var catalogCalls = 0
    private(set) var analysisCalls = 0
    private(set) var cancelCalls = 0
    private(set) var taskCancellationObserved = false
    private(set) var receivedProfiles: [CodexAssistedModelProfile] = []

    init(
        catalogResult: CatalogResult,
        analysisResult: AnalysisResult,
        cancelDelay: Duration = .zero
    ) {
        self.catalogResult = catalogResult
        self.analysisResult = analysisResult
        self.cancelDelay = cancelDelay
    }

    func eligibleProfile() async throws -> CodexAssistedModelProfile? {
        catalogCalls += 1
        switch catalogResult {
        case let .success(profile):
            return profile
        case let .failure(error):
            throw error
        case let .delayedThenSuccess(profile):
            if catalogCalls == 1 {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
            return profile
        case let .sequence(profiles):
            return profiles[catalogCalls - 1]
        }
    }

    func analyze(
        payload: CodexMetadataAnalysisPayload,
        profile: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome {
        analysisCalls += 1
        receivedProfiles.append(profile)
        switch analysisResult {
        case let .succeeded(result):
            return .succeeded(result)
        case let .failed(overhead):
            return .failed(overhead)
        case .delayed:
            while cancelCalls == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return .cancelled(
                CodexAnalyticsOverhead(
                    durationSeconds: 4,
                    accountMovement: nil
                )
            )
        case .waitForTaskCancellation:
            while !Task.isCancelled {
                await Task.yield()
            }
            taskCancellationObserved = true
            return .cancelled(
                CodexAnalyticsOverhead(
                    durationSeconds: 4,
                    accountMovement: nil
                )
            )
        }
    }

    func cancelAnalysis() async {
        cancelCalls += 1
        if cancelDelay > .zero {
            try? await Task.sleep(for: cancelDelay)
        }
    }

    func snapshot() -> AssistedServiceSnapshot {
        AssistedServiceSnapshot(
            catalogCalls: catalogCalls,
            analysisCalls: analysisCalls,
            cancelCalls: cancelCalls,
            taskCancellationObserved: taskCancellationObserved,
            receivedProfiles: receivedProfiles
        )
    }
}

private struct CodexAssistedProtocolSnapshot {
    let connectionCount: Int
    let modelListCount: Int
    let threadStartCount: Int
    let turnStartCount: Int
    let rateLimitReads: Int
    let accountReads: Int
    let interruptCount: Int
    let featureListReads: Int
    let configReads: Int
    let isolationVerified: Bool
    let includeHidden: Bool
}

private enum InstructionSourcesFixture {
    case empty
    case missing
    case malformed
}

private final class CodexAssistedProtocolFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let sendsToolCall: Bool
    private let sendsUnknownItem: Bool
    private let dropsCatalogConnection: Bool
    private let addsUnknownEnabledFeature: Bool
    private let delaysThreadResponse: Bool
    private let accountIsMissing: Bool
    private let instructionSources: InstructionSourcesFixture
    private var connections = 0
    private var modelLists = 0
    private var threadStarts = 0
    private var turnStarts = 0
    private var rateReads = 0
    private var accountReads = 0
    private var interrupts = 0
    private var featureListReads = 0
    private var configReads = 0
    private var isolationVerified = false
    private var includedHidden = true
    private var clockIndex = 0

    init(
        sendsToolCall: Bool = false,
        sendsUnknownItem: Bool = false,
        dropsCatalogConnection: Bool = false,
        addsUnknownEnabledFeature: Bool = false,
        delaysThreadResponse: Bool = false,
        accountIsMissing: Bool = false,
        instructionSources: InstructionSourcesFixture = .empty
    ) {
        self.sendsToolCall = sendsToolCall
        self.sendsUnknownItem = sendsUnknownItem
        self.dropsCatalogConnection = dropsCatalogConnection
        self.addsUnknownEnabledFeature = addsUnknownEnabledFeature
        self.delaysThreadResponse = delaysThreadResponse
        self.accountIsMissing = accountIsMissing
        self.instructionSources = instructionSources
    }

    func now() -> Date {
        lock.withLock {
            defer { clockIndex += 1 }
            return Date(timeIntervalSince1970: clockIndex == 0 ? 2_000 : 2_012)
        }
    }

    func snapshot() -> CodexAssistedProtocolSnapshot {
        lock.withLock {
            CodexAssistedProtocolSnapshot(
                connectionCount: connections,
                modelListCount: modelLists,
                threadStartCount: threadStarts,
                turnStartCount: turnStarts,
                rateLimitReads: rateReads,
                accountReads: accountReads,
                interruptCount: interrupts,
                featureListReads: featureListReads,
                configReads: configReads,
                isolationVerified: isolationVerified,
                includeHidden: includedHidden
            )
        }
    }

    func makeConnection() throws -> CodexAppServerConnection {
        let requests = Pipe()
        let responses = Pipe()
        lock.withLock { connections += 1 }
        Task {
            for try await line in requests.fileHandleForReading.bytes.lines {
                guard let request = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                ) as? [String: Any],
                      let id = request["id"] as? Int,
                      let method = request["method"] as? String else {
                    continue
                }
                let params = request["params"] as? [String: Any]
                let response: String
                switch method {
                case "initialize":
                    response = #"{"id":\#(id),"result":{}}"#
                case "model/list":
                    lock.withLock {
                        modelLists += 1
                        includedHidden = params?["includeHidden"] as? Bool ?? true
                    }
                    if dropsCatalogConnection {
                        try? responses.fileHandleForWriting.close()
                        return
                    }
                    response = #"{"id":\#(id),"result":{"data":[{"id":"gpt-5.6-luna","model":"gpt-5.6-luna","displayName":"GPT-5.6 Luna","description":"","hidden":false,"isDefault":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Balanced"}]}],"nextCursor":null}}"#
                case "account/rateLimits/read":
                    let read = lock.withLock {
                        rateReads += 1
                        return rateReads
                    }
                    let used = read == 1 ? 63 : 64
                    response = #"{"id":\#(id),"result":{"rateLimits":{"limitId":"codex","secondary":{"usedPercent":\#(used),"windowDurationMins":10080,"resetsAt":3000}}}}"#
                case "account/read":
                    lock.withLock { accountReads += 1 }
                    response = accountIsMissing
                        ? #"{"id":\#(id),"result":{"account":null,"requiresOpenaiAuth":true}}"#
                        : #"{"id":\#(id),"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro"},"requiresOpenaiAuth":true}}"#
                case "experimentalFeature/list":
                    lock.withLock { featureListReads += 1 }
                    let unknown = addsUnknownEnabledFeature
                        ? #",{"name":"future_tool","stage":"stable","enabled":true,"defaultEnabled":true}"#
                        : ""
                    response = #"{"id":\#(id),"result":{"data":[{"name":"apps","stage":"stable","enabled":true,"defaultEnabled":true},{"name":"multi_agent","stage":"stable","enabled":true,"defaultEnabled":true},{"name":"fast_mode","stage":"stable","enabled":true,"defaultEnabled":true}\#(unknown)],"nextCursor":null}}"#
                case "config/read":
                    lock.withLock { configReads += 1 }
                    response = #"{"id":\#(id),"result":{"config":{"mcp_servers":{"local-server":{"enabled":true}}},"origins":{}}}"#
                case "thread/start":
                    lock.withLock {
                        threadStarts += 1
                        let config = params?["config"] as? [String: Any]
                        let features = config?["features"]
                            as? [String: Bool]
                        let servers = config?["mcp_servers"]
                            as? [String: [String: Bool]]
                        isolationVerified =
                            features == [
                                "apps": false,
                                "multi_agent": false
                            ]
                            && servers == [
                                "local-server": ["enabled": false]
                            ]
                            && params?["environments"] as? [String] == []
                            && params?["dynamicTools"] as? [String] == []
                    }
                    if delaysThreadResponse {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    let sources = switch instructionSources {
                    case .empty:
                        #","instructionSources":[] "#
                    case .missing:
                        ""
                    case .malformed:
                        #","instructionSources":"none" "#
                    }
                    response = #"{"id":\#(id),"result":{"thread":{"id":"analysis-thread"},"model":"gpt-5.6-luna","modelProvider":"openai","cwd":"/private/var/empty","approvalPolicy":"never","sandbox":{"type":"readOnly"},"approvalsReviewer":"user"\#(sources)}}"#
                case "turn/start":
                    lock.withLock { turnStarts += 1 }
                    response = #"{"id":\#(id),"result":{"turn":{"id":"analysis-turn","items":[],"status":"inProgress"}}}"#
                    try write(response, to: responses.fileHandleForWriting)
                    if sendsToolCall || sendsUnknownItem {
                        let itemType = sendsToolCall
                            ? "commandExecution"
                            : "futureTool"
                        try write(
                            #"{"method":"item/completed","params":{"threadId":"analysis-thread","turnId":"analysis-turn","completedAtMs":2001000,"item":{"id":"tool-1","type":"\#(itemType)","status":"completed"}}}"#,
                            to: responses.fileHandleForWriting
                        )
                    } else {
                        try write(
                            [
                                "method": "item/completed",
                                "params": [
                                    "threadId": "analysis-thread",
                                    "turnId": "analysis-turn",
                                    "completedAtMs": 2_012_000,
                                    "item": [
                                        "id": "message-1",
                                        "type": "agentMessage",
                                        "text": #"{"insightKind":"usage_per_token_change"}"#
                                    ]
                                ]
                            ],
                            to: responses.fileHandleForWriting
                        )
                        try write(
                            #"{"method":"turn/completed","params":{"threadId":"analysis-thread","turn":{"id":"analysis-turn","items":[],"status":"completed"}}}"#,
                            to: responses.fileHandleForWriting
                        )
                    }
                    continue
                case "turn/interrupt":
                    lock.withLock { interrupts += 1 }
                    response = #"{"id":\#(id),"result":{}}"#
                default:
                    continue
                }
                try write(response, to: responses.fileHandleForWriting)
            }
        }
        return CodexAppServerConnection(
            input: requests.fileHandleForWriting,
            output: responses.fileHandleForReading,
            isRunning: { true },
            stop: {
                try? requests.fileHandleForWriting.close()
                try? responses.fileHandleForWriting.close()
            }
        )
    }

    private func write(_ value: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data((value + "\n").utf8))
    }

    private func write(
        _ value: [String: Any],
        to handle: FileHandle
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try handle.write(contentsOf: data + Data([0x0A]))
    }
}
