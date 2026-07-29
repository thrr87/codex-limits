import Foundation
import XCTest
@testable import CodexLimits

@MainActor
final class ResetReminderTests: XCTestCase {
    func testDefaultsToOffAndTwentyFourHours() {
        let fixture = makeFixture()

        XCTAssertFalse(fixture.coordinator.state.isEnabled)
        XCTAssertEqual(fixture.coordinator.state.leadTime, .hours24)
        XCTAssertEqual(fixture.coordinator.state.delivery, .off)
        XCTAssertTrue(fixture.scheduler.events.isEmpty)
    }

    func testEnablingRequestsPermissionAndSchedulesTwentyFourHoursBeforeExpiry() async {
        let fixture = makeFixture(authorization: .notDetermined)
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(72 * 60 * 60)
        )

        await fixture.coordinator.setEnabled(true, target: target)

        XCTAssertEqual(fixture.scheduler.events.first, .requestedPermission)
        XCTAssertEqual(
            fixture.scheduler.events.last,
            .scheduled(
                ResetReminderRequest(
                    resetID: "reset-1",
                    firesAt: fixture.now.addingTimeInterval(48 * 60 * 60),
                    expiresAt: target.expiresAt,
                    title: "Banked reset expires soon",
                    body: "A banked reset expires in 24 hours."
                )
            )
        )
        XCTAssertEqual(
            fixture.coordinator.state.delivery,
            .scheduled(fixture.now.addingTimeInterval(48 * 60 * 60))
        )
    }

    func testPermissionDenialKeepsSettingOnAndExplainsNoDelivery() async {
        let fixture = makeFixture(
            authorization: .notDetermined,
            requestedAuthorization: .denied
        )

        await fixture.coordinator.setEnabled(
            true,
            target: ResetReminderTarget(
                id: "reset-1",
                expiresAt: fixture.now.addingTimeInterval(48 * 60 * 60)
            )
        )

        XCTAssertTrue(fixture.coordinator.state.isEnabled)
        XCTAssertEqual(fixture.coordinator.state.authorization, .denied)
        XCTAssertEqual(fixture.coordinator.state.delivery, .permissionDenied)
        XCTAssertEqual(
            fixture.scheduler.events,
            [.requestedPermission, .cancelled]
        )
    }

    func testCustomLeadTimeReschedulesTheKnownExpiry() async {
        let fixture = makeFixture(authorization: .authorized)
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(48 * 60 * 60)
        )

        await fixture.coordinator.setEnabled(true, target: target)
        fixture.scheduler.events = []
        await fixture.coordinator.setLeadTime(.hours6, target: target)

        XCTAssertEqual(
            fixture.scheduler.events,
            [
                .scheduled(
                    ResetReminderRequest(
                        resetID: "reset-1",
                        firesAt: fixture.now.addingTimeInterval(42 * 60 * 60),
                        expiresAt: target.expiresAt,
                        title: "Banked reset expires soon",
                        body: "A banked reset expires in 6 hours."
                    )
                )
            ]
        )
        XCTAssertEqual(fixture.coordinator.state.leadTime, .hours6)
    }

    func testSameFreshSnapshotDoesNotCreateADuplicate() async {
        let fixture = makeFixture(authorization: .authorized)
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(48 * 60 * 60)
        )

        await fixture.coordinator.setEnabled(true, target: target)
        fixture.scheduler.events = []
        await fixture.coordinator.reconcile(target: target)

        XCTAssertTrue(fixture.scheduler.events.isEmpty)
    }

    func testChangedExpiryReplacesTheReminder() async {
        let fixture = makeFixture(authorization: .authorized)
        let original = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(48 * 60 * 60)
        )
        let changed = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(72 * 60 * 60)
        )

        await fixture.coordinator.setEnabled(true, target: original)
        fixture.scheduler.events = []
        await fixture.coordinator.reconcile(target: changed)

        XCTAssertEqual(
            fixture.scheduler.events,
            [
                .scheduled(
                    ResetReminderRequest(
                        resetID: "reset-1",
                        firesAt: fixture.now.addingTimeInterval(48 * 60 * 60),
                        expiresAt: changed.expiresAt,
                        title: "Banked reset expires soon",
                        body: "A banked reset expires in 24 hours."
                    )
                )
            ]
        )
    }

    func testUseRemovalAndExpiryCancelWithoutTurningThePreferenceOff() async {
        let fixture = makeFixture(authorization: .authorized)
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(48 * 60 * 60)
        )
        await fixture.coordinator.setEnabled(true, target: target)
        fixture.scheduler.events = []

        await fixture.coordinator.reconcile(target: nil)

        XCTAssertEqual(fixture.scheduler.events, [.cancelled])
        XCTAssertTrue(fixture.coordinator.state.isEnabled)
        XCTAssertEqual(fixture.coordinator.state.delivery, .waitingForExpiry)

        fixture.scheduler.events = []
        await fixture.coordinator.reconcile(
            target: ResetReminderTarget(
                id: "expired",
                expiresAt: fixture.now.addingTimeInterval(-1)
            )
        )
        XCTAssertEqual(fixture.scheduler.events, [.cancelled])
        XCTAssertEqual(fixture.coordinator.state.delivery, .waitingForExpiry)
    }

    func testRestartKeepsOnePendingReminderWithoutRequestingPermissionAgain() async {
        let fixture = makeFixture(authorization: .authorized)
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(48 * 60 * 60)
        )
        await fixture.coordinator.setEnabled(true, target: target)

        let restartedScheduler = RecordingResetReminderScheduler(
            authorization: .authorized,
            pendingFireDate: fixture.now.addingTimeInterval(24 * 60 * 60)
        )
        let restarted = ResetReminderCoordinator(
            defaults: fixture.defaults,
            scheduler: restartedScheduler,
            now: { fixture.now }
        )
        await restarted.reconcile(target: target)

        XCTAssertTrue(restarted.state.isEnabled)
        XCTAssertTrue(restartedScheduler.events.isEmpty)
        XCTAssertEqual(
            restarted.state.delivery,
            .scheduled(fixture.now.addingTimeInterval(24 * 60 * 60))
        )
    }

    func testRestartRepairsAMissingFutureSystemRequest() async {
        let fixture = makeFixture(authorization: .authorized)
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(48 * 60 * 60)
        )
        await fixture.coordinator.setEnabled(true, target: target)

        let restartedScheduler = RecordingResetReminderScheduler(
            authorization: .authorized
        )
        let restarted = ResetReminderCoordinator(
            defaults: fixture.defaults,
            scheduler: restartedScheduler,
            now: { fixture.now }
        )
        await restarted.reconcile(target: target)

        XCTAssertEqual(
            restartedScheduler.events,
            [
                .scheduled(
                    ResetReminderRequest(
                        resetID: "reset-1",
                        firesAt: fixture.now.addingTimeInterval(24 * 60 * 60),
                        expiresAt: target.expiresAt,
                        title: "Banked reset expires soon",
                        body: "A banked reset expires in 24 hours."
                    )
                )
            ]
        )
    }

    func testRestartAfterReminderTimeDoesNotSendASecondReminder() async {
        let suite = "ResetReminderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = RecordingResetReminderScheduler(
            authorization: .authorized
        )
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: now.addingTimeInterval(48 * 60 * 60)
        )
        let first = ResetReminderCoordinator(
            defaults: defaults,
            scheduler: scheduler,
            now: { now }
        )
        await first.setEnabled(true, target: target)
        scheduler.events = []
        scheduler.pendingFireDate = nil
        now = now.addingTimeInterval(25 * 60 * 60)

        let restarted = ResetReminderCoordinator(
            defaults: defaults,
            scheduler: scheduler,
            now: { now }
        )
        await restarted.reconcile(target: target)

        XCTAssertTrue(scheduler.events.isEmpty)
        XCTAssertEqual(
            restarted.state.delivery,
            .reminderTimePassed(
                Date(timeIntervalSince1970: 1_800_000_000)
                    .addingTimeInterval(24 * 60 * 60)
            )
        )
    }

    func testLeadTimeChangeAfterReminderTimeDoesNotSendAgain() async {
        let suite = "ResetReminderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = RecordingResetReminderScheduler(
            authorization: .authorized
        )
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: now.addingTimeInterval(48 * 60 * 60)
        )
        let coordinator = ResetReminderCoordinator(
            defaults: defaults,
            scheduler: scheduler,
            now: { now }
        )
        await coordinator.setEnabled(true, target: target)
        scheduler.events = []
        scheduler.pendingFireDate = nil
        now = now.addingTimeInterval(25 * 60 * 60)

        await coordinator.setLeadTime(.hours6, target: target)

        XCTAssertTrue(scheduler.events.isEmpty)
        XCTAssertEqual(coordinator.state.leadTime, .hours6)
        XCTAssertEqual(
            coordinator.state.delivery,
            .reminderTimePassed(
                Date(timeIntervalSince1970: 1_800_000_000)
                    .addingTimeInterval(24 * 60 * 60)
            )
        )
    }

    func testStartupRepairsMissingFutureRequestWhenFirstAccountReadFails() async {
        let fixture = makeFixture(authorization: .authorized)
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(48 * 60 * 60)
        )
        await fixture.coordinator.setEnabled(true, target: target)
        let restartedScheduler = RecordingResetReminderScheduler(
            authorization: .authorized
        )
        let root = temporaryDirectory()
        let monitor = UsageMonitor(
            defaults: fixture.defaults,
            historyDirectory: root,
            startsAutomatically: false,
            resetReminderScheduler: restartedScheduler,
            resetReminderNow: { fixture.now },
            fetchUsage: { throw ResetReminderFetchError() }
        )

        await monitor.start()

        XCTAssertEqual(
            restartedScheduler.events,
            [
                .scheduled(
                    ResetReminderRequest(
                        resetID: "reset-1",
                        firesAt: fixture.now.addingTimeInterval(24 * 60 * 60),
                        expiresAt: target.expiresAt,
                        title: "Banked reset expires soon",
                        body: "A banked reset expires in 24 hours."
                    )
                )
            ]
        )
        XCTAssertEqual(
            monitor.resetReminderState.delivery,
            .scheduled(fixture.now.addingTimeInterval(24 * 60 * 60))
        )
    }

    func testOlderEnableCannotScheduleAfterTheUserTurnsReminderOff() async {
        let fixture = makeFixture(authorization: .authorized)
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(48 * 60 * 60)
        )
        fixture.scheduler.suspendAuthorizationRead = true

        let enabling = Task {
            await fixture.coordinator.setEnabled(true, target: target)
        }
        while !fixture.scheduler.isAuthorizationReadSuspended {
            await Task.yield()
        }
        await fixture.coordinator.setEnabled(false, target: target)
        fixture.scheduler.resumeAuthorizationRead()
        await enabling.value

        XCTAssertFalse(fixture.coordinator.state.isEnabled)
        XCTAssertEqual(fixture.coordinator.state.delivery, .off)
        XCTAssertNil(fixture.scheduler.pendingFireDate)
        XCTAssertFalse(
            fixture.scheduler.events.contains {
                if case .scheduled = $0 { return true }
                return false
            }
        )
    }

    func testDisablingCancelsAndClearsTheStoredSchedule() async {
        let fixture = makeFixture(authorization: .authorized)
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(48 * 60 * 60)
        )
        await fixture.coordinator.setEnabled(true, target: target)
        fixture.scheduler.events = []

        await fixture.coordinator.setEnabled(false, target: target)

        XCTAssertEqual(fixture.scheduler.events, [.cancelled])
        XCTAssertEqual(fixture.coordinator.state.delivery, .off)

        fixture.scheduler.events = []
        await fixture.coordinator.setEnabled(true, target: target)
        XCTAssertEqual(fixture.scheduler.events.count, 1)
    }

    func testInsideLeadWindowSchedulesOnceSoonWithActualTimeToExpiry() async {
        let fixture = makeFixture(authorization: .authorized)
        let target = ResetReminderTarget(
            id: "reset-1",
            expiresAt: fixture.now.addingTimeInterval(90 * 60)
        )

        await fixture.coordinator.setEnabled(true, target: target)

        XCTAssertEqual(
            fixture.scheduler.events,
            [
                .scheduled(
                    ResetReminderRequest(
                        resetID: "reset-1",
                        firesAt: fixture.now.addingTimeInterval(1),
                        expiresAt: target.expiresAt,
                        title: "Banked reset expires soon",
                        body: "A banked reset expires in 1 hour."
                    )
                )
            ]
        )
    }

    func testFailedAccountRefreshKeepsTheLastFreshReminder() async throws {
        let fixture = makeFixture(authorization: .authorized)
        let root = temporaryDirectory()
        let fetch = ResetReminderFetchFixture(
            result: CodexFetchResult(
                snapshot: UsageSnapshot(
                    mainLimit: nil,
                    otherLimits: [],
                    tokenHistory: [],
                    emergencyResetCount: 1,
                    bankedResetDetails: [
                        BankedResetDetail(
                            id: "reset-1",
                            resetType: "full",
                            status: "available",
                            grantedAt: nil,
                            expiresAt: fixture.now.addingTimeInterval(
                                48 * 60 * 60
                            ),
                            title: nil,
                            description: nil
                        )
                    ],
                    fetchedAt: fixture.now
                ),
                account: .stable(identity: "account-1")
            )
        )
        let monitor = UsageMonitor(
            defaults: fixture.defaults,
            historyDirectory: root,
            startsAutomatically: false,
            resetReminderScheduler: fixture.scheduler,
            resetReminderNow: { fixture.now },
            fetchUsage: { try fetch.read() }
        )

        await monitor.refresh()
        await monitor.setResetReminderEnabled(true)
        fixture.scheduler.events = []
        fetch.shouldFail = true
        await monitor.refresh()

        XCTAssertTrue(fixture.scheduler.events.isEmpty)
        XCTAssertEqual(
            monitor.resetReminderState.delivery,
            .scheduled(fixture.now.addingTimeInterval(24 * 60 * 60))
        )
    }

    private func makeFixture(
        authorization: ResetReminderAuthorization = .notDetermined,
        requestedAuthorization: ResetReminderAuthorization = .authorized
    ) -> Fixture {
        let suite = "ResetReminderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let scheduler = RecordingResetReminderScheduler(
            authorization: authorization,
            requestedAuthorization: requestedAuthorization
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return Fixture(
            coordinator: ResetReminderCoordinator(
                defaults: defaults,
                scheduler: scheduler,
                now: { now }
            ),
            scheduler: scheduler,
            defaults: defaults,
            now: now
        )
    }
}

@MainActor
private struct Fixture {
    let coordinator: ResetReminderCoordinator
    let scheduler: RecordingResetReminderScheduler
    let defaults: UserDefaults
    let now: Date
}

@MainActor
private final class RecordingResetReminderScheduler: ResetReminderScheduling {
    enum Event: Equatable {
        case requestedPermission
        case scheduled(ResetReminderRequest)
        case cancelled
    }

    var events: [Event] = []
    var pendingFireDate: Date?
    var suspendAuthorizationRead = false
    private(set) var isAuthorizationReadSuspended = false
    private var authorization: ResetReminderAuthorization
    private let requestedAuthorization: ResetReminderAuthorization
    private var authorizationContinuation:
        CheckedContinuation<Void, Never>?

    init(
        authorization: ResetReminderAuthorization,
        requestedAuthorization: ResetReminderAuthorization = .authorized,
        pendingFireDate: Date? = nil
    ) {
        self.authorization = authorization
        self.requestedAuthorization = requestedAuthorization
        self.pendingFireDate = pendingFireDate
    }

    func authorizationStatus() async -> ResetReminderAuthorization {
        if suspendAuthorizationRead {
            isAuthorizationReadSuspended = true
            await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
            }
            isAuthorizationReadSuspended = false
        }
        return authorization
    }

    func requestAuthorization() async throws -> ResetReminderAuthorization {
        events.append(.requestedPermission)
        authorization = requestedAuthorization
        return authorization
    }

    func pendingReminderFireDate() async -> Date? {
        pendingFireDate
    }

    func schedule(_ request: ResetReminderRequest) async throws {
        pendingFireDate = request.firesAt
        events.append(.scheduled(request))
    }

    func cancel() async {
        pendingFireDate = nil
        events.append(.cancelled)
    }

    func resumeAuthorizationRead() {
        suspendAuthorizationRead = false
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }
}

@MainActor
private final class ResetReminderFetchFixture {
    let result: CodexFetchResult
    var shouldFail = false

    init(result: CodexFetchResult) {
        self.result = result
    }

    func read() throws -> CodexFetchResult {
        if shouldFail {
            throw ResetReminderFetchError()
        }
        return result
    }
}

private struct ResetReminderFetchError: Error {}
