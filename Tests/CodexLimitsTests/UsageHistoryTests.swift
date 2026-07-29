import Foundation
import XCTest
@testable import CodexLimits

final class UsageHistoryTests: XCTestCase {
    func testStableAccountIdentityProducesAnOpaqueDeterministicPartition() {
        let key = Data(repeating: 7, count: 32)

        let first = AccountHistoryPartition.stable(
            identity: " User@Example.com ",
            key: key
        )
        let second = AccountHistoryPartition.stable(
            identity: "user@example.com",
            key: key
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.id.contains("user"))
        XCTAssertFalse(first.id.contains("@"))
    }

    func testUnknownAuthTransitionsProduceSeparatePartitions() {
        let first = AccountHistoryPartition.unknown(
            transitionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let second = AccountHistoryPartition.unknown(
            transitionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        XCTAssertNotEqual(first, second)
    }

    func testDecodedAccountPartitionRejectsPathComponents() {
        let data = Data(#"{"id":"../other-account"}"#.utf8)

        XCTAssertThrowsError(
            try JSONDecoder().decode(AccountHistoryPartition.self, from: data)
        )
    }

    func testChangingAccountPartitionKeepsHistoriesSeparate() async throws {
        let root = temporaryDirectory()
        let key = Data(repeating: 3, count: 32)
        let firstPartition = AccountHistoryPartition.stable(
            identity: "first@example.com",
            key: key
        )
        let secondPartition = AccountHistoryPartition.stable(
            identity: "second@example.com",
            key: key
        )
        let firstSample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let secondSample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_060),
            remainingPercent: 70,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a",
            partition: firstPartition
        )

        _ = await history.load()
        _ = await history.record(firstSample)
        let emptySecond = await history.selectPartition(secondPartition)
        _ = await history.record(secondSample)
        let restoredFirst = await history.selectPartition(firstPartition)

        XCTAssertTrue(emptySecond.samples.isEmpty)
        XCTAssertEqual(restoredFirst.samples, [firstSample])
    }

    func testLifetimeTokenEnrichmentKeepsTheExistingSampleIdentity() async throws {
        let root = temporaryDirectory()
        let observedAt = Date(timeIntervalSince1970: 1_900_000)
        let resetsAt = Date(timeIntervalSince1970: 2_000_000)
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        _ = await history.load()
        _ = await history.record(
            UsageSample(
                observedAt: observedAt,
                remainingPercent: 80,
                resetsAt: resetsAt
            )
        )

        let state = await history.record(
            UsageSample(
                observedAt: observedAt,
                remainingPercent: 80,
                resetsAt: resetsAt,
                lifetimeTokens: 1_500,
                comparisonBreak: true
            )
        )

        XCTAssertEqual(state.samples.count, 1)
        XCTAssertEqual(state.samples.first?.lifetimeTokens, 1_500)
        XCTAssertEqual(state.samples.first?.comparisonBreak, true)
    }

    func testNegativeLifetimeTokenReadingIsRejectedDuringNormalization() async throws {
        let root = temporaryDirectory()
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        _ = await history.load()

        let state = await history.record(
            UsageSample(
                observedAt: Date(timeIntervalSince1970: 1_900_000),
                remainingPercent: 80,
                resetsAt: Date(timeIntervalSince1970: 2_000_000),
                lifetimeTokens: -1
            )
        )

        XCTAssertTrue(state.samples.isEmpty)
    }

    func testSharedFolderAcceptsTheSameAccountAndRejectsAnotherAccount() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let owner = UsageHistory(
            localDirectory: root.appendingPathComponent("owner", isDirectory: true),
            installationID: "owner"
        )
        _ = await owner.load()
        _ = await owner.connect(
            to: shared,
            accountIdentity: "User@example.com"
        )
        _ = await owner.record(sample)

        let sameAccount = UsageHistory(
            localDirectory: root.appendingPathComponent("same", isDirectory: true),
            installationID: "same"
        )
        _ = await sameAccount.load()
        let imported = await sameAccount.connect(
            to: shared,
            accountIdentity: " user@example.com "
        )

        let otherAccount = UsageHistory(
            localDirectory: root.appendingPathComponent("other", isDirectory: true),
            installationID: "other"
        )
        _ = await otherAccount.load()
        let rejected = await otherAccount.connect(
            to: shared,
            accountIdentity: "other@example.com"
        )
        let protected = await owner.synchronize()

        XCTAssertEqual(imported.samples, [sample])
        XCTAssertTrue(rejected.samples.isEmpty)
        XCTAssertEqual(
            rejected.errorMessage,
            "This history folder belongs to a different Codex account."
        )
        XCTAssertEqual(rejected.issue, .wrongAccount)
        XCTAssertEqual(protected.samples, [sample])
    }

    func testChangedBindingDisconnectsTheActiveFolderBeforeRecording() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let other = root.appendingPathComponent("other-shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let firstSample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let secondSample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_060),
            remainingPercent: 70,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer-a"
        )
        _ = await history.load()
        _ = await history.connect(
            to: shared,
            accountIdentity: "first@example.com"
        )
        _ = await history.record(firstSample)

        let otherAccount = UsageHistory(
            localDirectory: root.appendingPathComponent("other-local", isDirectory: true),
            installationID: "other"
        )
        _ = await otherAccount.load()
        _ = await otherAccount.connect(
            to: other,
            accountIdentity: "second@example.com"
        )
        let bindingName = ".codex-limits-account.json"
        try Data(contentsOf: other.appendingPathComponent(bindingName)).write(
            to: shared.appendingPathComponent(bindingName),
            options: .atomic
        )

        let rejected = await history.connect(
            to: shared,
            accountIdentity: "first@example.com"
        )
        _ = await history.record(secondSample)

        XCTAssertNil(rejected.folderName)
        XCTAssertEqual(
            rejected.errorMessage,
            "This history folder belongs to a different Codex account."
        )
        let sharedFile = try XCTUnwrap(jsonFiles(for: "writer-a", in: shared).first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sharedFile))
                as? [String: Any]
        )
        let values = (object["samples"] as? [[String: Any]])?
            .compactMap { $0["remainingPercent"] as? Double } ?? []
        XCTAssertEqual(values, [80])
    }

    func testUnavailableFolderKeepsLocalHistoryAndRemainsSelected() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_900_000)
        let sample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(86_400)
        )
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer-a"
        )
        _ = await history.load()
        _ = await history.connect(
            to: shared,
            accountIdentity: "second@example.com"
        )
        _ = await history.record(sample)
        try FileManager.default.removeItem(at: shared)

        let state = await history.synchronize()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(state.folderName, "shared")
        XCTAssertEqual(state.errorMessage, "Sync paused — folder unavailable.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
    }

    func testLegacyDateKeyDecodesAsObservationTime() throws {
        let data = Data(#"{"date":0,"remainingPercent":80,"resetsAt":86400}"#.utf8)

        let sample = try JSONDecoder().decode(UsageSample.self, from: data)

        XCTAssertEqual(sample.observedAt, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(sample.remainingPercent, 80)
        XCTAssertEqual(sample.resetsAt, Date(timeIntervalSinceReferenceDate: 86_400))
    }

    func testVersionOneHistoryMigratesIntoTheActiveAccountPartition() async throws {
        let root = temporaryDirectory()
        let writer = root
            .appendingPathComponent("installations", isDirectory: true)
            .appendingPathComponent("old-writer", isDirectory: true)
        try FileManager.default.createDirectory(at: writer, withIntermediateDirectories: true)
        try Data(#"{"version":1}"#.utf8).write(
            to: root.appendingPathComponent(".codex-limits-history.json")
        )
        let sample = UsageSample(
            observedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            remainingPercent: 64,
            resetsAt: Date(timeIntervalSinceReferenceDate: 8_000)
        )
        let file = [
            "version": 1,
            "samples": [[
                "observedAt": sample.observedAt.timeIntervalSinceReferenceDate,
                "remainingPercent": sample.remainingPercent,
                "resetsAt": sample.resetsAt.timeIntervalSinceReferenceDate
            ]]
        ] as [String: Any]
        try JSONSerialization.data(withJSONObject: file).write(
            to: writer.appendingPathComponent("legacy.json")
        )
        let partition = AccountHistoryPartition.stable(
            identity: "user@example.com",
            key: Data(repeating: 5, count: 32)
        )
        let history = UsageHistory(
            localDirectory: root,
            installationID: "new-writer",
            partition: partition
        )

        let state = await history.load()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("installations").path
        ))
    }

    func testDeleteAnalyticsHistoryRemovesAllLocalPartitionsAndSyncedInstallations() async throws {
        let root = temporaryDirectory()
        let local = root.appendingPathComponent("local", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let key = Data(repeating: 9, count: 32)
        let firstPartition = AccountHistoryPartition.stable(
            identity: "first@example.com",
            key: key
        )
        let secondPartition = AccountHistoryPartition.stable(
            identity: "second@example.com",
            key: key
        )
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let history = UsageHistory(
            localDirectory: local,
            installationID: "writer-a",
            partition: firstPartition
        )
        _ = await history.load()
        _ = await history.record(UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: reset
        ))
        _ = await history.selectPartition(secondPartition)
        _ = await history.connect(
            to: shared,
            accountIdentity: "second@example.com"
        )
        _ = await history.record(UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_060),
            remainingPercent: 70,
            resetsAt: reset
        ))

        let otherWriter = UsageHistory(
            localDirectory: root.appendingPathComponent("other", isDirectory: true),
            installationID: "writer-b",
            partition: secondPartition
        )
        _ = await otherWriter.load()
        _ = await otherWriter.connect(
            to: shared,
            accountIdentity: "second@example.com"
        )
        _ = await otherWriter.record(UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_120),
            remainingPercent: 60,
            resetsAt: reset
        ))

        let state = await history.deleteAnalyticsHistory()

        XCTAssertTrue(state.samples.isEmpty)
        XCTAssertEqual(state.deletionStatus, .complete)
        XCTAssertTrue(jsonFiles(for: "writer-a", in: local).isEmpty)
        XCTAssertTrue(jsonFiles(for: "writer-a", in: shared).isEmpty)
        XCTAssertTrue(jsonFiles(for: "writer-b", in: shared).isEmpty)
    }

    func testNewSyncGenerationPreventsAnOfflineMacFromRepublishingOldHistory() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let partition = AccountHistoryPartition.stable(
            identity: "user@example.com",
            key: Data(repeating: 4, count: 32)
        )
        let first = UsageHistory(
            localDirectory: root.appendingPathComponent("first", isDirectory: true),
            installationID: "writer-a",
            partition: partition
        )
        let offline = UsageHistory(
            localDirectory: root.appendingPathComponent("offline", isDirectory: true),
            installationID: "writer-b",
            partition: partition
        )
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        _ = await first.load()
        _ = await offline.load()
        _ = await first.connect(
            to: shared,
            accountIdentity: "user@example.com"
        )
        _ = await offline.connect(
            to: shared,
            accountIdentity: "user@example.com"
        )
        _ = await offline.record(sample)

        _ = await first.deleteAnalyticsHistory()
        let state = await offline.synchronize()

        XCTAssertTrue(state.samples.isEmpty)
        XCTAssertTrue(jsonFiles(for: "writer-b", in: shared).isEmpty)
    }

    func testNewSamplesUseASeparateDirectoryAfterSharedHistoryIsDeleted() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let writer = UsageHistory(
            localDirectory: root.appendingPathComponent("writer", isDirectory: true),
            installationID: "writer"
        )
        _ = await writer.load()
        _ = await writer.connect(to: shared)
        _ = await writer.deleteAnalyticsHistory()
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )

        _ = await writer.record(sample)

        let sharedFile = try XCTUnwrap(jsonFiles(for: "writer", in: shared).first)
        XCTAssertEqual(
            sharedFile.deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent,
            "generation-2"
        )
    }

    func testLateWriteFromAnOldGenerationCannotRestoreDeletedHistory() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let sample = UsageSample(
            observedAt: Date(timeIntervalSinceReferenceDate: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSinceReferenceDate: 2_000_000)
        )
        let deletingMac = UsageHistory(
            localDirectory: root.appendingPathComponent("deleting", isDirectory: true),
            installationID: "deleting"
        )
        let reader = UsageHistory(
            localDirectory: root.appendingPathComponent("reader", isDirectory: true),
            installationID: "reader"
        )
        _ = await deletingMac.load()
        _ = await deletingMac.connect(to: shared)
        _ = await deletingMac.deleteAnalyticsHistory()
        let markerURL = shared.appendingPathComponent(".codex-limits-history.json")
        let marker = try JSONSerialization.jsonObject(
            with: Data(contentsOf: markerURL)
        ) as! [String: Any]
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "generation": 1,
            "pendingDeletion": false,
            "localDeletionComplete": false,
            "lineageID": try XCTUnwrap(marker["lineageID"] as? String)
        ]).write(to: markerURL, options: .atomic)

        let staleWriter = shared
            .appendingPathComponent("installations", isDirectory: true)
            .appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: staleWriter, withIntermediateDirectories: true)
        let staleFile = [
            "version": 1,
            "samples": [[
                "observedAt": sample.observedAt.timeIntervalSinceReferenceDate,
                "remainingPercent": sample.remainingPercent,
                "resetsAt": sample.resetsAt.timeIntervalSinceReferenceDate
            ]]
        ] as [String: Any]
        try JSONSerialization.data(withJSONObject: staleFile).write(
            to: staleWriter.appendingPathComponent("late.json")
        )

        _ = await reader.load()
        let state = await reader.connect(to: shared)

        XCTAssertTrue(state.samples.isEmpty)
        XCTAssertTrue(jsonFiles(for: "stale", in: shared).isEmpty)
    }

    func testConcurrentDeletionsNeverMoveTheSyncGenerationBackward() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let highLocal = root.appendingPathComponent("high", isDirectory: true)
        let lowLocal = root.appendingPathComponent("low", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let high = UsageHistory(localDirectory: highLocal, installationID: "high")
        let low = UsageHistory(localDirectory: lowLocal, installationID: "low")
        _ = await high.load()
        _ = await low.load()
        _ = await high.connect(to: shared)
        _ = await low.connect(to: shared)
        let sharedMarker = try JSONSerialization.jsonObject(
            with: Data(contentsOf: shared.appendingPathComponent(".codex-limits-history.json"))
        ) as! [String: Any]
        let lineage = try XCTUnwrap(sharedMarker["lineageID"] as? String)
        try markerData(generation: 10, syncTarget: lineage).write(
            to: highLocal.appendingPathComponent(".codex-limits-history.json"),
            options: .atomic
        )
        try markerData(generation: 2, syncTarget: lineage).write(
            to: lowLocal.appendingPathComponent(".codex-limits-history.json"),
            options: .atomic
        )

        async let highDeletion = high.deleteAnalyticsHistory()
        async let lowDeletion = low.deleteAnalyticsHistory()
        _ = await (highDeletion, lowDeletion)

        let finalMarker = try JSONSerialization.jsonObject(
            with: Data(contentsOf: shared.appendingPathComponent(".codex-limits-history.json"))
        ) as! [String: Any]
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(finalMarker["generation"] as? Int), 11)
    }

    func testUnavailableSyncKeepsDeletionPendingUntilExplicitRetry() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer-a"
        )
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        _ = await history.load()
        _ = await history.connect(to: shared)
        _ = await history.record(sample)
        try FileManager.default.moveItem(at: shared, to: parked)

        let pending = await history.deleteAnalyticsHistory()

        XCTAssertTrue(pending.samples.isEmpty)
        XCTAssertEqual(pending.deletionStatus, .pendingSync)
        XCTAssertEqual(
            pending.errorMessage,
            "Deletion pending — sync folder unavailable."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))

        try FileManager.default.moveItem(at: parked, to: shared)
        let completed = await history.retryPendingDeletion()

        XCTAssertTrue(completed.samples.isEmpty)
        XCTAssertEqual(completed.deletionStatus, .complete)
        XCTAssertNil(completed.errorMessage)
        XCTAssertTrue(jsonFiles(for: "writer-a", in: shared).isEmpty)
    }

    func testPendingSyncDeletionBlocksNewHistoryUntilRetry() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer-a"
        )
        _ = await history.load()
        _ = await history.connect(to: shared)
        try FileManager.default.moveItem(at: shared, to: parked)
        _ = await history.deleteAnalyticsHistory()
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )

        let state = await history.record(sample)

        XCTAssertTrue(state.samples.isEmpty)
        XCTAssertEqual(state.deletionStatus, .pendingSync)
        XCTAssertEqual(
            state.errorMessage,
            "Deletion pending — retry before recording new history."
        )
    }

    func testConfiguredButUnavailableSyncTargetKeepsDeletionPending() async throws {
        let root = temporaryDirectory()
        let missing = root.appendingPathComponent("missing-sync", isDirectory: true)
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer-a"
        )
        _ = await history.load()

        let state = await history.deleteAnalyticsHistory(syncTarget: missing)

        XCTAssertTrue(state.samples.isEmpty)
        XCTAssertEqual(state.deletionStatus, .pendingSync)
        XCTAssertEqual(
            state.errorMessage,
            "Deletion pending — sync folder unavailable."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let completed = await history.retryPendingDeletion(
            syncTarget: missing,
            bindsUnresolvedDeletionTarget: true
        )

        XCTAssertEqual(completed.deletionStatus, .complete)
        XCTAssertNil(completed.errorMessage)
    }

    func testPendingDeletionCannotDeleteADifferentSyncFolder() async throws {
        let root = temporaryDirectory()
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        let different = root.appendingPathComponent("different", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: different, withIntermediateDirectories: true)
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let protectedSample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_060),
            remainingPercent: 70,
            resetsAt: reset
        )
        let owner = UsageHistory(
            localDirectory: root.appendingPathComponent("owner", isDirectory: true),
            installationID: "owner"
        )
        _ = await owner.load()
        _ = await owner.connect(to: selected)
        try FileManager.default.moveItem(at: selected, to: parked)
        _ = await owner.deleteAnalyticsHistory()

        let other = UsageHistory(
            localDirectory: root.appendingPathComponent("other", isDirectory: true),
            installationID: "other"
        )
        _ = await other.load()
        _ = await other.connect(to: different)
        _ = await other.record(protectedSample)

        let state = await owner.connect(to: different)
        let protectedState = await other.synchronize()

        XCTAssertEqual(state.deletionStatus, .pendingSync)
        XCTAssertEqual(
            state.errorMessage,
            "Reconnect the folder used for this deletion."
        )
        XCTAssertEqual(protectedState.samples, [protectedSample])
        XCTAssertFalse(jsonFiles(for: "other", in: different).isEmpty)
    }

    func testPendingDeletionCannotDeleteAReplacementAtTheSamePath() async throws {
        let root = temporaryDirectory()
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let owner = UsageHistory(
            localDirectory: root.appendingPathComponent("owner", isDirectory: true),
            installationID: "owner"
        )
        _ = await owner.load()
        _ = await owner.connect(to: selected)
        try FileManager.default.moveItem(at: selected, to: parked)
        _ = await owner.deleteAnalyticsHistory()

        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let protectedSample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let replacementOwner = UsageHistory(
            localDirectory: root.appendingPathComponent("replacement", isDirectory: true),
            installationID: "replacement"
        )
        _ = await replacementOwner.load()
        _ = await replacementOwner.connect(to: selected)
        _ = await replacementOwner.record(protectedSample)

        let state = await owner.connect(to: selected)
        let protectedState = await replacementOwner.synchronize()

        XCTAssertEqual(state.deletionStatus, .pendingSync)
        XCTAssertEqual(protectedState.samples, [protectedSample])
    }

    func testDeleteChecksFolderIdentityBeforeRemovingReachableSharedHistory() async throws {
        let root = temporaryDirectory()
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let owner = UsageHistory(
            localDirectory: root.appendingPathComponent("owner", isDirectory: true),
            installationID: "owner"
        )
        _ = await owner.load()
        _ = await owner.connect(to: selected)
        try FileManager.default.moveItem(at: selected, to: parked)

        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let protectedSample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let replacementOwner = UsageHistory(
            localDirectory: root.appendingPathComponent("replacement", isDirectory: true),
            installationID: "replacement"
        )
        _ = await replacementOwner.load()
        _ = await replacementOwner.connect(to: selected)
        _ = await replacementOwner.record(protectedSample)

        let deletion = await owner.deleteAnalyticsHistory(syncTarget: selected)
        let protectedState = await replacementOwner.synchronize()

        XCTAssertEqual(deletion.deletionStatus, .pendingSync)
        XCTAssertEqual(protectedState.samples, [protectedSample])
        XCTAssertFalse(jsonFiles(for: "replacement", in: selected).isEmpty)
    }

    func testPendingDeletionFollowsTheSelectedFolderAfterRename() async throws {
        let root = temporaryDirectory()
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let renamed = root.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer"
        )
        _ = await history.load()
        _ = await history.connect(to: selected)
        try FileManager.default.moveItem(at: selected, to: renamed)
        _ = await history.deleteAnalyticsHistory()

        let state = await history.connect(to: renamed)

        XCTAssertEqual(state.deletionStatus, .complete)
        XCTAssertNil(state.errorMessage)
    }

    func testSwitchingSyncFoldersDoesNotApplyTheOldFolderGeneration() async throws {
        let root = temporaryDirectory()
        let firstFolder = root.appendingPathComponent("first", isDirectory: true)
        let secondFolder = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let switching = UsageHistory(
            localDirectory: root.appendingPathComponent("switching", isDirectory: true),
            installationID: "switching"
        )
        _ = await switching.load()
        _ = await switching.connect(to: firstFolder)
        _ = await switching.deleteAnalyticsHistory()
        _ = await switching.disconnect()

        let other = UsageHistory(
            localDirectory: root.appendingPathComponent("other-local", isDirectory: true),
            installationID: "other"
        )
        _ = await other.load()
        _ = await other.connect(to: secondFolder)
        _ = await other.record(sample)

        let state = await switching.connect(to: secondFolder)

        XCTAssertEqual(state.samples, [sample])
        XCTAssertFalse(jsonFiles(for: "other", in: secondFolder).isEmpty)
    }

    func testPendingDeletionSurvivesRestartAndBlocksOldImports() async throws {
        let root = temporaryDirectory()
        let local = root.appendingPathComponent("local", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let history = UsageHistory(
            localDirectory: local,
            installationID: "writer-a"
        )
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        _ = await history.load()
        _ = await history.connect(to: shared)
        _ = await history.record(sample)
        try FileManager.default.moveItem(at: shared, to: parked)
        _ = await history.deleteAnalyticsHistory()

        let restarted = UsageHistory(
            localDirectory: local,
            installationID: "writer-a"
        )
        let pending = await restarted.load()

        XCTAssertTrue(pending.samples.isEmpty)
        XCTAssertEqual(pending.deletionStatus, .pendingSync)

        try FileManager.default.moveItem(at: parked, to: shared)
        let completed = await restarted.connect(to: shared)

        XCTAssertTrue(completed.samples.isEmpty)
        XCTAssertEqual(completed.deletionStatus, .complete)
        XCTAssertTrue(jsonFiles(for: "writer-a", in: shared).isEmpty)
    }

    func testCompletingPendingDeletionDoesNotConnectAnotherAccount() async throws {
        let root = temporaryDirectory()
        let local = root.appendingPathComponent("local", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let key = Data(repeating: 7, count: 32)
        let firstPartition = AccountHistoryPartition.stable(
            identity: "first@example.com",
            key: key
        )
        let secondPartition = AccountHistoryPartition.stable(
            identity: "second@example.com",
            key: key
        )
        let history = UsageHistory(
            localDirectory: local,
            installationID: "writer-a",
            partition: firstPartition
        )
        _ = await history.load()
        _ = await history.connect(
            to: shared,
            accountIdentity: "first@example.com"
        )
        try FileManager.default.moveItem(at: shared, to: parked)
        _ = await history.deleteAnalyticsHistory()
        _ = await history.selectPartition(secondPartition)
        try FileManager.default.moveItem(at: parked, to: shared)

        let completed = await history.connect(
            to: shared,
            accountIdentity: "second@example.com"
        )
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        _ = await history.record(sample)

        XCTAssertEqual(completed.deletionStatus, .complete)
        XCTAssertNil(completed.folderName)
        XCTAssertEqual(
            completed.errorMessage,
            "This history folder belongs to a different Codex account."
        )
        XCTAssertTrue(jsonFiles(for: "writer-a", in: shared).isEmpty)
    }

    func testRetryFinishesInterruptedLocalDeletionBeforePublishing() async throws {
        let root = temporaryDirectory()
        let local = root.appendingPathComponent("local", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let history = UsageHistory(
            localDirectory: local,
            installationID: "writer-a"
        )
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        _ = await history.load()
        _ = await history.connect(to: shared)
        _ = await history.record(sample)
        let sharedMarker = try JSONSerialization.jsonObject(
            with: Data(contentsOf: shared.appendingPathComponent(".codex-limits-history.json"))
        ) as! [String: Any]
        let lineage = try XCTUnwrap(sharedMarker["lineageID"] as? String)
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "generation": 2,
            "pendingDeletion": true,
            "localDeletionComplete": false,
            "pendingSyncTarget": lineage,
            "syncTarget": lineage
        ]).write(
            to: local.appendingPathComponent(".codex-limits-history.json"),
            options: .atomic
        )

        let completed = await history.retryPendingDeletion()

        XCTAssertTrue(completed.samples.isEmpty)
        XCTAssertEqual(completed.deletionStatus, .complete)
        XCTAssertTrue(jsonFiles(for: "writer-a", in: shared).isEmpty)
    }

    func testDeletedHistoryStaysEmptyUntilExplicitPartialRebuild() async throws {
        let root = temporaryDirectory()
        let sample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        _ = await history.load()
        _ = await history.record(sample)
        _ = await history.deleteAnalyticsHistory()

        let restarted = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        let empty = await restarted.load()
        let rebuilt = await restarted.rebuildAvailableHistory([sample])

        XCTAssertTrue(empty.samples.isEmpty)
        XCTAssertEqual(rebuilt.samples, [sample])
    }

    func testInterruptedLocalOnlyDeletionFinishesWithoutAskingForASyncFolder() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "generation": 2,
            "pendingDeletion": true,
            "localDeletionComplete": true,
            "pendingDeletionTarget": "local-only"
        ]).write(
            to: root.appendingPathComponent(".codex-limits-history.json"),
            options: .atomic
        )

        let restarted = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        let state = await restarted.load()

        XCTAssertTrue(state.samples.isEmpty)
        XCTAssertEqual(state.deletionStatus, .complete)
        XCTAssertNil(state.errorMessage)
    }

    func testCorruptionDoesNotReplaceHistoryAlreadyLoadedInMemory() async throws {
        let root = temporaryDirectory()
        let now = Date(timeIntervalSince1970: 1_900_000)
        let sample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(86_400)
        )
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        _ = await history.load()
        _ = await history.record(sample)
        let file = try XCTUnwrap(jsonFiles(for: "writer-a", in: root).first)
        try Data("broken".utf8).write(to: file)

        let state = await history.synchronize()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(state.errorMessage, "Some usage history couldn’t be read.")
    }

    func testFailedAtomicWriteKeepsTheLastValidHistory() async throws {
        let root = temporaryDirectory()
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let first = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 80,
            resetsAt: reset
        )
        let second = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_060),
            remainingPercent: 79,
            resetsAt: reset
        )
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        _ = await history.load()
        _ = await history.record(first)
        let writer = try XCTUnwrap(writerDirectories(for: "writer-a", in: root).first)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: writer.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: writer.path
            )
        }

        let state = await history.record(second)

        XCTAssertEqual(state.samples, [first])
        XCTAssertEqual(state.errorMessage, "Usage history couldn’t be saved.")
    }

    func testOversizedDailyFileIsSkipped() async throws {
        let root = temporaryDirectory()
        let now = Date(timeIntervalSince1970: 1_900_000)
        let sample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(86_400)
        )
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        _ = await history.load()
        _ = await history.record(sample)
        let file = try XCTUnwrap(jsonFiles(for: "writer-a", in: root).first)
        let original = try XCTUnwrap(String(data: Data(contentsOf: file), encoding: .utf8))
        let oversized = original.replacingOccurrences(
            of: "{",
            with: #"{"padding":""# + String(repeating: "x", count: 1_000_001) + #"","#,
            options: [.anchored]
        )
        try Data(oversized.utf8).write(to: file)

        let reloaded = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        let state = await reloaded.load()

        XCTAssertTrue(state.samples.isEmpty)
        XCTAssertEqual(state.errorMessage, "Some usage history couldn’t be read.")
    }

    func testRepeatedLegacyMigrationAndSyncAreIdempotent() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_900_000)
        let sample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(86_400)
        )
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer-a"
        )

        _ = await history.load(legacySamples: [sample])
        _ = await history.load(legacySamples: [sample])
        _ = await history.connect(to: shared)
        _ = await history.synchronize()
        let state = await history.synchronize()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertNil(state.errorMessage)
    }

    func testUnsupportedFolderVersionIsNotModified() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let marker = shared.appendingPathComponent(".codex-limits-history.json")
        let unsupportedMarker = Data(#"{"version":3}"#.utf8)
        try unsupportedMarker.write(to: marker)
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer-a"
        )
        _ = await history.load()

        let state = await history.connect(to: shared)

        XCTAssertEqual(
            state.errorMessage,
            "This history folder was created by a newer version of Codex Limits."
        )
        XCTAssertEqual(try Data(contentsOf: marker), unsupportedMarker)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: shared.appendingPathComponent("installations").path
        ))
    }

    func testAtomicMarkerUpdateDoesNotOverwriteANewerConcurrentVersion() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let upgraded = try JSONSerialization.data(withJSONObject: [
            "version": 3,
            "generation": 1,
            "futureField": "keep-me"
        ])
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer-a",
            beforeCoordinatedMarkerRead: { marker in
                try upgraded.write(to: marker, options: .atomic)
            }
        )
        _ = await history.load()

        let state = await history.connect(to: shared)

        let marker = shared.appendingPathComponent(".codex-limits-history.json")
        XCTAssertEqual(
            state.errorMessage,
            "This history folder was created by a newer version of Codex Limits."
        )
        XCTAssertEqual(try Data(contentsOf: marker), upgraded)
    }

    func testOutOfRangeGenerationIsRejectedWithoutOverflowing() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let owner = UsageHistory(
            localDirectory: root.appendingPathComponent("owner", isDirectory: true),
            installationID: "owner"
        )
        _ = await owner.load()
        _ = await owner.connect(to: shared)
        let markerURL = shared.appendingPathComponent(".codex-limits-history.json")
        var marker = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
                as? [String: Any]
        )
        marker["generation"] = Int.max
        try JSONSerialization.data(withJSONObject: marker).write(
            to: markerURL,
            options: .atomic
        )

        let state = await owner.deleteAnalyticsHistory()

        XCTAssertEqual(state.deletionStatus, .pendingSync)
        XCTAssertTrue(state.samples.isEmpty)
    }

    func testDisconnectKeepsLocalHistoryAndStopsPublishing() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_900_060)
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let first = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 82,
            resetsAt: reset
        )
        let second = UsageSample(
            observedAt: now,
            remainingPercent: 81,
            resetsAt: reset
        )
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer-a"
        )
        _ = await history.load()
        _ = await history.connect(to: shared)
        _ = await history.record(first)

        _ = await history.disconnect()
        let localState = await history.record(second)

        let reader = UsageHistory(
            localDirectory: root.appendingPathComponent("reader", isDirectory: true),
            installationID: "reader"
        )
        _ = await reader.load()
        let sharedState = await reader.connect(to: shared)

        XCTAssertEqual(localState.samples, [first, second])
        XCTAssertNil(localState.folderName)
        XCTAssertEqual(sharedState.samples, [first])
    }

    func testMissingSyncFolderIsNotRecreated() async throws {
        let root = temporaryDirectory()
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let history = UsageHistory(
            localDirectory: root.appendingPathComponent("local", isDirectory: true),
            installationID: "writer-a"
        )
        _ = await history.load()

        let state = await history.connect(to: missing)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertNil(state.folderName)
        XCTAssertEqual(state.errorMessage, "Sync paused — folder unavailable.")
    }

    func testMalformedSyncedFileDoesNotBlockValidRemoteHistory() async throws {
        let root = temporaryDirectory()
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_900_000)
        let receiver = UsageHistory(
            localDirectory: root.appendingPathComponent("receiver", isDirectory: true),
            installationID: "receiver"
        )
        _ = await receiver.load()
        _ = await receiver.connect(to: shared)

        let corruptWriter = shared
            .appendingPathComponent("installations", isDirectory: true)
            .appendingPathComponent("a-corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptWriter, withIntermediateDirectories: true)
        try Data("broken".utf8).write(
            to: corruptWriter.appendingPathComponent("0000-broken.json")
        )

        let sample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(86_400)
        )
        let sender = UsageHistory(
            localDirectory: root.appendingPathComponent("sender", isDirectory: true),
            installationID: "z-sender"
        )
        _ = await sender.load()
        _ = await sender.connect(to: shared)
        let senderState = await sender.record(sample)
        XCTAssertNil(senderState.errorMessage)

        let state = await receiver.synchronize()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(state.errorMessage, "Some synced history couldn’t be read.")
    }

    func testHistoryKeepsSamplesWithoutAgeLimit() async throws {
        let root = temporaryDirectory()
        let currentDate = Date(timeIntervalSince1970: 1_700_000_000)
        let oldDate = currentDate.addingTimeInterval(-3 * 365 * 86_400)
        let oldReset = oldDate.addingTimeInterval(7 * 86_400)
        let writer = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        let sample = UsageSample(
            observedAt: oldDate,
            remainingPercent: 80,
            resetsAt: oldReset
        )

        _ = await writer.load()
        _ = await writer.record(sample)

        let reloaded = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        let state = await reloaded.load()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(jsonFiles(for: "writer-a", in: root).count, 1)
    }

    func testMalformedFileKeepsValidHistoryAndReportsWarning() async throws {
        let root = temporaryDirectory()
        let now = Date(timeIntervalSince1970: 1_900_000)
        let sample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(86_400)
        )
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        _ = await history.load()
        _ = await history.record(sample)
        let writerDirectory = try XCTUnwrap(
            writerDirectories(for: "writer-a", in: root).first
        )
        try Data("broken".utf8).write(
            to: writerDirectory.appendingPathComponent("broken.json")
        )

        let reloaded = UsageHistory(
            localDirectory: root,
            installationID: "writer-a"
        )
        let state = await reloaded.load()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(state.errorMessage, "Some usage history couldn’t be read.")
    }

    func testVersionOneMigrationKeepsValidSamplesWhenAnotherFileIsMalformed() async throws {
        let root = temporaryDirectory()
        let writer = root
            .appendingPathComponent("installations", isDirectory: true)
            .appendingPathComponent("old-writer", isDirectory: true)
        try FileManager.default.createDirectory(at: writer, withIntermediateDirectories: true)
        try Data(#"{"version":1}"#.utf8).write(
            to: root.appendingPathComponent(".codex-limits-history.json")
        )
        let sample = UsageSample(
            observedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            remainingPercent: 64,
            resetsAt: Date(timeIntervalSinceReferenceDate: 8_000)
        )
        let valid = [
            "version": 1,
            "samples": [[
                "observedAt": sample.observedAt.timeIntervalSinceReferenceDate,
                "remainingPercent": sample.remainingPercent,
                "resetsAt": sample.resetsAt.timeIntervalSinceReferenceDate
            ]]
        ] as [String: Any]
        try JSONSerialization.data(withJSONObject: valid).write(
            to: writer.appendingPathComponent("valid.json")
        )
        let malformed = writer.appendingPathComponent("malformed.json")
        try Data("broken".utf8).write(to: malformed)

        let history = UsageHistory(
            localDirectory: root,
            installationID: "new-writer"
        )
        let state = await history.load()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(state.errorMessage, "Some usage history couldn’t be migrated.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))

        let restarted = UsageHistory(
            localDirectory: root,
            installationID: "new-writer"
        )
        let restartedState = await restarted.load()
        XCTAssertEqual(
            restartedState.errorMessage,
            "Some usage history couldn’t be migrated."
        )
    }

    func testFailedMigrationKeepsLegacyHistoryAvailable() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unusableDirectory = root.appendingPathComponent("history")
        try Data("not a directory".utf8).write(to: unusableDirectory)
        let now = Date(timeIntervalSince1970: 1_900_000)
        let sample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(86_400)
        )
        let history = UsageHistory(
            localDirectory: unusableDirectory,
            installationID: "writer-a"
        )

        let state = await history.load(legacySamples: [sample])

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(state.errorMessage, "Usage history couldn’t be saved.")
    }

    func testTwoInstallationsMergeWithoutLosingSamples() async throws {
        let root = temporaryDirectory()

        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let firstWriter = UsageHistory(
            localDirectory: root.appendingPathComponent("writer-a", isDirectory: true),
            installationID: "writer-a"
        )
        let secondWriter = UsageHistory(
            localDirectory: root.appendingPathComponent("writer-b", isDirectory: true),
            installationID: "writer-b"
        )
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let firstSample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_000),
            remainingPercent: 82,
            resetsAt: reset
        )
        let secondSample = UsageSample(
            observedAt: Date(timeIntervalSince1970: 1_900_060),
            remainingPercent: 81,
            resetsAt: reset
        )

        _ = await firstWriter.load()
        _ = await secondWriter.load()
        _ = await firstWriter.connect(to: shared)
        _ = await secondWriter.connect(to: shared)

        async let firstWrite = firstWriter.record(firstSample)
        async let secondWrite = secondWriter.record(secondSample)
        let writeStates = await (firstWrite, secondWrite)
        XCTAssertNil(writeStates.0.errorMessage)
        XCTAssertNil(writeStates.1.errorMessage)
        XCTAssertEqual(jsonFiles(for: "writer-a", in: shared).count, 1)
        XCTAssertEqual(jsonFiles(for: "writer-b", in: shared).count, 1)

        let firstState = await firstWriter.synchronize()
        let secondState = await secondWriter.synchronize()

        XCTAssertEqual(firstState.samples, [firstSample, secondSample])
        XCTAssertEqual(secondState.samples, [firstSample, secondSample])
        XCTAssertNil(firstState.errorMessage)
        XCTAssertNil(secondState.errorMessage)
    }

    private func jsonFiles(for installationID: String, in root: URL) -> [URL] {
        writerDirectories(for: installationID, in: root).flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension == "json" } ?? []
        }
    }

    private func writerDirectories(for installationID: String, in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            let parent = $0.deletingLastPathComponent()
            let isDirectWriter = parent.lastPathComponent == "installations"
            let isGenerationWriter = parent.lastPathComponent.hasPrefix("generation-")
                && parent.deletingLastPathComponent().lastPathComponent == "installations"
            return $0.lastPathComponent == installationID
                && (isDirectWriter || isGenerationWriter)
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func markerData(generation: Int, syncTarget: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "generation": generation,
            "pendingDeletion": false,
            "localDeletionComplete": false,
            "syncTarget": syncTarget
        ])
    }
}
