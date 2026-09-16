import Darwin
import Foundation

enum GrokBillingError: Error, LocalizedError, Equatable {
    case notFound, authenticationRequired, unsupported, missingAllowance
    case unknownPeriod, invalidReset, invalidResponse, timedOut, connectionLost, failed

    var errorDescription: String? {
        switch self {
        case .notFound: "Grok Build could not be found."
        case .authenticationRequired: "Sign in with grok login to read your usage."
        case .unsupported: "This version of Grok Build does not support usage reads."
        case .missingAllowance: "Grok did not provide usable usage data."
        case .unknownPeriod: "Grok returned an unsupported usage period."
        case .invalidReset: "Grok did not provide a valid reset date."
        case .invalidResponse: "Grok returned usage data that could not be read."
        case .timedOut: "Grok took too long to respond."
        case .connectionLost: "The connection to Grok ended before usage was received."
        case .failed: "Grok usage could not be read. Try again later."
        }
    }
}

struct GrokAllowanceSnapshot: Codable, Equatable, Sendable {
    enum Period: String, Codable, Sendable { case weekly, monthly }

    let reportedUsedPercent: Double?
    let period: Period
    let resetsAt: Date
    let observedAt: Date
    let sourceVersion: String?
    let subscriptionTier: String?
    let prepaidBalanceUSD: Double?
    let onDemandUsedUSD: Double?
    let onDemandCapUSD: Double?
    let isUnifiedBilling: Bool?
    let measurementSource: String
    let startsAt: Date?

    init(
        reportedUsedPercent: Double?,
        period: Period,
        resetsAt: Date,
        observedAt: Date,
        sourceVersion: String?,
        subscriptionTier: String?,
        prepaidBalanceUSD: Double?,
        onDemandUsedUSD: Double?,
        onDemandCapUSD: Double?,
        isUnifiedBilling: Bool?,
        measurementSource: String,
        startsAt: Date? = nil
    ) {
        self.reportedUsedPercent = reportedUsedPercent
        self.period = period
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.sourceVersion = sourceVersion
        self.subscriptionTier = subscriptionTier
        self.prepaidBalanceUSD = prepaidBalanceUSD
        self.onDemandUsedUSD = onDemandUsedUSD
        self.onDemandCapUSD = onDemandCapUSD
        self.isUnifiedBilling = isUnifiedBilling
        self.measurementSource = measurementSource
        self.startsAt = startsAt
    }

    var remainingPercent: Double? {
        reportedUsedPercent.map { 100 - min(100, max(0, $0)) }
    }

    var isValid: Bool {
        (reportedUsedPercent.map(\.isFinite) ?? (measurementSource == "creditUsagePercent"))
            && Self.isSupportedDate(observedAt)
            && Self.isSupportedDate(resetsAt)
            && resetsAt.timeIntervalSince1970 > 0
            && (startsAt.map { Self.isSupportedDate($0) && $0 < resetsAt } ?? true)
            && ["creditUsagePercent", "legacyCredits"].contains(measurementSource)
            && [prepaidBalanceUSD, onDemandUsedUSD, onDemandCapUSD]
                .allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? true }
            && sourceVersion == Self.safeText(sourceVersion, limit: 64)
            && subscriptionTier == Self.safeText(subscriptionTier, limit: 80)
    }

    static func decode(
        _ data: Data,
        observedAt: Date,
        sourceVersion: String?
    ) throws -> Self {
        guard data.count <= 1_048_576,
              isSupportedDate(observedAt),
              let result = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw GrokBillingError.invalidResponse
        }
        guard let config = result["config"] as? [String: Any] else {
            throw GrokBillingError.missingAllowance
        }
        let used: Double?
        let period: Period
        let reset: Date
        let start: Date?
        let source: String
        if config.keys.contains("creditUsagePercent")
            || config.keys.contains("currentPeriod") {
            // GrokCreditsConfig uses an implicit-presence proto3 float: omitted means zero.
            // Validate the current period below before accepting that default.
            used = config.keys.contains("creditUsagePercent") ? number(config["creditUsagePercent"]) : 0
            guard used != nil else {
                throw GrokBillingError.missingAllowance
            }
            guard let current = config["currentPeriod"] as? [String: Any] else {
                throw GrokBillingError.unknownPeriod
            }
            switch current["type"] as? String {
            case "USAGE_PERIOD_TYPE_WEEKLY": period = .weekly
            case "USAGE_PERIOD_TYPE_MONTHLY": period = .monthly
            default: throw GrokBillingError.unknownPeriod
            }
            (start, reset) = try periodDates(end: current["end"], start: current["start"])
            source = "creditUsagePercent"
        } else {
            guard let limit = cents(config["monthlyLimit"]), limit > 0,
                  let value = cents(config["used"]) else {
                throw GrokBillingError.missingAllowance
            }
            let percent = value / limit * 100
            guard percent.isFinite else { throw GrokBillingError.invalidResponse }
            used = percent
            period = .monthly
            (start, reset) = try periodDates(
                end: config["billingPeriodEnd"], start: config["billingPeriodStart"]
            )
            source = "legacyCredits"
        }
        let unified = config["isUnifiedBillingUser"] as? NSNumber
        return Self(
            reportedUsedPercent: used,
            period: period,
            resetsAt: reset,
            observedAt: observedAt,
            sourceVersion: safeText(sourceVersion, limit: 64),
            subscriptionTier: safeText(result["subscription_tier"] as? String, limit: 80),
            prepaidBalanceUSD: cents(config["prepaidBalance"]).map { $0 / 100 },
            onDemandUsedUSD: cents(config["onDemandUsed"]).map { $0 / 100 },
            onDemandCapUSD: cents(config["onDemandCap"]).map { $0 / 100 },
            isUnifiedBilling: unified.flatMap {
                CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil
            },
            measurementSource: source,
            startsAt: start
        )
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func cents(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any] else { return nil }
        // The provider's protobuf JSON omits val for a present zero-valued Cent.
        guard !object.isEmpty else { return 0 }
        guard let value = number(object["val"]), value >= 0 else { return nil }
        return value
    }

    private static func periodDates(end: Any?, start: Any?) throws -> (Date?, Date) {
        let parser = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            guard let value = value as? String, value.utf8.count <= 64 else { return nil }
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: value) { return date }
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: value)
        }
        guard let end = date(end), isSupportedDate(end), end.timeIntervalSince1970 > 0 else {
            throw GrokBillingError.invalidReset
        }
        if let start, !(start is NSNull) {
            guard let start = date(start), isSupportedDate(start), start < end else {
                throw GrokBillingError.invalidReset
            }
            return (start, end)
        }
        return (nil, end)
    }

    private static func isSupportedDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
            && date >= .distantPast && date <= .distantFuture
    }

    private static func safeText(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let clean = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && $0.properties.generalCategory != .format
        }.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

actor GrokBillingClient {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 10) {
        self.timeout = timeout.isFinite ? min(10, max(0.01, timeout)) : 10
    }

    func fetch(executableURL: URL) async throws -> GrokAllowanceSnapshot {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { [timeout] in
            try GrokBillingProcess.fetch(executableURL: executableURL, timeout: timeout)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func executableURL(selected: URL?) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ([selected].compactMap { $0 } + [
            home.appendingPathComponent(".grok/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "/usr/local/bin/grok")
        ]).first(where: isExecutable)?.resolvingSymlinksInPath()
    }

    static func isExecutable(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let resolved = url.resolvingSymlinksInPath()
        return (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?
            .isRegularFile == true
            && FileManager.default.isExecutableFile(atPath: resolved.path)
    }
}

private struct GrokBillingProcess {
    private static let maximumOutputBytes = 1_048_576

    static func fetch(executableURL: URL, timeout: TimeInterval) throws -> GrokAllowanceSnapshot {
        try Task.checkCancellation()
        guard GrokBillingClient.isExecutable(executableURL) else {
            throw GrokBillingError.notFound
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLimits-Grok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cwd, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: cwd) }
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { throw GrokBillingError.failed }
        defer { for fd in input where fd >= 0 { close(fd) } }
        guard pipe(&output) == 0 else { throw GrokBillingError.failed }
        defer { for fd in output where fd >= 0 { close(fd) } }
        for fd in input + output {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else { throw GrokBillingError.failed }
        }
        // A closed child stdin must report EPIPE instead of terminating the app.
        guard fcntl(input[1], F_SETNOSIGPIPE, 1) != -1 else { throw GrokBillingError.failed }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw GrokBillingError.failed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw GrokBillingError.failed }
        defer { posix_spawnattr_destroy(&attributes) }
        for status in [
            posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_addchdir_np(&actions, cwd.path),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        ] where status != 0 { throw GrokBillingError.failed }
        let argv = [executableURL.path, "agent", "--no-leader", "stdio"].map {
            $0.withCString { strdup($0) }
        } + [nil]
        let env = ProcessInfo.processInfo.environment.map {
            "\($0.key)=\($0.value)".withCString { strdup($0) }
        } + [nil]
        defer { for string in argv + env { free(string) } }
        let pid = try GrokProcessRegistry.shared.start { pid in
            argv.withUnsafeBufferPointer { args in
                env.withUnsafeBufferPointer { environment in
                    posix_spawn(&pid, executableURL.path, &actions, &attributes, args.baseAddress!, environment.baseAddress!)
                }
            }
        }
        close(input[0]); input[0] = -1
        close(output[1]); output[1] = -1
        defer {
            close(input[1]); input[1] = -1
            GrokProcessRegistry.shared.stop(pid)
        }
        var buffer = Data()
        var totalBytes = 0
        func checkDeadline() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GrokBillingError.timedOut }
        }
        func request(_ method: String, id: Int, params: [String: Any]) throws {
            try checkDeadline()
            var message = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "method": method, "params": params
            ], options: [.withoutEscapingSlashes])
            message.append(10)
            let written = message.withUnsafeBytes { bytes in
                Darwin.write(input[1], bytes.baseAddress, bytes.count)
            }
            guard written == message.count else { throw GrokBillingError.connectionLost }
        }
        func response(id: Int) throws -> [String: Any] {
            while true {
                try checkDeadline()
                if let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    defer { buffer.removeSubrange(...newline) }
                    guard let object = try? JSONSerialization.jsonObject(with: line)
                        as? [String: Any], object["jsonrpc"] as? String == "2.0" else {
                        throw GrokBillingError.invalidResponse
                    }
                    guard object["id"] as? Int == id else { continue }
                    if let error = object["error"] as? [String: Any] {
                        switch error["code"] as? Int {
                        case -32601: throw GrokBillingError.unsupported
                        case -32000: throw GrokBillingError.authenticationRequired
                        default: throw GrokBillingError.failed
                        }
                    }
                    guard let result = object["result"] as? [String: Any] else {
                        throw GrokBillingError.invalidResponse
                    }
                    return result
                }
                var descriptor = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 25)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else { throw GrokBillingError.connectionLost }
                guard ready > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: 8_192)
                let count = Darwin.read(output[0], &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw GrokBillingError.connectionLost }
                totalBytes += count
                guard totalBytes <= maximumOutputBytes else { throw GrokBillingError.invalidResponse }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }
        try request("initialize", id: 1, params: [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "codex-limits", "version": "1"]
        ])
        let initialized = try response(id: 1)
        guard initialized["protocolVersion"] as? Int == 1 else { throw GrokBillingError.unsupported }
        let version = (initialized["_meta"] as? [String: Any])?["agentVersion"] as? String
            ?? (initialized["agentInfo"] as? [String: Any])?["version"] as? String
        // ACP SDKs add this underscore automatically; raw JSON-RPC clients must include it.
        try request("_x.ai/billing", id: 2, params: [:])
        let result = try response(id: 2)
        return try GrokAllowanceSnapshot.decode(
            JSONSerialization.data(withJSONObject: result), observedAt: Date(), sourceVersion: version
        )
    }

}

private final class GrokProcessRegistry: @unchecked Sendable {
    static let shared = GrokProcessRegistry()

    private let lock = NSLock()
    private var processes: Set<pid_t> = []
    private var exiting = false
    private let registered: Bool

    private init() {
        registered = atexit { GrokProcessRegistry.shared.stopAll() } == 0
    }

    func start(_ spawn: (inout pid_t) -> Int32) throws -> pid_t {
        try lock.withLock {
            guard registered, !exiting else { throw GrokBillingError.connectionLost }
            var pid: pid_t = 0
            guard spawn(&pid) == 0 else { throw GrokBillingError.failed }
            processes.insert(pid)
            return pid
        }
    }

    func stop(_ pid: pid_t) {
        lock.withLock {
            guard processes.remove(pid) != nil else { return }
            Self.stopGroup(pid)
        }
    }

    private func stopAll() {
        lock.withLock {
            exiting = true
            for pid in processes { Self.stopGroup(pid) }
            processes.removeAll()
        }
    }

    private static func stopGroup(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        repeat {
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == 0, info.si_pid == pid { break }
            if result == -1, errno == ECHILD { return }
            usleep(10_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        // WNOWAIT reserves the leader's PID until the final group signal;
        // another process cannot reuse it between observation and cleanup.
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
}
