import ClaudeIntegrationCore
import Combine
import Darwin
import Foundation
import XCTest
@testable import CodexLimits

final class ClaudeCodeSetupServiceTests: XCTestCase {
    func testQAPathsStayInsideTheQABaseAndBundle() {
        let base = URL(fileURLWithPath: "/qa-data", isDirectory: true)
        let bundle = URL(fileURLWithPath: "/qa-app", isDirectory: true)

        let paths = ClaudeCodeIntegrationPaths.isolatedQA(
            base: base,
            bundleURL: bundle
        )

        XCTAssertEqual(
            paths.executableCandidates,
            [bundle.appendingPathComponent(
                "Contents/Helpers/CodexLimitsClaudeRelay"
            )]
        )
        XCTAssertEqual(
            paths.settingsURL,
            base.appendingPathComponent("Fixtures/ClaudeCode/settings.json")
        )
        XCTAssertEqual(
            paths.dataDirectory,
            base.appendingPathComponent(
                "Integrations/ClaudeCode",
                isDirectory: true
            )
        )
        XCTAssertEqual(paths.helperURL, paths.executableCandidates[0])
    }

    func testSevenDayResetExpiresThePrimaryMetricEvenWhenFiveHourIsStillValid() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = ClaudeAllowanceSnapshot(
            observedAt: now.addingTimeInterval(-60),
            cliVersion: "2.1.92",
            fiveHour: ClaudeAllowanceWindowSnapshot(
                remainingPercent: 80,
                resetsAt: now.addingTimeInterval(60)
            ),
            sevenDay: ClaudeAllowanceWindowSnapshot(
                remainingPercent: 40,
                resetsAt: now
            )
        )

        XCTAssertEqual(snapshot.displayFreshness(now: now), .expired)
    }

    func testFreshnessFallsBackToFiveHourWhenSevenDayIsMissing() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = ClaudeAllowanceSnapshot(
            observedAt: now.addingTimeInterval(-31 * 60),
            cliVersion: "2.1.92",
            fiveHour: ClaudeAllowanceWindowSnapshot(
                remainingPercent: 80,
                resetsAt: now.addingTimeInterval(60)
            ),
            sevenDay: nil
        )

        XCTAssertEqual(snapshot.displayFreshness(now: now), .stale)
    }

    @MainActor
    func testDisableSuppressesAnInFlightReadinessResult() async throws {
        let fixture = try fixture(settings: [
            "payload": Array(repeating: "x", count: 200_000)
        ])
        let service = ClaudeCodeSetupService(paths: fixture.paths)
        let store = ClaudeCodeIntegrationStore(
            isEnabled: false,
            service: service
        )
        var readinessValues: [ClaudeCodeReadiness] = []
        let observation = store.$readiness.sink {
            readinessValues.append($0)
        }
        defer { observation.cancel() }

        let enabling = Task { @MainActor in
            await store.setEnabled(true)
        }
        while store.readiness != .checking {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(1))
        let probe = ClaudeServiceProbe()
        let queuedProbe = Task {
            _ = await service.hasStoredData()
            await probe.complete()
        }
        try await Task.sleep(for: .milliseconds(1))
        let probeCompletedEarly = await probe.isComplete
        XCTAssertFalse(probeCompletedEarly)

        await store.setEnabled(false)
        await enabling.value
        await queuedProbe.value

        XCTAssertEqual(store.readiness, .disabled)
        XCTAssertFalse(readinessValues.contains(.setUp))
    }

    @MainActor
    func testUnselectedHiddenClaudeDefersCacheReadUntilVisible() async throws {
        let fixture = try fixture(settings: [:])
        try FileManager.default.createDirectory(
            at: fixture.paths.dataDirectory,
            withIntermediateDirectories: true
        )
        let snapshot = ClaudeAllowanceSnapshot(
            observedAt: Date(),
            cliVersion: "2.1.231",
            fiveHour: ClaudeAllowanceWindowSnapshot(
                remainingPercent: 80,
                resetsAt: Date().addingTimeInterval(3_600)
            ),
            sevenDay: nil
        )
        try JSONEncoder().encode(snapshot).write(to: fixture.paths.cacheURL)
        let store = ClaudeCodeIntegrationStore(
            isEnabled: true,
            menuBarSourceActive: false,
            service: ClaudeCodeSetupService(paths: fixture.paths)
        )

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.readiness, .checking)

        await store.setVisible(true)

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(store.readiness, .setUp)
    }

    @MainActor
    func testHidingClaudeSuppressesQueuedVisibleRead() async throws {
        let fixture = try fixture(settings: [:])
        let coordinator = IntegrationWorkCoordinator()
        let gate = ClaudeCoordinatorGate()
        let blocker = Task {
            await coordinator.run(priority: .explicit) {
                await gate.hold()
            }
        }
        while !(await gate.started) {
            await Task.yield()
        }
        let store = ClaudeCodeIntegrationStore(
            isEnabled: true,
            menuBarSourceActive: false,
            service: ClaudeCodeSetupService(paths: fixture.paths),
            integrationWorkCoordinator: coordinator
        )
        let showing = Task { @MainActor in
            await store.setVisible(true)
        }
        try await Task.sleep(for: .milliseconds(10))

        await store.setVisible(false)
        await gate.release()
        await blocker.value
        await showing.value
        XCTAssertEqual(store.readiness, .checking)

        await store.setVisible(true)
        XCTAssertEqual(store.readiness, .setUp)
    }

    func testSetupPreservesSettingsAndExactDeactivateRemovesOnlyOwnedStatusLine() async throws {
        let fixture = try fixture(settings: ["model": "sonnet"])
        let service = ClaudeCodeSetupService(paths: fixture.paths)

        let installed = try await service.setUp()
        XCTAssertEqual(installed.readiness, .waitingForData)
        var settings = try settingsObject(at: fixture.paths.settingsURL)
        XCTAssertEqual(settings["model"] as? String, "sonnet")
        XCTAssertNotNil(settings["statusLine"])

        let didDeactivate = await service.deactivate()
        XCTAssertTrue(didDeactivate)
        settings = try settingsObject(at: fixture.paths.settingsURL)
        XCTAssertEqual(settings["model"] as? String, "sonnet")
        XCTAssertNil(settings["statusLine"])
    }

    func testDeactivateRemovesASettingsFileCreatedBySetup() async throws {
        let fixture = try fixture(settings: nil)
        let service = ClaudeCodeSetupService(paths: fixture.paths)

        _ = try await service.setUp()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.settingsURL.path
        ))

        let didDeactivate = await service.deactivate()

        XCTAssertTrue(didDeactivate)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.settingsURL.path
        ))
    }

    func testDeactivateKeepsSettingsAddedAfterSetupCreatedTheFile() async throws {
        let fixture = try fixture(settings: nil)
        let service = ClaudeCodeSetupService(paths: fixture.paths)
        _ = try await service.setUp()
        var settings = try settingsObject(at: fixture.paths.settingsURL)
        settings["model"] = "sonnet"
        try JSONSerialization.data(withJSONObject: settings).write(
            to: fixture.paths.settingsURL,
            options: .atomic
        )

        let didDeactivate = await service.deactivate()

        XCTAssertTrue(didDeactivate)
        settings = try settingsObject(at: fixture.paths.settingsURL)
        XCTAssertEqual(settings["model"] as? String, "sonnet")
        XCTAssertNil(settings["statusLine"])
    }

    func testSetupRefusesUserOwnedStatusLineWithoutChangingIt() async throws {
        let owned: [String: Any] = [
            "type": "command",
            "command": "user-status",
            "padding": 2
        ]
        let fixture = try fixture(settings: ["statusLine": owned])
        let before = try Data(contentsOf: fixture.paths.settingsURL)
        let service = ClaudeCodeSetupService(paths: fixture.paths)

        let inspection = await service.inspect()
        XCTAssertEqual(inspection.readiness, .conflict)
        do {
            _ = try await service.setUp()
            XCTFail("Expected a status-line conflict")
        } catch ClaudeCodeSetupService.SetupError.conflict {
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.settingsURL), before)
    }

    func testDeactivateLeavesModifiedOwnedConfigurationAndStopsWrites() async throws {
        let fixture = try fixture(settings: [:])
        let service = ClaudeCodeSetupService(paths: fixture.paths)
        _ = try await service.setUp()
        var settings = try settingsObject(at: fixture.paths.settingsURL)
        var statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        statusLine["padding"] = 1
        settings["statusLine"] = statusLine
        try JSONSerialization.data(withJSONObject: settings).write(
            to: fixture.paths.settingsURL,
            options: .atomic
        )

        let didDeactivate = await service.deactivate()
        XCTAssertFalse(didDeactivate)
        XCTAssertNotNil(
            try settingsObject(at: fixture.paths.settingsURL)["statusLine"]
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.enabledMarkerURL.path
        ))
    }

    func testDeleteDataRemovesOnlyOwnedSettingsAndFiles() async throws {
        let fixture = try fixture(settings: ["model": "sonnet"])
        let service = ClaudeCodeSetupService(paths: fixture.paths)
        _ = try await service.setUp()
        let snapshot = ClaudeAllowanceSnapshot(
            observedAt: Date(),
            cliVersion: "2.1.231",
            fiveHour: nil,
            sevenDay: ClaudeAllowanceWindowSnapshot(
                remainingPercent: 50,
                resetsAt: Date().addingTimeInterval(3_600)
            )
        )
        try JSONEncoder().encode(snapshot).write(to: fixture.paths.cacheURL)
        let readyInspection = await service.inspect()
        XCTAssertEqual(readyInspection.readiness, .ready)

        let deleted = await service.deleteData()
        XCTAssertTrue(deleted)
        let settings = try settingsObject(at: fixture.paths.settingsURL)
        XCTAssertEqual(settings["model"] as? String, "sonnet")
        XCTAssertNil(settings["statusLine"])
        let hasStoredData = await service.hasStoredData()
        XCTAssertFalse(hasStoredData)
    }

    func testDeletionWaitsForAnActiveRelayAndKeepsItsLockInode() async throws {
        let fixture = try fixture(settings: [:])
        let service = ClaudeCodeSetupService(paths: fixture.paths)
        _ = try await service.setUp()
        let lockURL = fixture.paths.cacheURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let inode = try FileManager.default.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber
        let deleting = Task { await service.deleteData() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while FileManager.default.fileExists(atPath: fixture.paths.enabledMarkerURL.path),
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.enabledMarkerURL.path))

        // A relay past the marker check can still finish its write under this lock.
        try Data("in-flight snapshot".utf8).write(to: fixture.paths.cacheURL)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let deleted = await deleting.value

        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.cacheURL.path))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber,
            inode
        )
    }

    func testSetupSupersedesDeletionWaitingForARelay() async throws {
        let fixture = try fixture(settings: [:])
        let service = ClaudeCodeSetupService(paths: fixture.paths)
        _ = try await service.setUp()
        let lockURL = fixture.paths.cacheURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let deleting = Task { await service.deleteData() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while FileManager.default.fileExists(atPath: fixture.paths.enabledMarkerURL.path),
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.enabledMarkerURL.path))

        _ = try await service.setUp()
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let deleted = await deleting.value

        XCTAssertFalse(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.enabledMarkerURL.path))
        XCTAssertNotNil(try settingsObject(at: fixture.paths.settingsURL)["statusLine"])
    }

    @MainActor
    func testReadFailureAndMissingCLIPreserveTheLastSnapshot() async throws {
        let fixture = try fixture(settings: [:])
        let service = ClaudeCodeSetupService(paths: fixture.paths)
        _ = try await service.setUp()
        let snapshot = ClaudeAllowanceSnapshot(
            observedAt: Date(),
            cliVersion: "2.1.231",
            fiveHour: nil,
            sevenDay: ClaudeAllowanceWindowSnapshot(
                remainingPercent: 50,
                resetsAt: Date().addingTimeInterval(3_600)
            )
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fixture.paths.cacheURL)
        let store = ClaudeCodeIntegrationStore(
            isEnabled: true,
            menuBarSourceActive: false,
            service: service
        )
        await store.setVisible(true)
        XCTAssertEqual(store.displayFreshness, .fresh)

        try Data("invalid cache".utf8).write(to: fixture.paths.cacheURL)
        await store.checkForNewObservation()
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(store.readiness, .failed)
        XCTAssertEqual(store.displayFreshness, .stale)
        await store.settingsPresented()
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(store.displayFreshness, .stale)

        try data.write(to: fixture.paths.cacheURL)
        await store.checkForNewObservation()
        XCTAssertEqual(store.readiness, .ready)
        XCTAssertEqual(store.displayFreshness, .fresh)

        try FileManager.default.removeItem(at: fixture.paths.executableCandidates[0])
        await store.settingsPresented()
        XCTAssertEqual(store.readiness, .notFound)
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(store.displayFreshness, .stale)
    }

    func testSelectedExecutableMustBeARegularExecutableFile() async throws {
        let fixture = try fixture(settings: [:])
        let service = ClaudeCodeSetupService(
            paths: ClaudeCodeIntegrationPaths(
                executableCandidates: [],
                settingsURL: fixture.paths.settingsURL,
                dataDirectory: fixture.paths.dataDirectory,
                helperURL: fixture.paths.helperURL
            )
        )
        let plainFile = fixture.root.appendingPathComponent("not-executable")
        try Data().write(to: plainFile)

        let missingInspection = await service.inspect()
        XCTAssertEqual(missingInspection.readiness, .notFound)
        let rejected = await service.selectExecutable(plainFile)
        XCTAssertNil(rejected)
        let inspection = await service.selectExecutable(
            fixture.paths.executableCandidates[0]
        )
        XCTAssertEqual(inspection?.readiness, .setUp)
    }

    func testUpdateRequiredPreservesACompatibleSnapshot() async throws {
        let fixture = try fixture(settings: [:])
        try FileManager.default.createDirectory(
            at: fixture.paths.dataDirectory,
            withIntermediateDirectories: true
        )
        let snapshot = ClaudeAllowanceSnapshot(
            observedAt: Date(),
            cliVersion: "2.1.231",
            fiveHour: ClaudeAllowanceWindowSnapshot(
                remainingPercent: 75,
                resetsAt: Date().addingTimeInterval(3_600)
            ),
            sevenDay: nil
        )
        try JSONEncoder().encode(snapshot).write(to: fixture.paths.cacheURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.paths.helperURL.path
        )

        let inspection = await ClaudeCodeSetupService(
            paths: fixture.paths
        ).inspect()

        XCTAssertEqual(inspection.readiness, .updateRequired)
        XCTAssertEqual(inspection.snapshot, snapshot)
    }

    private func fixture(
        settings: [String: Any]?
    ) throws -> (paths: ClaudeCodeIntegrationPaths, root: URL) {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let executable = root.appendingPathComponent("claude")
        let helper = root.appendingPathComponent("relay")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let settingsURL = root.appendingPathComponent("settings.json")
        if let settings {
            try JSONSerialization.data(withJSONObject: settings).write(
                to: settingsURL
            )
        }
        return (
            ClaudeCodeIntegrationPaths(
                executableCandidates: [executable],
                settingsURL: settingsURL,
                dataDirectory: root.appendingPathComponent("data", isDirectory: true),
                helperURL: helper
            ),
            root
        )
    }

    private func settingsObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
    }
}

private actor ClaudeServiceProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

private actor ClaudeCoordinatorGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
