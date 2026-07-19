import Foundation

enum CodexClientError: LocalizedError {
    case cliNotFound
    case invalidResponse
    case mainLimitMissing
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Codex CLI was not found. Install it with Homebrew, sign in, and try again."
        case .invalidResponse:
            "Codex returned data this app could not read. Update Codex CLI and try again."
        case .mainLimitMissing:
            "Codex did not return a usable limit. Make sure Codex CLI is signed in."
        case .timedOut:
            "Codex took too long to respond. Try refreshing again."
        }
    }
}

enum CodexClient {
    private static let executablePaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex"
    ]

    static func fetch() async throws -> UsageSnapshot {
        guard let executable = executablePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw CodexClientError.cliNotFound
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
            try write(
                #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-limits","title":"Codex Limits","version":"\#(version)"},"capabilities":{"experimentalApi":true}}}"#,
                to: input.fileHandleForWriting
            )
            let fetchedAt = Date()
            let snapshot = try await withThrowingTaskGroup(of: UsageSnapshot.self) { group in
                group.addTask {
                    try await readSnapshot(
                        from: output.fileHandleForReading,
                        writingTo: input.fileHandleForWriting,
                        fetchedAt: fetchedAt
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw CodexClientError.timedOut
                }
                guard let first = try await group.next() else {
                    throw CodexClientError.invalidResponse
                }
                group.cancelAll()
                return first
            }
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            return snapshot
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    static func decode(
        rateLimitsResponse: Data,
        usageResponse: Data,
        fetchedAt: Date
    ) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        guard let rateResult = try decoder.decode(RPCResponse<RateLimitsResult>.self, from: rateLimitsResponse).result,
              let usageResult = try decoder.decode(RPCResponse<UsageResult>.self, from: usageResponse).result else {
            throw CodexClientError.invalidResponse
        }

        let snapshots = rateResult.rateLimitsByLimitId ?? ["codex": rateResult.rateLimits]
        let mainSnapshot = snapshots["codex"] ?? rateResult.rateLimits
        let mainWindows = windows(from: mainSnapshot)
        guard let mainWindow = mainWindows.min(by: {
            $0.remainingPercent < $1.remainingPercent
        }) else {
            throw CodexClientError.mainLimitMissing
        }

        let extraMainWindows = mainWindows
            .filter { $0 != mainWindow }
            .map {
                LimitReading(limitId: "codex", name: windowName($0.durationMinutes), window: $0)
            }
        let otherLimits = snapshots
            .filter { $0.key != "codex" }
            .compactMap { id, snapshot -> LimitReading? in
                guard let window = windows(from: snapshot).min(by: {
                    $0.remainingPercent < $1.remainingPercent
                }) else { return nil }
                return LimitReading(
                    limitId: id,
                    name: snapshot.limitName ?? id,
                    window: window
                )
            }
        let others = (extraMainWindows + otherLimits)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let tokenHistory = (usageResult.dailyUsageBuckets ?? []).compactMap { bucket -> TokenDay? in
            guard let date = dateFormatter.date(from: bucket.startDate) else { return nil }
            return TokenDay(date: date, tokens: bucket.tokens)
        }

        return UsageSnapshot(
            mainLimit: LimitReading(limitId: "codex", name: "Codex", window: mainWindow),
            otherLimits: others,
            tokenHistory: tokenHistory,
            emergencyResetCount: rateResult.rateLimitResetCredits?.availableCount ?? 0,
            fetchedAt: fetchedAt
        )
    }

    private static func windows(from snapshot: RateLimitSnapshot) -> [UsageWindow] {
        [snapshot.primary, snapshot.secondary].compactMap { window in
            guard let window,
                  let resetsAt = window.resetsAt,
                  let duration = window.windowDurationMins else { return nil }
            return UsageWindow(
                remainingPercent: min(max(100 - window.usedPercent, 0), 100),
                resetsAt: Date(timeIntervalSince1970: TimeInterval(resetsAt)),
                durationMinutes: duration
            )
        }
    }

    private static func windowName(_ minutes: Int) -> String {
        if minutes == 10_080 { return "Weekly window" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour window" }
        return "Additional window"
    }

    private static func write(_ message: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data((message + "\n").utf8))
    }

    private static func readSnapshot(
        from output: FileHandle,
        writingTo input: FileHandle,
        fetchedAt: Date
    ) async throws -> UsageSnapshot {
        var rateLimitsResponse: Data?
        var usageResponse: Data?

        for try await line in output.bytes.lines {
            try Task.checkCancellation()
            let data = Data(line.utf8)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? Int else { continue }

            if object["error"] != nil { throw CodexClientError.invalidResponse }
            switch id {
            case 1:
                try write(#"{"method":"initialized"}"#, to: input)
                try write(#"{"id":2,"method":"account/rateLimits/read"}"#, to: input)
                try write(#"{"id":3,"method":"account/usage/read"}"#, to: input)
            case 2:
                rateLimitsResponse = data
            case 3:
                usageResponse = data
            default:
                continue
            }

            if let rateLimitsResponse, let usageResponse {
                return try decode(
                    rateLimitsResponse: rateLimitsResponse,
                    usageResponse: usageResponse,
                    fetchedAt: fetchedAt
                )
            }
        }
        throw CodexClientError.invalidResponse
    }
}

private struct RPCResponse<Result: Decodable>: Decodable {
    let result: Result?
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: ResetCredits?
}

private struct ResetCredits: Decodable {
    let availableCount: Int
}

private struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

private struct UsageResult: Decodable {
    let dailyUsageBuckets: [TokenBucket]?
}

private struct TokenBucket: Decodable {
    let startDate: String
    let tokens: Int64
}
