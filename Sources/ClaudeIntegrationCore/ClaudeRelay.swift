import Darwin
import Foundation

public struct ClaudeAllowanceWindowSnapshot: Codable, Equatable, Sendable {
    public let remainingPercent: Double
    public let resetsAt: Date

    public init(remainingPercent: Double, resetsAt: Date) {
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }
}

public struct ClaudeAllowanceSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let observedAt: Date
    public let cliVersion: String?
    public let fiveHour: ClaudeAllowanceWindowSnapshot?
    public let sevenDay: ClaudeAllowanceWindowSnapshot?
    public let historyWriteFailed: Bool?

    public init(
        version: Int = 1,
        observedAt: Date,
        cliVersion: String?,
        fiveHour: ClaudeAllowanceWindowSnapshot?,
        sevenDay: ClaudeAllowanceWindowSnapshot?,
        historyWriteFailed: Bool? = nil
    ) {
        self.version = version
        self.observedAt = observedAt
        self.cliVersion = cliVersion
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.historyWriteFailed = historyWriteFailed
    }

    public var historyObservations: [AllowanceObservation] {
        [
            ("claude-seven-day", sevenDay, 7 * 86_400.0),
            ("claude-five-hour", fiveHour, 5 * 3_600.0)
        ].compactMap { metric, window, duration in
            guard let window else { return nil }
            let observation = AllowanceObservation(
                metric: metric,
                observedAt: observedAt,
                remainingPercent: window.remainingPercent,
                resetsAt: window.resetsAt,
                startsAt: window.resetsAt.addingTimeInterval(-duration),
                source: "statusLine.rate_limits"
            )
            return observation.isValid ? observation : nil
        }
    }
}

public enum ClaudeRelayError: Error, Equatable {
    case inputTooLarge
    case invalidInput
    case noAllowance
    case disabled
    case lockUnavailable
}

public enum ClaudeRelay {
    public static let snapshotChangedNotificationName =
        "com.github.thrr87.CodexLimits.ClaudeSnapshotChanged"
    public static let maximumInputBytes = 256 * 1_024
    public static let maximumCacheBytes = 64 * 1_024
    public static let equivalentWriteInterval: TimeInterval = 30
    public static let unavailableStatusLine = "Usage unavailable"

    public static func readBoundedInput(
        from handle: FileHandle
    ) throws -> Data {
        var input = Data()
        while input.count < maximumInputBytes + 1 {
            let remaining = maximumInputBytes + 1 - input.count
            guard let chunk = try handle.read(
                upToCount: min(64 * 1_024, remaining)
            ), !chunk.isEmpty else {
                break
            }
            input.append(chunk)
        }
        return input
    }

    public static func decode(
        _ data: Data,
        observedAt: Date
    ) throws -> ClaudeAllowanceSnapshot {
        guard data.count <= maximumInputBytes else {
            throw ClaudeRelayError.inputTooLarge
        }
        let input: Input
        do {
            input = try JSONDecoder().decode(Input.self, from: data)
        } catch {
            throw ClaudeRelayError.invalidInput
        }
        let fiveHour = try window(input.rateLimits?.fiveHour)
        let sevenDay = try window(input.rateLimits?.sevenDay)
        guard fiveHour != nil || sevenDay != nil else {
            throw ClaudeRelayError.noAllowance
        }
        return ClaudeAllowanceSnapshot(
            observedAt: observedAt,
            cliVersion: acceptedVersion(input.version),
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    public static func statusLine(
        for snapshot: ClaudeAllowanceSnapshot
    ) -> String {
        var values: [String] = []
        if let sevenDay = snapshot.sevenDay {
            values.append(
                "7d \(Int(sevenDay.remainingPercent.rounded()))% remaining"
            )
        }
        if let fiveHour = snapshot.fiveHour {
            values.append(
                "5h \(Int(fiveHour.remainingPercent.rounded()))% remaining"
            )
        }
        return values.joined(separator: " · ")
    }

    public static func storeIfNewer(
        _ snapshot: ClaudeAllowanceSnapshot,
        at cacheURL: URL,
        enabledMarkerURL: URL,
        now: () -> Date = { Date() }
    ) throws -> Bool {
        guard let markerIdentity = enabledMarkerIdentity(at: enabledMarkerURL) else {
            throw ClaudeRelayError.disabled
        }
        return try withCacheLock(at: cacheURL, waits: true) {
            guard enabledMarkerIdentity(at: enabledMarkerURL) == markerIdentity else {
                throw ClaudeRelayError.disabled
            }
            let wallTime = now()
            guard snapshot.observedAt <= wallTime.addingTimeInterval(AllowanceHistory.maximumObservationClockSkew) else {
                throw ClaudeRelayError.invalidInput
            }
            let existing = try? readSnapshot(at: cacheURL, now: wallTime)
            if let existing {
                if existing.observedAt >= snapshot.observedAt {
                    return false
                }
                if existing.cliVersion == snapshot.cliVersion,
                   existing.fiveHour == snapshot.fiveHour,
                   existing.sevenDay == snapshot.sevenDay,
                   snapshot.observedAt.timeIntervalSince(existing.observedAt)
                    < equivalentWriteInterval {
                    return false
                }
            }
            var historyFailed = false
            do {
                try AllowanceHistory.append(
                    (existing?.historyObservations ?? []) + snapshot.historyObservations,
                    in: historyDirectory(for: cacheURL), now: now
                )
            } catch {
                historyFailed = true
            }
            let stored = ClaudeAllowanceSnapshot(
                version: snapshot.version,
                observedAt: snapshot.observedAt,
                cliVersion: snapshot.cliVersion,
                fiveHour: snapshot.fiveHour,
                sevenDay: snapshot.sevenDay,
                historyWriteFailed: historyFailed ? true : nil
            )
            let data = try JSONEncoder().encode(stored)
            guard data.count <= maximumCacheBytes else {
                throw ClaudeRelayError.invalidInput
            }
            try data.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: cacheURL.path
            )
            return true
        }
    }

    public static func deleteSnapshotIfIdle(at cacheURL: URL) throws {
        try withCacheLock(at: cacheURL, waits: false) {
            try AllowanceHistory.delete(in: historyDirectory(for: cacheURL))
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                try FileManager.default.removeItem(at: cacheURL)
            }
        }
    }

    public static func historyDirectory(for cacheURL: URL) -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("History", isDirectory: true)
    }

    private static func withCacheLock<T>(
        at cacheURL: URL,
        waits: Bool,
        operation: () throws -> T
    ) throws -> T {
        // Keep this empty lock file: waiting relays may hold its inode after deletion.
        let lockURL = cacheURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ClaudeRelayError.lockUnavailable }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX | (waits ? 0 : LOCK_NB)) == 0 else {
            throw ClaudeRelayError.lockUnavailable
        }
        return try operation()
    }

    private static func enabledMarkerIdentity(at url: URL) -> NSObject? {
        var uncachedURL = url
        uncachedURL.removeAllCachedResourceValues()
        let values = try? uncachedURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        return values?.fileResourceIdentifier as? NSObject
    }

    public static func readSnapshot(at cacheURL: URL, now: Date = Date()) throws
        -> ClaudeAllowanceSnapshot {
        let value = try JSONDecoder().decode(
            ClaudeAllowanceSnapshot.self,
            from: checkedCacheData(at: cacheURL)
        )
        guard value.version == 1,
              value.observedAt.timeIntervalSinceReferenceDate.isFinite,
              value.observedAt <= now.addingTimeInterval(AllowanceHistory.maximumObservationClockSkew),
              value.cliVersion == acceptedVersion(value.cliVersion),
              value.fiveHour != nil || value.sevenDay != nil,
              value.fiveHour.map(isValid) ?? true,
              value.sevenDay.map(isValid) ?? true else {
            throw ClaudeRelayError.invalidInput
        }
        return value
    }

    private static func window(_ input: Input.Window?) throws
        -> ClaudeAllowanceWindowSnapshot? {
        guard let input else { return nil }
        guard input.usedPercentage.isFinite,
              (0 ... 100).contains(input.usedPercentage),
              input.resetsAt.isFinite else {
            throw ClaudeRelayError.invalidInput
        }
        let resetsAt = Date(timeIntervalSince1970: input.resetsAt)
        guard resetsAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ClaudeRelayError.invalidInput
        }
        return ClaudeAllowanceWindowSnapshot(
            remainingPercent: 100 - input.usedPercentage,
            resetsAt: resetsAt
        )
    }

    private static func acceptedVersion(_ version: String?) -> String? {
        guard let version,
              !version.isEmpty,
              version.utf8.count <= 64,
              version.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value <= 0x7e
              }) else {
            return nil
        }
        return version
    }

    private static func isValid(
        _ window: ClaudeAllowanceWindowSnapshot
    ) -> Bool {
        window.remainingPercent.isFinite
            && (0 ... 100).contains(window.remainingPercent)
            && window.resetsAt.timeIntervalSinceReferenceDate.isFinite
    }

    private static func checkedCacheData(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumCacheBytes else {
            throw ClaudeRelayError.invalidInput
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumCacheBytes else {
            throw ClaudeRelayError.invalidInput
        }
        return data
    }

    private struct Input: Decodable {
        let version: String?
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case version
            case rateLimits = "rate_limits"
        }

        struct RateLimits: Decodable {
            let fiveHour: Window?
            let sevenDay: Window?

            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
            }
        }

        struct Window: Decodable {
            let usedPercentage: Double
            let resetsAt: Double

            enum CodingKeys: String, CodingKey {
                case usedPercentage = "used_percentage"
                case resetsAt = "resets_at"
            }
        }
    }
}
