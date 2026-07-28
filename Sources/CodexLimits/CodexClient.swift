import Darwin
import Foundation

private actor CodexProtocolGate {
    private var isAvailable = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if isAvailable {
            isAvailable = false
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func leave() {
        guard !waiters.isEmpty else {
            isAvailable = true
            return
        }
        waiters.removeFirst().resume()
    }
}

enum CodexAccountObservation: Equatable, Sendable {
    case stable(identity: String)
    case unknown(state: String)
}

struct CodexFetchResult: Sendable {
    let snapshot: UsageSnapshot
    let account: CodexAccountObservation?
    let planType: String?

    init(
        snapshot: UsageSnapshot,
        account: CodexAccountObservation?,
        planType: String? = nil
    ) {
        self.snapshot = snapshot
        self.account = account
        self.planType = planType
    }
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

enum CodexIsolatedHome {
    static let directoryPrefix = "codex-limits-analysis-"
    private static let staleAge: TimeInterval = 24 * 60 * 60

    static func prepare(
        sourceHome: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date()
    ) throws -> URL {
        removeStaleDirectories(
            in: temporaryDirectory,
            now: now,
            maximumAge: staleAge
        )
        let directory = temporaryDirectory.appendingPathComponent(
            "\(directoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let sourceAuthentication = sourceHome.appendingPathComponent(
                "auth.json"
            )
            let authentication = directory.appendingPathComponent("auth.json")
            try FileManager.default.createSymbolicLink(
                at: authentication,
                withDestinationURL: sourceAuthentication
            )
            return directory
        } catch {
            remove(directory)
            throw error
        }
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func removeStaleDirectories(
        in temporaryDirectory: URL,
        now: Date,
        maximumAge: TimeInterval
    ) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for candidate in contents
        where candidate.lastPathComponent.hasPrefix(directoryPrefix) {
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: candidate.path
            ),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(modifiedAt) > maximumAge else {
                continue
            }
            remove(candidate)
        }
    }
}

private final class CodexAppServerProcessOwner: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let isolatedHome: URL?
    private let lock = NSLock()
    private var didStop = false

    init(
        process: Process,
        input: FileHandle,
        output: FileHandle,
        isolatedHome: URL?
    ) {
        self.process = process
        self.input = input
        self.output = output
        self.isolatedHome = isolatedHome
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard !didStop else { return false }
            didStop = true
            return true
        }
        guard shouldStop else { return }
        try? input.close()
        try? output.close()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        if let isolatedHome {
            CodexIsolatedHome.remove(isolatedHome)
        }
    }
}

actor CodexClient {
    static let shared = CodexClient(
        makeConnection: CodexClient.liveConnection,
        executableIdentity: CodexClient.liveExecutableIdentity
    )

    private static let weeklyWindowDurationMinutes = 10_080
    private static let executablePaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex"
    ]
    private let makeConnection: () throws -> CodexAppServerConnection
    private let executableIdentity: () -> String?
    private let protocolGate = CodexProtocolGate()
    private let timeoutNanoseconds: UInt64
    private var connection: CodexAppServerConnection?
    private var initialized = false
    private var serverCLIVersion: String?
    private var connectionExecutableIdentity: String?
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
        executableIdentity: @escaping () -> String? = { nil },
        timeout: TimeInterval = 15
    ) {
        self.makeConnection = makeConnection
        self.executableIdentity = executableIdentity
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
            try await self.withProtocolAccess {
                try await self.fetchWithReconnect(fetchedAt: fetchedAt)
            }
        }
        inFlightFetch = task
        defer { inFlightFetch = nil }
        return try await task.value
    }

    func threadProjectionResponse(
        for request: ThreadProjectionReadRequest
    ) async throws -> Data {
        try await withProtocolAccess {
            try await self.threadProjectionResponseWithReconnect(for: request)
        }
    }

    func installedCLIVersion() async throws -> String? {
        try await withProtocolAccess {
            let connection = try self.activeConnection()
            try await self.ensureInitialized(connection)
            return self.serverCLIVersion
        }
    }

    private func withProtocolAccess<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await protocolGate.enter()
        do {
            let result = try await operation()
            await protocolGate.leave()
            return result
        } catch {
            await protocolGate.leave()
            throw error
        }
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
        try await ensureInitialized(connection)

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

    private func threadProjectionResponseWithReconnect(
        for request: ThreadProjectionReadRequest
    ) async throws -> Data {
        for attempt in 0 ... 1 {
            do {
                let connection = try activeConnection()
                try await ensureInitialized(connection)
                let id = requestID()
                let method: String
                let params: [String: Any]
                switch request {
                case let .list(cursor, limit, useStateDBOnly, sortKey):
                    method = "thread/list"
                    params = [
                        "cursor": cursor as Any,
                        "limit": limit,
                        "useStateDbOnly": useStateDBOnly,
                        "sortKey": sortKey
                    ]
                case let .read(threadID, includeTurns):
                    method = "thread/read"
                    params = [
                        "threadId": threadID,
                        "includeTurns": includeTurns
                    ]
                }
                try Self.write(
                    object: [
                        "id": id,
                        "method": method,
                        "params": params
                    ],
                    to: connection.input
                )
                guard let response = try await responses(
                    for: [id],
                    from: connection
                ).values[id] else {
                    throw CodexClientError.invalidResponse
                }
                return response
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

    private func ensureInitialized(
        _ connection: CodexAppServerConnection
    ) async throws {
        guard !initialized else { return }
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
        serverCLIVersion = Self.serverCLIVersion(in: object)
        try Self.write(#"{"method":"initialized"}"#, to: connection.input)
        initialized = true
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

    private static func serverCLIVersion(
        in response: [String: Any]
    ) -> String? {
        guard let result = response["result"] as? [String: Any],
              let userAgent = result["userAgent"] as? String else {
            return nil
        }
        return userAgent.split(separator: " ").compactMap { component in
            let parts = component.split(separator: "/", maxSplits: 1)
            guard parts.count == 2,
                  parts[1].contains("."),
                  parts[1].allSatisfy({
                      $0.isNumber || $0 == "." || $0 == "-"
                  }) else {
                return nil
            }
            return String(parts[1])
        }.first
    }

    static func liveConnection() throws -> CodexAppServerConnection {
        try liveConnection(codexHome: nil)
    }

    static func liveIsolatedConnection() throws -> CodexAppServerConnection {
        let sourceHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        let directory = try CodexIsolatedHome.prepare(sourceHome: sourceHome)
        do {
            return try liveConnection(codexHome: directory)
        } catch {
            CodexIsolatedHome.remove(directory)
            throw error
        }
    }

    private static func liveConnection(
        codexHome: URL?
    ) throws -> CodexAppServerConnection {
        guard let executable = liveExecutableURL() else {
            throw CodexClientError.cliNotFound
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        if let codexHome {
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["CODEX_HOME": codexHome.path],
                uniquingKeysWith: { _, isolated in isolated }
            )
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let owner = CodexAppServerProcessOwner(
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading,
            isolatedHome: codexHome
        )

        return CodexAppServerConnection(
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading,
            isRunning: { process.isRunning },
            stop: { owner.stop() }
        )
    }

    private func activeConnection() throws -> CodexAppServerConnection {
        let currentExecutableIdentity = executableIdentity()
        if let connection,
           connection.isRunning(),
           currentExecutableIdentity == connectionExecutableIdentity {
            return connection
        }
        invalidateConnection()
        let connection = try makeConnection()
        self.connection = connection
        connectionExecutableIdentity = currentExecutableIdentity
        return connection
    }

    private func invalidateConnection() {
        connection?.stop()
        connection = nil
        initialized = false
        serverCLIVersion = nil
        connectionExecutableIdentity = nil
    }

    private static func liveExecutableURL() -> URL? {
        executablePaths.lazy.compactMap { path -> URL? in
            guard FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }.first
    }

    private static func liveExecutableIdentity() -> String? {
        guard let executable = liveExecutableURL(),
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: executable.path
              ) else {
            return nil
        }
        let fileNumber = attributes[.systemFileNumber] as? NSNumber
        let size = attributes[.size] as? NSNumber
        let modified = attributes[.modificationDate] as? Date
        return [
            executable.path,
            fileNumber?.stringValue ?? "unknown",
            size?.stringValue ?? "unknown",
            modified?.timeIntervalSince1970.description ?? "unknown"
        ].joined(separator: ":")
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

    static func decodeWeeklyLimit(
        rateLimitsResponse: Data
    ) throws -> LimitReading? {
        do {
            let response = try JSONDecoder().decode(
                RPCResponse<RateLimitsResult>.self,
                from: rateLimitsResponse
            )
            guard let result = response.result else {
                throw CodexClientError.invalidResponse
            }
            let snapshots = result.rateLimitsByLimitId
                ?? ["codex": result.rateLimits]
            let mainSnapshot = snapshots["codex"] ?? result.rateLimits
            return windows(from: mainSnapshot)
                .first(where: {
                    $0.durationMinutes == weeklyWindowDurationMinutes
                })
                .map {
                    LimitReading(
                        limitId: "codex",
                        name: "Codex",
                        window: $0
                    )
                }
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
        let resetCredits = rateResult.rateLimitResetCredits
        guard (resetCredits?.availableCount ?? 0) >= 0 else {
            throw CodexClientError.invalidResponse
        }
        let bankedResetDetails: [BankedResetDetail]? = resetCredits?
            .credits?
            .compactMap { detail -> BankedResetDetail? in
            guard let id = detail.id?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
                  !id.isEmpty,
                  let status = detail.status,
                  let expiresAt = detail.expiresAt,
                  expiresAt >= 0 else {
                return nil
            }
            return BankedResetDetail(
                id: id,
                resetType: detail.resetType,
                status: status,
                grantedAt: detail.grantedAt.flatMap {
                    $0 >= 0
                        ? Date(timeIntervalSince1970: TimeInterval($0))
                        : nil
                },
                expiresAt: Date(
                    timeIntervalSince1970: TimeInterval(expiresAt)
                ),
                title: detail.title,
                description: detail.description
            )
        }

        return UsageSnapshot(
            mainLimit: mainWindow.map {
                LimitReading(limitId: "codex", name: "Codex", window: $0)
            },
            otherLimits: others,
            tokenHistory: tokenHistory,
            emergencyResetCount: resetCredits?.availableCount ?? 0,
            bankedResetCountAvailable: resetCredits != nil,
            bankedResetDetails: bankedResetDetails,
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

    static func decodePlanType(_ response: Data) -> String? {
        guard let value = try? JSONDecoder().decode(
            RPCResponse<AccountResult>.self,
            from: response
        ) else {
            return nil
        }
        let plan = value.result?.account?.planType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return plan?.isEmpty == false ? plan : nil
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
            account: try? decodeAccount(accountResponse),
            planType: decodePlanType(accountResponse)
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
            bankedResetCountAvailable: current.snapshot.bankedResetCountAvailable,
            bankedResetDetails: current.snapshot.bankedResetDetails,
            fetchedAt: current.snapshot.fetchedAt,
            accountFacts: facts
        )
        return CodexFetchResult(
            snapshot: snapshot,
            account: current.account,
            planType: current.planType ?? previous.planType
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

    private static func write(
        object: [String: Any],
        to handle: FileHandle
    ) throws {
        guard JSONSerialization.isValidJSONObject(object),
              let message = String(
                  data: try JSONSerialization.data(withJSONObject: object),
                  encoding: .utf8
              ) else {
            throw CodexClientError.invalidResponse
        }
        try write(message, to: handle)
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
    let credits: [ResetCreditDetail]?

    private enum CodingKeys: String, CodingKey {
        case availableCount
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try container.decode(
            Int.self,
            forKey: .availableCount
        )
        credits = try? container.decode(
            [ResetCreditDetail].self,
            forKey: .credits
        )
    }
}

private struct ResetCreditDetail: Decodable {
    let id: String?
    let resetType: String?
    let status: String?
    let grantedAt: Int64?
    let expiresAt: Int64?
    let title: String?
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case resetType
        case status
        case grantedAt
        case expiresAt
        case title
        case description
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(
            keyedBy: CodingKeys.self
        ) else {
            id = nil
            resetType = nil
            status = nil
            grantedAt = nil
            expiresAt = nil
            title = nil
            description = nil
            return
        }
        id = try? container.decode(String.self, forKey: .id)
        resetType = try? container.decode(String.self, forKey: .resetType)
        status = try? container.decode(String.self, forKey: .status)
        grantedAt = try? container.decode(Int64.self, forKey: .grantedAt)
        expiresAt = try? container.decode(Int64.self, forKey: .expiresAt)
        title = try? container.decode(String.self, forKey: .title)
        description = try? container.decode(
            String.self,
            forKey: .description
        )
    }
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
    let planType: String?
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
