import Foundation
import UserNotifications

enum ResetReminderLeadTime: TimeInterval, CaseIterable, Codable, Identifiable {
    case hour1 = 3_600
    case hours6 = 21_600
    case hours12 = 43_200
    case hours24 = 86_400
    case hours48 = 172_800

    var id: TimeInterval { rawValue }

    var displayName: String {
        switch self {
        case .hour1: "1 hour"
        case .hours6: "6 hours"
        case .hours12: "12 hours"
        case .hours24: "24 hours"
        case .hours48: "48 hours"
        }
    }
}

enum ResetReminderAuthorization: Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized
}

enum ResetReminderDelivery: Equatable {
    case off
    case waitingForExpiry
    case permissionRequired
    case permissionDenied
    case scheduled(Date)
    case reminderTimePassed(Date)
    case failed
}

struct ResetReminderState: Equatable {
    let isEnabled: Bool
    let leadTime: ResetReminderLeadTime
    let authorization: ResetReminderAuthorization
    let delivery: ResetReminderDelivery

    var statusText: String {
        switch delivery {
        case .off:
            return "Off"
        case .waitingForExpiry:
            return "Waiting for an expiry."
        case .permissionRequired:
            return "Allow notifications to receive this reminder."
        case .permissionDenied:
            return "Notifications are off. No reminder will arrive."
        case let .scheduled(date):
            return "Set for \(date.formatted(date: .abbreviated, time: .shortened))."
        case .reminderTimePassed:
            return "The reminder time has passed."
        case .failed:
            return "Couldn’t set the reminder."
        }
    }

    var controlHelp: String {
        if isEnabled {
            return "\(statusText) Remind \(leadTime.displayName) before expiry."
        }
        return "Get one local notification before the next known expiry."
    }
}

struct ResetReminderTarget: Equatable, Sendable {
    let id: String
    let expiresAt: Date
}

struct ResetReminderRequest: Equatable, Sendable {
    let resetID: String
    let firesAt: Date
    let expiresAt: Date
    let title: String
    let body: String
}

@MainActor
protocol ResetReminderScheduling {
    func authorizationStatus() async -> ResetReminderAuthorization
    func requestAuthorization() async throws -> ResetReminderAuthorization
    func pendingReminderFireDate() async -> Date?
    func schedule(_ request: ResetReminderRequest) async throws
    func cancel() async
}

@MainActor
final class ResetReminderCoordinator {
    static let enabledKey = "resetReminderEnabled"
    static let leadTimeKey = "resetReminderLeadTime"

    private static let scheduledRecordKey = "resetReminderScheduledRecord"
    private let defaults: UserDefaults
    private let scheduler: any ResetReminderScheduling
    private let now: () -> Date
    private var scheduledRecord: ScheduledRecord?
    private var desiredTarget: ResetReminderTarget?
    private var mutationVersion = 0

    private(set) var state: ResetReminderState

    init(
        defaults: UserDefaults,
        scheduler: any ResetReminderScheduling,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.scheduler = scheduler
        self.now = now

        let isEnabled = defaults.bool(forKey: Self.enabledKey)
        let leadTime = Self.savedLeadTime(in: defaults)
        let scheduledRecord = defaults.data(forKey: Self.scheduledRecordKey)
            .flatMap { try? JSONDecoder().decode(ScheduledRecord.self, from: $0) }
        self.scheduledRecord = scheduledRecord
        state = ResetReminderState(
            isEnabled: isEnabled,
            leadTime: leadTime,
            authorization: .unknown,
            delivery: isEnabled
                ? scheduledRecord.map { .scheduled($0.firesAt) } ?? .waitingForExpiry
                : .off
        )
    }

    func setEnabled(_ isEnabled: Bool, target: ResetReminderTarget?) async {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        update(isEnabled: isEnabled)
        desiredTarget = target
        mutationVersion += 1
        await applyDesiredState(
            version: mutationVersion,
            mayRequestPermission: isEnabled
        )
    }

    func restore() async {
        desiredTarget = scheduledRecord.map {
            ResetReminderTarget(
                id: $0.resetID,
                expiresAt: $0.expiresAt
            )
        }
        mutationVersion += 1
        await applyDesiredState(
            version: mutationVersion,
            mayRequestPermission: false
        )
    }

    func setLeadTime(
        _ leadTime: ResetReminderLeadTime,
        target: ResetReminderTarget?
    ) async {
        defaults.set(leadTime.rawValue, forKey: Self.leadTimeKey)
        update(leadTime: leadTime)
        guard state.isEnabled else { return }
        desiredTarget = target
        mutationVersion += 1
        await applyDesiredState(
            version: mutationVersion,
            mayRequestPermission: false
        )
    }

    func reconcile(target: ResetReminderTarget?) async {
        desiredTarget = target
        mutationVersion += 1
        await applyDesiredState(
            version: mutationVersion,
            mayRequestPermission: false
        )
    }

    private func applyDesiredState(
        version: Int,
        mayRequestPermission: Bool
    ) async {
        guard version == mutationVersion else { return }
        guard state.isEnabled else {
            if scheduledRecord != nil {
                await scheduler.cancel()
                guard await continueIfCurrent(version) else { return }
                clearScheduledRecord()
            }
            update(delivery: .off)
            return
        }

        guard let target = desiredTarget, target.expiresAt > now() else {
            await scheduler.cancel()
            guard await continueIfCurrent(version) else { return }
            clearScheduledRecord()
            update(delivery: .waitingForExpiry)
            return
        }

        var authorization = await scheduler.authorizationStatus()
        guard await continueIfCurrent(version) else { return }
        if authorization == .notDetermined || authorization == .unknown {
            guard mayRequestPermission else {
                update(
                    authorization: authorization,
                    delivery: .permissionRequired
                )
                return
            }
            do {
                authorization = try await scheduler.requestAuthorization()
            } catch {
                guard await continueIfCurrent(version) else { return }
                update(authorization: authorization, delivery: .failed)
                return
            }
            guard await continueIfCurrent(version) else { return }
        }
        update(authorization: authorization)

        guard authorization == .authorized else {
            await scheduler.cancel()
            guard await continueIfCurrent(version) else { return }
            clearScheduledRecord()
            update(delivery: .permissionDenied)
            return
        }
        await schedule(target, version: version)
    }

    private func schedule(_ target: ResetReminderTarget, version: Int) async {
        let currentTime = now()
        let preferredFireDate = target.expiresAt.addingTimeInterval(
            -state.leadTime.rawValue
        )
        let firesAt = max(preferredFireDate, currentTime.addingTimeInterval(1))
        let record = ScheduledRecord(
            resetID: target.id,
            expiresAt: target.expiresAt,
            firesAt: firesAt,
            leadTime: state.leadTime
        )

        if let existingRecord = scheduledRecord,
           record.sameReset(as: existingRecord),
           existingRecord.firesAt <= currentTime {
            let pendingFireDate = await scheduler.pendingReminderFireDate()
            guard await continueIfCurrent(version) else { return }
            if pendingFireDate != nil {
                await scheduler.cancel()
                guard await continueIfCurrent(version) else {
                    return
                }
            }
            update(
                delivery: .reminderTimePassed(
                    existingRecord.firesAt
                )
            )
            return
        }

        if let existingRecord = scheduledRecord,
           record.sameReminder(as: existingRecord) {
            let pendingFireDate = await scheduler.pendingReminderFireDate()
            guard await continueIfCurrent(version) else { return }
            if let pendingFireDate,
               abs(
                   pendingFireDate.timeIntervalSince(
                       existingRecord.firesAt
                   )
               ) < 2 {
                update(delivery: .scheduled(existingRecord.firesAt))
                return
            }
        }

        let bodyTime = preferredFireDate > currentTime
            ? state.leadTime.displayName
            : Self.shortDuration(target.expiresAt.timeIntervalSince(currentTime))
        let request = ResetReminderRequest(
            resetID: target.id,
            firesAt: firesAt,
            expiresAt: target.expiresAt,
            title: "Banked reset expires soon",
            body: "A banked reset expires in \(bodyTime)."
        )
        do {
            try await scheduler.schedule(request)
            guard await continueIfCurrent(version) else { return }
            scheduledRecord = record
            if let data = try? JSONEncoder().encode(record) {
                defaults.set(data, forKey: Self.scheduledRecordKey)
            }
            update(delivery: .scheduled(firesAt))
        } catch {
            guard await continueIfCurrent(version) else { return }
            clearScheduledRecord()
            update(delivery: .failed)
        }
    }

    private func continueIfCurrent(_ version: Int) async -> Bool {
        guard version != mutationVersion else { return true }
        await applyDesiredState(
            version: mutationVersion,
            mayRequestPermission: false
        )
        return false
    }

    private func clearScheduledRecord() {
        scheduledRecord = nil
        defaults.removeObject(forKey: Self.scheduledRecordKey)
    }

    private func update(
        isEnabled: Bool? = nil,
        leadTime: ResetReminderLeadTime? = nil,
        authorization: ResetReminderAuthorization? = nil,
        delivery: ResetReminderDelivery? = nil
    ) {
        state = ResetReminderState(
            isEnabled: isEnabled ?? state.isEnabled,
            leadTime: leadTime ?? state.leadTime,
            authorization: authorization ?? state.authorization,
            delivery: delivery ?? state.delivery
        )
    }

    private static func savedLeadTime(
        in defaults: UserDefaults
    ) -> ResetReminderLeadTime {
        guard defaults.object(forKey: leadTimeKey) != nil else {
            return .hours24
        }
        return ResetReminderLeadTime(
            rawValue: defaults.double(forKey: leadTimeKey)
        ) ?? .hours24
    }

    private static func shortDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds >= 86_400 {
            let days = max(1, Int(seconds / 86_400))
            return days == 1 ? "1 day" : "\(days) days"
        }
        if seconds >= 3_600 {
            let hours = max(1, Int(seconds / 3_600))
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let minutes = max(1, Int(seconds / 60))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private struct ScheduledRecord: Codable, Equatable {
        let resetID: String
        let expiresAt: Date
        let firesAt: Date
        let leadTime: ResetReminderLeadTime

        func sameReminder(as other: ScheduledRecord?) -> Bool {
            sameReset(as: other) && leadTime == other?.leadTime
        }

        func sameReset(as other: ScheduledRecord?) -> Bool {
            resetID == other?.resetID
                && expiresAt == other?.expiresAt
        }
    }
}

@MainActor
final class UserNotificationResetReminderScheduler: ResetReminderScheduling {
    private static let requestIdentifier = "codex-limits.banked-reset-expiry"
    private let center: () -> UNUserNotificationCenter
    private let calendar: Calendar

    init(
        center: @escaping () -> UNUserNotificationCenter = {
            UNUserNotificationCenter.current()
        },
        calendar: Calendar = .current
    ) {
        self.center = center
        self.calendar = calendar
    }

    func authorizationStatus() async -> ResetReminderAuthorization {
        let settings = await center().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .unknown
        }
    }

    func requestAuthorization() async throws -> ResetReminderAuthorization {
        let granted = try await center().requestAuthorization(
            options: [.alert, .sound]
        )
        return granted ? .authorized : .denied
    }

    func pendingReminderFireDate() async -> Date? {
        let requests = await center().pendingNotificationRequests()
        let trigger = requests.first {
            $0.identifier == Self.requestIdentifier
        }?.trigger as? UNCalendarNotificationTrigger
        return trigger?.nextTriggerDate()
    }

    func schedule(_ request: ResetReminderRequest) async throws {
        let center = center()
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default

        let components = calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: request.firesAt
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: Self.requestIdentifier,
                content: content,
                trigger: trigger
            )
        )
    }

    func cancel() async {
        center().removePendingNotificationRequests(
            withIdentifiers: [Self.requestIdentifier]
        )
    }
}
