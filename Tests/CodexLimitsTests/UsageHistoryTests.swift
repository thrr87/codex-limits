import Foundation
import XCTest
@testable import CodexLimits

final class UsageHistoryTests: XCTestCase {
    func testUnavailableFolderKeepsLocalHistoryAndRemainsSelected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
            installationID: "writer-a",
            now: { now }
        )
        _ = await history.load()
        _ = await history.connect(to: shared)
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

    func testCorruptionDoesNotReplaceHistoryAlreadyLoadedInMemory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_900_000)
        let sample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(86_400)
        )
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a",
            now: { now }
        )
        _ = await history.load()
        _ = await history.record(sample)
        let file = try XCTUnwrap(jsonFiles(for: "writer-a", in: root).first)
        try Data("broken".utf8).write(to: file)

        let state = await history.synchronize()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(state.errorMessage, "Some usage history couldn’t be read.")
    }

    func testOversizedDailyFileIsSkipped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_900_000)
        let sample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(86_400)
        )
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a",
            now: { now }
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
            installationID: "writer-a",
            now: { now }
        )
        let state = await reloaded.load()

        XCTAssertTrue(state.samples.isEmpty)
        XCTAssertEqual(state.errorMessage, "Some usage history couldn’t be read.")
    }

    func testRepeatedLegacyMigrationAndSyncAreIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
            installationID: "writer-a",
            now: { now }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let marker = shared.appendingPathComponent(".codex-limits-history.json")
        let unsupportedMarker = Data(#"{"version":2}"#.utf8)
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

    func testDisconnectKeepsLocalHistoryAndStopsPublishing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
            installationID: "writer-a",
            now: { now }
        )
        _ = await history.load()
        _ = await history.connect(to: shared)
        _ = await history.record(first)

        _ = await history.disconnect()
        let localState = await history.record(second)

        let reader = UsageHistory(
            localDirectory: root.appendingPathComponent("reader", isDirectory: true),
            installationID: "reader",
            now: { now }
        )
        _ = await reader.load()
        let sharedState = await reader.connect(to: shared)

        XCTAssertEqual(localState.samples, [first, second])
        XCTAssertNil(localState.folderName)
        XCTAssertEqual(sharedState.samples, [first])
    }

    func testMissingSyncFolderIsNotRecreated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_900_000)
        let receiver = UsageHistory(
            localDirectory: root.appendingPathComponent("receiver", isDirectory: true),
            installationID: "receiver",
            now: { now }
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
            installationID: "z-sender",
            now: { now }
        )
        _ = await sender.load()
        _ = await sender.connect(to: shared)
        let senderState = await sender.record(sample)
        XCTAssertNil(senderState.errorMessage)

        let state = await receiver.synchronize()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(state.errorMessage, "Some synced history couldn’t be read.")
    }

    func testRetentionDeletesOnlyThisInstallationsExpiredFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentDate = Date(timeIntervalSince1970: 10_000_000)
        let oldDate = currentDate.addingTimeInterval(-91 * 86_400)
        let oldReset = oldDate.addingTimeInterval(7 * 86_400)
        let firstWriter = UsageHistory(
            localDirectory: root,
            installationID: "writer-a",
            now: { oldDate }
        )
        let secondWriter = UsageHistory(
            localDirectory: root,
            installationID: "writer-b",
            now: { oldDate }
        )

        _ = await firstWriter.load()
        _ = await firstWriter.record(UsageSample(
            observedAt: oldDate,
            remainingPercent: 80,
            resetsAt: oldReset
        ))
        _ = await secondWriter.record(UsageSample(
            observedAt: oldDate,
            remainingPercent: 79,
            resetsAt: oldReset
        ))

        let currentFirstWriter = UsageHistory(
            localDirectory: root,
            installationID: "writer-a",
            now: { currentDate }
        )
        _ = await currentFirstWriter.load()

        XCTAssertTrue(jsonFiles(for: "writer-a", in: root).isEmpty)
        XCTAssertEqual(jsonFiles(for: "writer-b", in: root).count, 1)
    }

    func testMalformedFileKeepsValidHistoryAndReportsWarning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_900_000)
        let sample = UsageSample(
            observedAt: now,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(86_400)
        )
        let history = UsageHistory(
            localDirectory: root,
            installationID: "writer-a",
            now: { now }
        )
        _ = await history.load()
        _ = await history.record(sample)
        let writerDirectory = root
            .appendingPathComponent("installations", isDirectory: true)
            .appendingPathComponent("writer-a", isDirectory: true)
        try Data("broken".utf8).write(
            to: writerDirectory.appendingPathComponent("broken.json")
        )

        let reloaded = UsageHistory(
            localDirectory: root,
            installationID: "writer-a",
            now: { now }
        )
        let state = await reloaded.load()

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(state.errorMessage, "Some usage history couldn’t be read.")
    }

    func testFailedMigrationKeepsLegacyHistoryAvailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
            installationID: "writer-a",
            now: { now }
        )

        let state = await history.load(legacySamples: [sample])

        XCTAssertEqual(state.samples, [sample])
        XCTAssertEqual(state.errorMessage, "Usage history couldn’t be saved.")
    }

    func testTwoInstallationsMergeWithoutLosingSamples() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_900_060)
        let firstWriter = UsageHistory(
            localDirectory: root.appendingPathComponent("writer-a", isDirectory: true),
            installationID: "writer-a",
            now: { now }
        )
        let secondWriter = UsageHistory(
            localDirectory: root.appendingPathComponent("writer-b", isDirectory: true),
            installationID: "writer-b",
            now: { now }
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
        let directory = root
            .appendingPathComponent("installations", isDirectory: true)
            .appendingPathComponent(installationID, isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "json" } ?? []
    }
}
