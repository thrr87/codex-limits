import Foundation

enum CodexAccountObservation: Equatable, Sendable {
    case stable(identity: String)
    case unknown(state: String)
}

struct CodexFetchResult: Sendable {
    let snapshot: UsageSnapshot
    let account: CodexAccountObservation?
}

enum CodexClientError: LocalizedError {
    case cliNotFound
    case invalidResponse
    case timedOut
    case connectionLost
    case updatesDidNotSettle

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Codex CLI was not found. Install it with Homebrew, sign in, and try again."
        case .invalidResponse:
            "Codex returned data this app could not read. Update Codex CLI and try again."
        case .timedOut:
            "Codex took too long to respond. Try refreshing again."
        case .connectionLost:
            "The Codex connection closed. Try refreshing again."
        case .updatesDidNotSettle:
            "Codex usage changed during refresh. Try again."
        }
    }
}

final class CodexAppServerConnection: @unchecked Sendable {
    let input: FileHandle
    let output: FileHandle
    let isRunning: () -> Bool
    let stop: () -> Void
    private var bufferedOutput = Data()

    init(
        input: FileHandle,
        output: FileHandle,
        isRunning: @escaping () -> Bool,
        stop: @escaping () -> Void
    ) {
        self.input = input
        self.output = output
        self.isRunning = isRunning
        self.stop = stop
    }

    func readLine() async -> Data? {
        while true {
            if let newline = bufferedOutput.firstIndex(of: 0x0A) {
                let line = bufferedOutput[..<newline]
                bufferedOutput.removeSubrange(...newline)
                return Data(line)
            }
            let chunk = await Task.detached { [output] in
                output.availableData
            }.value
            guard !chunk.isEmpty else {
                guard !bufferedOutput.isEmpty else { return nil }
                defer { bufferedOutput.removeAll() }
                return bufferedOutput
            }
            bufferedOutput.append(chunk)
        }
    }
}

actor CodexClient {
    static let shared = CodexClient()

    private static let weeklyWindowDurationMinutes = 10_080
    private static let executablePaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex"
    ]
    private let makeConnection: () throws -> CodexAppServerConnection
    private let timeoutNanoseconds: UInt64
    private var connection: CodexAppServerConnection?
    private var initialized = false
    private var nextRequestID = 1
    private var lastResult: CodexFetchResult?
    private var inFlightFetch: Task<CodexFetchResult, Error>?

    private struct ResponseBatch: Sendable {
        let values: [Int: Data]
        let sawRateLimitsUpdate: Bool
        let sawAccountUpdate: Bool
    }

    private struct AccountStateBatch: Sendable {
        let rateLimits: Data?
        let usage: Data?
        let account: Data?
        let sawRateLimitsUpdate: Bool
        let sawAccountUpdate: Bool

        var needsReconciliation: Bool {
            sawRateLimitsUpdate || sawAccountUpdate
        }
    }

    init(
        makeConnection: @escaping () throws -> CodexAppServerConnection = CodexClient.liveConnection,
        timeout: TimeInterval = 15
    ) {
        self.makeConnection = makeConnection
        timeoutNanoseconds = UInt64(max(timeout, 0.001) * 1_000_000_000)
    }

    static func fetch() async throws -> CodexFetchResult {
        try await shared.fetch(fetchedAt: Date())
    }

    func fetch(fetchedAt: Date) async throws -> CodexFetchResult {
        if let inFlightFetch {
            return try await inFlightFetch.value
        }
        let task = Task {
            try await self.fetchWithReconnect(fetchedAt: fetchedAt)
        }
        inFlightFetch = task
        defer { inFlightFetch = nil }
        return try await task.value
    }

    private func fetchWithReconnect(
        fetchedAt: Date
    ) async throws -> CodexFetchResult {
        for attempt in 0 ... 1 {
            do {
                return try await fetchOnce(fetchedAt: fetchedAt)
            } catch CodexClientError.updatesDidNotSettle {
                throw CodexClientError.updatesDidNotSettle
            } catch {
                invalidateConnection()
                if attempt == 0,
                   case CodexClientError.connectionLost = error {
                    continue
                }
                throw error
            }
        }
        throw CodexClientError.connectionLost
    }

    private func fetchOnce(fetchedAt: Date) async throws -> CodexFetchResult {
        let connection = try activeConnection()
        if !initialized {
            let initializeID = requestID()
            try Self.write(
                #"{"id":\#(initializeID),"method":"initialize","params":{"clientInfo":{"name":"codex-limits","title":"Codex Limits","version":"\#(Self.version)"},"capabilities":{"experimentalApi":true}}}"#,
                to: connection.input
            )
            let response = try await responses(
                for: [initializeID],
                from: connection
            ).values[initializeID]
            guard let response,
                  let object = try JSONSerialization.jsonObject(
                    with: response
                  ) as? [String: Any],
                  object["error"] == nil else {
                throw CodexClientError.invalidResponse
            }
            try Self.write(#"{"method":"initialized"}"#, to: connection.input)
            initialized = true
        }

        var state = try await readAccountState(from: connection)
        for _ in 0 ..< 2 where state.needsReconciliation {
            state = try await readAccountState(from: connection)
        }
        if state.needsReconciliation {
            throw CodexClientError.updatesDidNotSettle
        }
        guard let rateLimits = state.rateLimits,
              let usage = state.usage,
              let account = state.account else {
            throw CodexClientError.invalidResponse
        }
        var result = try Self.decodeResult(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            accountResponse: account,
            fetchedAt: fetchedAt
        )
        if let previous = lastResult,
           let currentAccount = result.account,
           currentAccount == previous.account,
           case .stable = currentAccount {
            result = Self.fillingMissingAccountFacts(
                in: result,
                from: previous
            )
        }
        lastResult = result
        return result
    }

    private func readAccountState(
        from connection: CodexAppServerConnection
    ) async throws -> AccountStateBatch {
        let rateLimitsID = requestID()
        let usageID = requestID()
        let accountID = requestID()
        try Self.write(
            #"{"id":\#(rateLimitsID),"method":"account/rateLimits/read"}"#,
            to: connection.input
        )
        try Self.write(
            #"{"id":\#(usageID),"method":"account/usage/read"}"#,
            to: connection.input
        )
        try Self.write(
            #"{"id":\#(accountID),"method":"account/read","params":{"refreshToken":false}}"#,
            to: connection.input
        )
        let batch = try await responses(
            for: [rateLimitsID, usageID, accountID],
            from: connection,
            observingAccountUpdates: true
        )
        return AccountStateBatch(
            rateLimits: batch.values[rateLimitsID],
            usage: batch.values[usageID],
            account: batch.values[accountID],
            sawRateLimitsUpdate: batch.sawRateLimitsUpdate,
            sawAccountUpdate: batch.sawAccountUpdate
        )
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private static func liveConnection() throws -> CodexAppServerConnection {
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

        return CodexAppServerConnection(
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading,
            isRunning: { process.isRunning },
            stop: {
                try? input.fileHandleForWriting.close()
                try? output.fileHandleForReading.close()
                if process.isRunning {
                    process.terminate()
                }
            }
        )
    }

    private func activeConnection() throws -> CodexAppServerConnection {
        if let connection, connection.isRunning() {
            return connection
        }
        invalidateConnection()
        let connection = try makeConnection()
        self.connection = connection
        return connection
    }

    private func invalidateConnection() {
        connection?.stop()
        connection = nil
        initialized = false
    }

    private func requestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func responses(
        for ids: Set<Int>,
        from connection: CodexAppServerConnection,
        observingAccountUpdates: Bool = false
    ) async throws -> ResponseBatch {
        try await withThrowingTaskGroup(of: ResponseBatch.self) { group in
            group.addTask {
                try await Self.readResponses(
                    for: ids,
                    from: connection,
                    observingAccountUpdates: observingAccountUpdates
                )
            }
            group.addTask { [timeoutNanoseconds] in
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw CodexClientError.timedOut
            }
            do {
                guard let first = try await group.next() else {
                    throw CodexClientError.invalidResponse
                }
                group.cancelAll()
                return first
            } catch {
                connection.stop()
                group.cancelAll()
                throw error
            }
        }
    }

    private static func readResponses(
        for ids: Set<Int>,
        from connection: CodexAppServerConnection,
        observingAccountUpdates: Bool
    ) async throws -> ResponseBatch {
        var values: [Int: Data] = [:]
        var sawRateLimitsUpdate = false
        var sawAccountUpdate = false
        while let data = await connection.readLine() {
            try Task.checkCancellation()
            guard !data.isEmpty,
                  let object = try? JSONSerialization.jsonObject(
                    with: data
                  ) as? [String: Any] else {
                throw CodexClientError.invalidResponse
            }
            if observingAccountUpdates,
               object["method"] as? String == "account/rateLimits/updated" {
                sawRateLimitsUpdate = true
                continue
            }
            if observingAccountUpdates,
               object["method"] as? String == "account/updated" {
                sawAccountUpdate = true
                continue
            }
            guard let id = object["id"] as? Int,
                  ids.contains(id) else { continue }
            values[id] = data
            if values.count == ids.count {
                return ResponseBatch(
                    values: values,
                    sawRateLimitsUpdate: sawRateLimitsUpdate,
                    sawAccountUpdate: sawAccountUpdate
                )
            }
        }
        throw CodexClientError.connectionLost
    }

    deinit {
        connection?.stop()
    }

    static func decode(
        rateLimitsResponse: Data,
        usageResponse: Data,
        fetchedAt: Date
    ) throws -> UsageSnapshot {
        do {
            return try decodeValidated(
                rateLimitsResponse: rateLimitsResponse,
                usageResponse: usageResponse,
                fetchedAt: fetchedAt
            )
        } catch let error as CodexClientError {
            throw error
        } catch {
            throw CodexClientError.invalidResponse
        }
    }

    private static func decodeValidated(
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
        let mainWindow = mainWindows.first(where: {
            $0.durationMinutes == weeklyWindowDurationMinutes
        })

        let extraMainWindows = mainWindows
            .filter { $0.durationMinutes != weeklyWindowDurationMinutes }
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
        dateFormatter.isLenient = false
        let tokenHistory = try (usageResult.dailyUsageBuckets ?? []).map { bucket in
            guard bucket.tokens >= 0,
                  let date = dateFormatter.date(from: bucket.startDate) else {
                throw CodexClientError.invalidResponse
            }
            let endOfDay = date.addingTimeInterval(24 * 60 * 60)
            return TokenDay(
                date: date,
                tokens: bucket.tokens,
                completeness: endOfDay <= fetchedAt ? .complete : .partial
            )
        }
        let summary = usageResult.summary
        let summaryCounts = [
            summary?.lifetimeTokens,
            summary?.peakDailyTokens,
            summary?.longestRunningTurnSec,
            summary?.currentStreakDays,
            summary?.longestStreakDays
        ].compactMap { $0 }
        guard summaryCounts.allSatisfy({ $0 >= 0 }) else {
            throw CodexClientError.invalidResponse
        }
        let credits = mainSnapshot.credits.map {
            AccountCreditFacts(
                balance: $0.balance,
                hasCredits: $0.hasCredits,
                unlimited: $0.unlimited
            )
        }
        let spendControl = mainSnapshot.individualLimit.map {
            AccountSpendControlFacts(
                limit: $0.limit,
                used: $0.used,
                remainingPercent: $0.remainingPercent,
                resetsAt: Date(timeIntervalSince1970: TimeInterval($0.resetsAt)),
                reached: mainSnapshot.spendControlReached
            )
        }
        let facts = AccountFacts(
            lifetimeTokens: summary?.lifetimeTokens,
            peakDailyTokens: summary?.peakDailyTokens,
            longestRunningTurnSeconds: summary?.longestRunningTurnSec,
            currentStreakDays: summary?.currentStreakDays,
            longestStreakDays: summary?.longestStreakDays,
            credits: credits,
            spendControl: spendControl,
            lifetimeTokensObservedAt: (summary?.lifetimeTokens).map { _ in fetchedAt },
            peakDailyTokensObservedAt: (summary?.peakDailyTokens).map { _ in fetchedAt },
            longestRunningTurnObservedAt: (summary?.longestRunningTurnSec).map {
                _ in fetchedAt
            },
            currentStreakObservedAt: (summary?.currentStreakDays).map { _ in fetchedAt },
            longestStreakObservedAt: (summary?.longestStreakDays).map { _ in fetchedAt },
            creditsObservedAt: credits.map { _ in fetchedAt },
            creditBalanceObservedAt: credits?.balance.map { _ in fetchedAt },
            spendControlObservedAt: spendControl.map { _ in fetchedAt },
            spendControlReachedObservedAt: spendControl?.reached.map { _ in fetchedAt }
        )

        return UsageSnapshot(
            mainLimit: mainWindow.map {
                LimitReading(limitId: "codex", name: "Codex", window: $0)
            },
            otherLimits: others,
            tokenHistory: tokenHistory,
            emergencyResetCount: rateResult.rateLimitResetCredits?.availableCount ?? 0,
            fetchedAt: fetchedAt,
            accountFacts: facts.isEmpty ? nil : facts
        )
    }

    static func decodeAccount(_ response: Data) throws -> CodexAccountObservation {
        let value = try JSONDecoder().decode(
            RPCResponse<AccountResult>.self,
            from: response
        )
        guard let result = value.result else {
            throw CodexClientError.invalidResponse
        }
        if result.account?.type == "chatgpt",
           let email = result.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return .stable(identity: email)
        }
        let state = result.account?.type
            ?? (result.requiresOpenaiAuth ? "signed-out" : "no-account")
        return .unknown(state: state)
    }

    static func decodeResult(
        rateLimitsResponse: Data,
        usageResponse: Data,
        accountResponse: Data,
        fetchedAt: Date
    ) throws -> CodexFetchResult {
        CodexFetchResult(
            snapshot: try decode(
                rateLimitsResponse: rateLimitsResponse,
                usageResponse: usageResponse,
                fetchedAt: fetchedAt
            ),
            account: try? decodeAccount(accountResponse)
        )
    }

    private static func fillingMissingAccountFacts(
        in current: CodexFetchResult,
        from previous: CodexFetchResult
    ) -> CodexFetchResult {
        let previousFacts = previous.snapshot.accountFacts
        let facts = current.snapshot.accountFacts.map { currentFacts in
            guard let previousFacts else { return currentFacts }
            return currentFacts.fillingMissingValues(from: previousFacts)
        } ?? previousFacts
        let snapshot = UsageSnapshot(
            mainLimit: current.snapshot.mainLimit,
            otherLimits: current.snapshot.otherLimits,
            tokenHistory: current.snapshot.tokenHistory,
            emergencyResetCount: current.snapshot.emergencyResetCount,
            fetchedAt: current.snapshot.fetchedAt,
            accountFacts: facts
        )
        return CodexFetchResult(
            snapshot: snapshot,
            account: current.account
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
        if minutes == weeklyWindowDurationMinutes { return "Weekly window" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour window" }
        return "Additional window"
    }

    private static func write(_ message: String, to handle: FileHandle) throws {
        do {
            try handle.write(contentsOf: Data((message + "\n").utf8))
        } catch {
            throw CodexClientError.connectionLost
        }
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
    let credits: CreditsSnapshot?
    let individualLimit: SpendControlLimitSnapshot?
    let spendControlReached: Bool?
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

private struct UsageResult: Decodable {
    let dailyUsageBuckets: [TokenBucket]?
    let summary: AccountTokenUsageSummary?
}

private struct AccountTokenUsageSummary: Decodable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
}

private struct AccountResult: Decodable {
    let account: AccountValue?
    let requiresOpenaiAuth: Bool
}

private struct AccountValue: Decodable {
    let type: String
    let email: String?
}

private struct TokenBucket: Decodable {
    let startDate: String
    let tokens: Int64
}

private struct CreditsSnapshot: Decodable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool
}

private struct SpendControlLimitSnapshot: Decodable {
    let limit: String
    let used: String
    let remainingPercent: Double
    let resetsAt: Int64
}
