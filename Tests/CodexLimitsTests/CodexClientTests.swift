import XCTest
@testable import CodexLimits

final class CodexClientTests: XCTestCase {
    func testIsolatedHomeLinksCredentialsAndRemovesTheLink() throws {
        let root = temporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        let temporary = root.appendingPathComponent(
            "temporary",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        let sourceAuthentication = source.appendingPathComponent("auth.json")
        try Data("secret".utf8).write(to: sourceAuthentication)
        let isolated = try CodexIsolatedHome.prepare(
            sourceHome: source,
            temporaryDirectory: temporary,
            now: Date(timeIntervalSince1970: 10_000)
        )
        let isolatedAuthentication = isolated.appendingPathComponent(
            "auth.json"
        )

        let values = try isolatedAuthentication.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: isolatedAuthentication.path
            ),
            sourceAuthentication.path
        )

        CodexIsolatedHome.remove(isolated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolated.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sourceAuthentication.path
            )
        )
    }

    func testIsolatedHomeRemovesOnlyStaleOwnedDirectories() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let stale = root.appendingPathComponent(
            "\(CodexIsolatedHome.directoryPrefix)stale",
            isDirectory: true
        )
        let current = root.appendingPathComponent(
            "\(CodexIsolatedHome.directoryPrefix)current",
            isDirectory: true
        )
        let unrelated = root.appendingPathComponent(
            "another-app",
            isDirectory: true
        )
        for directory in [stale, current, unrelated] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: stale.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 9_900)],
            ofItemAtPath: current.path
        )

        CodexIsolatedHome.removeStaleDirectories(
            in: root,
            now: Date(timeIntervalSince1970: 10_000),
            maximumAge: 1_000
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testRepeatedFetchesReuseOneInitializedSession() async throws {
        let server = PersistentAppServerFixture()
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        let first = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )
        let second = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_060)
        )

        XCTAssertEqual(first.snapshot.mainLimit?.window.remainingPercent, 80)
        XCTAssertEqual(second.snapshot.mainLimit?.window.remainingPercent, 70)
        XCTAssertEqual(server.connectionCount, 1)
        XCTAssertEqual(server.initializationCount, 1)
    }

    func testThreadProjectionReadsReuseTheInitializedAccountSession() async throws {
        let server = PersistentAppServerFixture()
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )
        _ = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )
        let source = ReadOnlyThreadProjectionSource { request in
            try await client.threadProjectionResponse(for: request)
        }

        let page = try await source.list(cursor: nil, limit: 25)
        let detail = try await source.read(threadID: "task-child")

        XCTAssertEqual(page.tasks.map(\.taskID), ["task-child"])
        XCTAssertEqual(detail?.projectLabel, "atlas")
        XCTAssertEqual(server.connectionCount, 1)
        XCTAssertEqual(server.initializationCount, 1)
        XCTAssertEqual(server.threadListReadCount, 1)
        XCTAssertEqual(server.threadReadCount, 1)
    }

    func testReadsInstalledCLIVersionFromTheInitializedSession() async throws {
        let server = PersistentAppServerFixture(
            initializeUserAgent: "Codex Desktop/0.145.0 (Mac OS 15.5)"
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        let version = try await client.installedCLIVersion()

        XCTAssertEqual(version, "0.145.0")
        XCTAssertEqual(server.connectionCount, 1)
        XCTAssertEqual(server.initializationCount, 1)
    }

    func testInstalledCLIChangeReplacesThePersistentSession() async throws {
        let server = PersistentAppServerFixture(
            initializeUserAgent: "Codex Desktop/0.145.0 (Mac OS 15.5)"
        )
        let identity = ExecutableIdentityFixture("first")
        let client = CodexClient(
            makeConnection: server.makeConnection,
            executableIdentity: identity.current,
            timeout: 1
        )

        _ = try await client.installedCLIVersion()
        identity.set("second")
        let version = try await client.installedCLIVersion()

        XCTAssertEqual(version, "0.145.0")
        XCTAssertEqual(server.connectionCount, 2)
        XCTAssertEqual(server.initializationCount, 2)
    }

    func testConcurrentClientFetchesShareOneProtocolTransaction() async throws {
        let server = PersistentAppServerFixture(
            delaysFirstRateLimitResponse: true
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        async let first = client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        async let second = client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_001)
        )
        let results = try await [first, second]

        XCTAssertEqual(
            results.compactMap(\.snapshot.mainLimit?.window.remainingPercent),
            [80, 80]
        )
        XCTAssertEqual(server.rateLimitReadCount, 1)
        XCTAssertEqual(server.accountReadCount, 1)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testFetchProjectionAndVersionShareOneProtocolReader() async throws {
        let server = PersistentAppServerFixture(
            delaysFirstRateLimitResponse: true,
            initializeUserAgent: "Codex Desktop/0.145.0 (Mac OS 15.5)"
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )
        let source = ReadOnlyThreadProjectionSource { request in
            try await client.threadProjectionResponse(for: request)
        }

        async let fetch = client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )
        async let page = source.list(cursor: nil, limit: 25)
        async let version = client.installedCLIVersion()
        let results = try await (fetch, page, version)

        XCTAssertEqual(
            results.0.snapshot.mainLimit?.window.remainingPercent,
            80
        )
        XCTAssertEqual(results.1.tasks.map(\.taskID), ["task-child"])
        XCTAssertEqual(results.2, "0.145.0")
        XCTAssertEqual(server.connectionCount, 1)
        XCTAssertEqual(server.initializationCount, 1)
        XCTAssertEqual(server.threadListReadCount, 1)
    }

    func testBrokenConnectionReconnectsWithoutLosingTheRefresh() async throws {
        let server = PersistentAppServerFixture(dropsFirstConnection: true)
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        let result = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(result.snapshot.mainLimit?.window.remainingPercent, 80)
        XCTAssertEqual(server.connectionCount, 2)
        XCTAssertEqual(server.initializationCount, 2)
    }

    func testSparseRateLimitNotificationTriggersFullReconciliation() async throws {
        let server = PersistentAppServerFixture(
            sendsSparseRateLimitUpdate: true
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        let result = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(result.snapshot.mainLimit?.window.remainingPercent, 70)
        XCTAssertEqual(server.rateLimitReadCount, 2)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testSparseRateLimitNotificationCannotReplaceFullResetDetail() async throws {
        let server = PersistentAppServerFixture(
            sendsSparseRateLimitUpdate: true,
            includesChangingResetDetails: true
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        let result = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(result.snapshot.emergencyResetCount, 1)
        XCTAssertEqual(
            result.snapshot.bankedResetDetails?.map(\.id),
            ["reset-2"]
        )
        XCTAssertEqual(server.rateLimitReadCount, 2)
    }

    func testSparseAccountNotificationTriggersFullReconciliation() async throws {
        let server = PersistentAppServerFixture(
            sendsSparseAccountUpdate: true
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        let result = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(
            result.account,
            .stable(identity: "updated@example.com")
        )
        XCTAssertEqual(result.snapshot.mainLimit?.window.remainingPercent, 70)
        XCTAssertEqual(result.snapshot.accountFacts?.lifetimeTokens, 2_000)
        XCTAssertEqual(server.rateLimitReadCount, 2)
        XCTAssertEqual(server.usageReadCount, 2)
        XCTAssertEqual(server.accountReadCount, 2)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testUpdateDuringReconciliationTriggersOneMoreBoundedRead() async throws {
        let server = PersistentAppServerFixture(
            sendsRateUpdateDuringReconciliation: true
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        let result = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(result.snapshot.mainLimit?.window.remainingPercent, 60)
        XCTAssertEqual(server.rateLimitReadCount, 3)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testTimeoutClosesTheSessionAndNextRefreshReconnects() async throws {
        let server = PersistentAppServerFixture(
            stallsFirstConnection: true
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 0.02
        )

        do {
            _ = try await client.fetch(
                fetchedAt: Date(timeIntervalSince1970: 1_900_000)
            )
            XCTFail("Expected the first refresh to time out")
        } catch CodexClientError.timedOut {
            // Expected.
        } catch {
            XCTFail("Expected timedOut, got \(error)")
        }

        let result = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_060)
        )

        XCTAssertEqual(result.snapshot.mainLimit?.window.remainingPercent, 70)
        XCTAssertEqual(server.connectionCount, 2)
        XCTAssertEqual(server.initializationCount, 2)
    }

    func testOutOfOrderResponsesAreMatchedByRequestID() async throws {
        let server = OutOfOrderAppServerFixture()
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        let result = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(result.snapshot.mainLimit?.window.remainingPercent, 80)
        XCTAssertEqual(
            result.account,
            .stable(identity: "user@example.com")
        )
    }

    func testMissingFactsDoNotEraseFactsFromTheSameAccount() async throws {
        let server = PersistentAppServerFixture(
            omitsAccountFactsOnSecondRead: true
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        _ = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )
        let second = try await client.fetch(
            fetchedAt: Date(timeIntervalSince1970: 1_900_060)
        )

        XCTAssertEqual(second.snapshot.accountFacts?.lifetimeTokens, 1_200)
        XCTAssertEqual(second.snapshot.accountFacts?.peakDailyTokens, 500)
        XCTAssertEqual(
            second.snapshot.accountFacts?.lifetimeTokensObservedAt,
            Date(timeIntervalSince1970: 1_900_060)
        )
        XCTAssertEqual(
            second.snapshot.accountFacts?.peakDailyTokensObservedAt,
            Date(timeIntervalSince1970: 1_900_000)
        )
    }

    func testPreservedLifetimeFactKeepsItsOriginalObservationTime() async throws {
        let server = PersistentAppServerFixture(
            omitsLifetimeTokensOnSecondRead: true
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )
        let firstReadAt = Date(timeIntervalSince1970: 1_900_000)
        let secondReadAt = Date(timeIntervalSince1970: 1_900_060)

        _ = try await client.fetch(fetchedAt: firstReadAt)
        let second = try await client.fetch(fetchedAt: secondReadAt)

        XCTAssertEqual(second.snapshot.accountFacts?.lifetimeTokens, 1_000)
        XCTAssertEqual(
            second.snapshot.accountFacts?.lifetimeTokensObservedAt,
            firstReadAt
        )
        XCTAssertEqual(second.snapshot.accountFacts?.peakDailyTokens, 600)
    }

    func testMalformedProtocolLineFailsWithoutPublishingPartialValues() async {
        let server = PersistentAppServerFixture(
            sendsMalformedRateLimitLine: true
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 0.02
        )

        do {
            _ = try await client.fetch(
                fetchedAt: Date(timeIntervalSince1970: 1_900_000)
            )
            XCTFail("Expected malformed protocol data to fail")
        } catch CodexClientError.invalidResponse {
            // Expected.
        } catch {
            XCTFail("Expected invalidResponse, got \(error)")
        }
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testMissingWeeklyWindowKeepsOtherLimitsWithoutRestarting() async throws {
        let server = PersistentAppServerFixture(
            omitsWeeklyWindow: true
        )
        let client = CodexClient(
            makeConnection: server.makeConnection,
            timeout: 1
        )

        for offset in [0.0, 60.0] {
            let result = try await client.fetch(
                fetchedAt: Date(timeIntervalSince1970: 1_900_000 + offset)
            )
            XCTAssertNil(result.snapshot.mainLimit)
            XCTAssertEqual(result.snapshot.otherLimits.map(\.name), [
                "5-hour window"
            ])
        }

        XCTAssertEqual(server.connectionCount, 1)
        XCTAssertEqual(server.initializationCount, 1)
    }

    func testDecodesMainLimitOtherLimitsAndUsageHistory() throws {
        let rateLimits = Data(#"""
        {"id":2,"result":{
          "rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1950000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
          "rateLimitsByLimitId":{
            "codex":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1950000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
            "codex_example":{"limitId":"codex_example","limitName":"Example model","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":2100000}}
          },
          "rateLimitResetCredits":{"availableCount":3}
        }}
        """#.utf8)
        let usage = Data(#"""
        {"id":3,"result":{
          "dailyUsageBuckets":[
            {"startDate":"2001-01-01","tokens":1000},
            {"startDate":"2001-01-02","tokens":250}
          ]
        }}
        """#.utf8)
        let fetchedAt = Date(timeIntervalSince1970: 1_900_000)

        let result = try CodexClient.decode(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(result.mainLimit?.window.remainingPercent, 80)
        XCTAssertEqual(result.mainLimit?.window.durationMinutes, 10_080)
        XCTAssertEqual(
            result.mainLimit?.window.resetsAt,
            Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertEqual(result.otherLimits.map(\.name), ["5-hour window", "Example model"])
        XCTAssertEqual(result.tokenHistory.map(\.tokens), [1_000, 250])
        XCTAssertEqual(result.emergencyResetCount, 3)
        XCTAssertEqual(result.fetchedAt, fetchedAt)
    }

    func testDecodesAuthoritativeResetCountAndReorderedDetailRows() throws {
        let rateLimits = Data(#"""
        {"id":2,"result":{
          "rateLimits":{"limitId":"codex","secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
          "rateLimitResetCredits":{
            "availableCount":3,
            "credits":[
              {"id":"later","resetType":"codexRateLimits","status":"available","grantedAt":1900000,"expiresAt":2100000,"title":"Full reset","description":"Ready"},
              {"id":"earlier","resetType":"codexRateLimits","status":"available","grantedAt":1900000,"expiresAt":2050000,"title":"Full reset","description":"Ready"}
            ]
          }
        }}
        """#.utf8)
        let usage = Data(#"{"id":3,"result":{"dailyUsageBuckets":[]}}"#.utf8)

        let result = try CodexClient.decode(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            fetchedAt: Date(timeIntervalSince1970: 2_000_000)
        )

        XCTAssertEqual(result.emergencyResetCount, 3)
        XCTAssertEqual(result.bankedResetDetails?.map(\.id), ["later", "earlier"])
        XCTAssertEqual(
            result.bankedResetDetails?.map(\.expiresAt),
            [
                Date(timeIntervalSince1970: 2_100_000),
                Date(timeIntervalSince1970: 2_050_000)
            ]
        )
    }

    func testDistinguishesMissingAndFetchedEmptyResetDetail() throws {
        let usage = Data(#"{"id":3,"result":{"dailyUsageBuckets":[]}}"#.utf8)
        let missing = try CodexClient.decode(
            rateLimitsResponse: Data(#"""
            {"id":2,"result":{
              "rateLimits":{"limitId":"codex","secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
              "rateLimitResetCredits":{"availableCount":2,"credits":null}
            }}
            """#.utf8),
            usageResponse: usage,
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )
        let empty = try CodexClient.decode(
            rateLimitsResponse: Data(#"""
            {"id":2,"result":{
              "rateLimits":{"limitId":"codex","secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
              "rateLimitResetCredits":{"availableCount":0,"credits":[]}
            }}
            """#.utf8),
            usageResponse: usage,
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(missing.emergencyResetCount, 2)
        XCTAssertNil(missing.bankedResetDetails)
        XCTAssertEqual(empty.emergencyResetCount, 0)
        XCTAssertEqual(empty.bankedResetDetails, [])
    }

    func testMissingResetCreditContainerDoesNotClaimZeroIsAuthoritative() throws {
        let result = try CodexClient.decode(
            rateLimitsResponse: Data(#"""
            {"id":2,"result":{
              "rateLimits":{"limitId":"codex","secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}}
            }}
            """#.utf8),
            usageResponse: Data(
                #"{"id":3,"result":{"dailyUsageBuckets":[]}}"#.utf8
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(result.emergencyResetCount, 0)
        XCTAssertEqual(result.bankedResetCountAvailable, false)
    }

    func testMalformedOptionalResetRowDoesNotDiscardCountOrValidDetail() throws {
        let result = try CodexClient.decode(
            rateLimitsResponse: Data(#"""
            {"id":2,"result":{
              "rateLimits":{"limitId":"codex","secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
              "rateLimitResetCredits":{
                "availableCount":2,
                "credits":[
                  {"id":"broken","resetType":"codexRateLimits","grantedAt":1900000,"title":"Full reset"},
                  {"id":42,"status":"available","expiresAt":"2100000"},
                  {"id":"valid","status":"available","expiresAt":2100000}
                ]
              }
            }}
            """#.utf8),
            usageResponse: Data(
                #"{"id":3,"result":{"dailyUsageBuckets":[]}}"#.utf8
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(result.emergencyResetCount, 2)
        XCTAssertEqual(result.bankedResetDetails?.map(\.id), ["valid"])
    }

    func testDecodesTokenSummaryCreditsAndSpendControlAsIndependentFacts() throws {
        let rateLimits = Data(#"""
        {"id":2,"result":{
          "rateLimits":{
            "limitId":"codex",
            "secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000},
            "credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"},
            "individualLimit":{"limit":"50.00","used":"10.00","remainingPercent":80,"resetsAt":2100000},
            "spendControlReached":false
          }
        }}
        """#.utf8)
        let usage = Data(#"""
        {"id":3,"result":{
          "summary":{
            "lifetimeTokens":43000000000,
            "peakDailyTokens":2300000000,
            "longestRunningTurnSec":83820,
            "currentStreakDays":43,
            "longestStreakDays":51
          },
          "dailyUsageBuckets":[]
        }}
        """#.utf8)

        let result = try CodexClient.decode(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(
            result.accountFacts,
            AccountFacts(
                lifetimeTokens: 43_000_000_000,
                peakDailyTokens: 2_300_000_000,
                longestRunningTurnSeconds: 83_820,
                currentStreakDays: 43,
                longestStreakDays: 51,
                credits: AccountCreditFacts(
                    balance: "12.50",
                    hasCredits: true,
                    unlimited: false
                ),
                spendControl: AccountSpendControlFacts(
                    limit: "50.00",
                    used: "10.00",
                    remainingPercent: 80,
                    resetsAt: Date(timeIntervalSince1970: 2_100_000),
                    reached: false
                ),
                lifetimeTokensObservedAt: Date(
                    timeIntervalSince1970: 1_900_000
                ),
                peakDailyTokensObservedAt: Date(
                    timeIntervalSince1970: 1_900_000
                ),
                longestRunningTurnObservedAt: Date(
                    timeIntervalSince1970: 1_900_000
                ),
                currentStreakObservedAt: Date(
                    timeIntervalSince1970: 1_900_000
                ),
                longestStreakObservedAt: Date(
                    timeIntervalSince1970: 1_900_000
                ),
                creditsObservedAt: Date(
                    timeIntervalSince1970: 1_900_000
                ),
                creditBalanceObservedAt: Date(
                    timeIntervalSince1970: 1_900_000
                ),
                spendControlObservedAt: Date(
                    timeIntervalSince1970: 1_900_000
                ),
                spendControlReachedObservedAt: Date(
                    timeIntervalSince1970: 1_900_000
                )
            )
        )
    }

    func testNestedMissingFactsKeepTheirOwnObservationTimes() {
        let previousReadAt = Date(timeIntervalSince1970: 1_900_000)
        let currentReadAt = Date(timeIntervalSince1970: 1_900_060)
        let previous = AccountFacts(
            lifetimeTokens: nil,
            peakDailyTokens: nil,
            longestRunningTurnSeconds: nil,
            currentStreakDays: nil,
            longestStreakDays: nil,
            credits: AccountCreditFacts(
                balance: "12.50",
                hasCredits: true,
                unlimited: false
            ),
            spendControl: AccountSpendControlFacts(
                limit: "50.00",
                used: "10.00",
                remainingPercent: 80,
                resetsAt: Date(timeIntervalSince1970: 2_100_000),
                reached: false
            ),
            creditsObservedAt: previousReadAt,
            creditBalanceObservedAt: previousReadAt,
            spendControlObservedAt: previousReadAt,
            spendControlReachedObservedAt: previousReadAt
        )
        let current = AccountFacts(
            lifetimeTokens: nil,
            peakDailyTokens: nil,
            longestRunningTurnSeconds: nil,
            currentStreakDays: nil,
            longestStreakDays: nil,
            credits: AccountCreditFacts(
                balance: nil,
                hasCredits: true,
                unlimited: false
            ),
            spendControl: AccountSpendControlFacts(
                limit: "50.00",
                used: "12.00",
                remainingPercent: 76,
                resetsAt: Date(timeIntervalSince1970: 2_100_000),
                reached: nil
            ),
            creditsObservedAt: currentReadAt,
            spendControlObservedAt: currentReadAt
        )

        let merged = current.fillingMissingValues(from: previous)

        XCTAssertEqual(merged.credits?.balance, "12.50")
        XCTAssertEqual(merged.creditsObservedAt, currentReadAt)
        XCTAssertEqual(merged.creditBalanceObservedAt, previousReadAt)
        XCTAssertEqual(merged.spendControl?.reached, false)
        XCTAssertEqual(merged.spendControlObservedAt, currentReadAt)
        XCTAssertEqual(
            merged.spendControlReachedObservedAt,
            previousReadAt
        )
    }

    func testDailyTokenBucketsKeepCompleteAndPartialState() throws {
        let rateLimits = Data(#"""
        {"id":2,"result":{
          "rateLimits":{"limitId":"codex","secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}}
        }}
        """#.utf8)
        let usage = Data(#"""
        {"id":3,"result":{
          "summary":{},
          "dailyUsageBuckets":[
            {"startDate":"2026-07-27","tokens":1000},
            {"startDate":"2026-07-28","tokens":250}
          ]
        }}
        """#.utf8)
        let fetchedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-28T12:00:00Z")
        )

        let result = try CodexClient.decode(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(
            result.tokenHistory.map(\.completeness),
            [.complete, .partial]
        )
    }

    func testMissingWeeklyWindowDoesNotPromoteTheFiveHourWindow() throws {
        let rateLimits = Data(#"""
        {"id":2,"result":{
          "rateLimits":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":2000000}},
          "rateLimitsByLimitId":{
            "codex":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":2000000}}
          }
        }}
        """#.utf8)
        let usage = Data(#"{"id":3,"result":{"dailyUsageBuckets":[]}}"#.utf8)

        let result = try CodexClient.decode(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertNil(result.mainLimit)
        XCTAssertEqual(result.otherLimits.map(\.name), ["5-hour window"])
        XCTAssertEqual(result.otherLimits.first?.window.durationMinutes, 300)
    }

    func testMalformedRateLimitPayloadUsesTheIncompatibleResponseError() {
        let rateLimits = Data(
            #"{"id":2,"result":{"rateLimits":"unsupported"}}"#.utf8
        )
        let usage = Data(
            #"{"id":3,"result":{"dailyUsageBuckets":[]}}"#.utf8
        )

        XCTAssertThrowsError(
            try CodexClient.decode(
                rateLimitsResponse: rateLimits,
                usageResponse: usage,
                fetchedAt: Date(timeIntervalSince1970: 1_900_000)
            )
        ) { error in
            guard case CodexClientError.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    func testMalformedDailyTokenBucketsFailTheWholeAccountRead() {
        let rateLimits = Data(#"""
        {"id":2,"result":{
          "rateLimits":{"limitId":"codex","secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}}
        }}
        """#.utf8)
        let malformedBuckets = [
            #"{"startDate":"not-a-date","tokens":100}"#,
            #"{"startDate":"2026-07-27","tokens":-1}"#
        ]

        for bucket in malformedBuckets {
            let usage = Data(
                #"{"id":3,"result":{"dailyUsageBuckets":[\#(bucket)]}}"#.utf8
            )
            XCTAssertThrowsError(
                try CodexClient.decode(
                    rateLimitsResponse: rateLimits,
                    usageResponse: usage,
                    fetchedAt: Date(timeIntervalSince1970: 1_900_000)
                )
            ) { error in
                guard case CodexClientError.invalidResponse = error else {
                    return XCTFail("Expected invalidResponse, got \(error)")
                }
            }
        }

        let usage = Data(
            #"{"id":3,"result":{"summary":{"lifetimeTokens":-1},"dailyUsageBuckets":[]}}"#.utf8
        )
        XCTAssertThrowsError(
            try CodexClient.decode(
                rateLimitsResponse: rateLimits,
                usageResponse: usage,
                fetchedAt: Date(timeIntervalSince1970: 1_900_000)
            )
        ) { error in
            guard case CodexClientError.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    func testDecodesStableChatGPTAccountIdentity() throws {
        let response = Data(#"""
        {"id":4,"result":{
          "account":{"type":"chatgpt","email":"User@example.com","planType":"pro"},
          "requiresOpenaiAuth":true
        }}
        """#.utf8)

        let account = try CodexClient.decodeAccount(response)

        XCTAssertEqual(account, .stable(identity: "User@example.com"))
        XCTAssertEqual(CodexClient.decodePlanType(response), "pro")
    }

    func testAccountReadErrorKeepsValidUsageWithoutAnAccountObservation() throws {
        let rateLimits = Data(#"""
        {"id":2,"result":{
          "rateLimits":{"limitId":"codex","secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
          "rateLimitsByLimitId":{
            "codex":{"limitId":"codex","secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}}
          }
        }}
        """#.utf8)
        let usage = Data(#"{"id":3,"result":{"dailyUsageBuckets":[]}}"#.utf8)
        let accountError = Data(
            #"{"id":4,"error":{"code":-32601,"message":"Method not found"}}"#.utf8
        )

        let result = try CodexClient.decodeResult(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            accountResponse: accountError,
            fetchedAt: Date(timeIntervalSince1970: 1_900_000)
        )

        XCTAssertEqual(result.snapshot.mainLimit?.window.remainingPercent, 80)
        XCTAssertNil(result.account)
    }

}

private final class ExecutableIdentityFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) {
        self.value = value
    }

    func current() -> String? {
        lock.withLock { value }
    }

    func set(_ value: String) {
        lock.withLock { self.value = value }
    }
}

private final class PersistentAppServerFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let dropsFirstConnection: Bool
    private let stallsFirstConnection: Bool
    private let sendsSparseRateLimitUpdate: Bool
    private let sendsSparseAccountUpdate: Bool
    private let sendsRateUpdateDuringReconciliation: Bool
    private let omitsAccountFactsOnSecondRead: Bool
    private let omitsLifetimeTokensOnSecondRead: Bool
    private let sendsMalformedRateLimitLine: Bool
    private let omitsWeeklyWindow: Bool
    private let delaysFirstRateLimitResponse: Bool
    private let initializeUserAgent: String?
    private let includesChangingResetDetails: Bool
    private var connections = 0
    private var initializations = 0
    private var rateLimitReads = 0
    private var usageReads = 0
    private var accountReads = 0
    private var threadListReads = 0
    private var threadReads = 0

    var connectionCount: Int {
        lock.withLock { connections }
    }

    var initializationCount: Int {
        lock.withLock { initializations }
    }

    var rateLimitReadCount: Int {
        lock.withLock { rateLimitReads }
    }

    var accountReadCount: Int {
        lock.withLock { accountReads }
    }

    var usageReadCount: Int {
        lock.withLock { usageReads }
    }

    var threadListReadCount: Int {
        lock.withLock { threadListReads }
    }

    var threadReadCount: Int {
        lock.withLock { threadReads }
    }

    init(
        dropsFirstConnection: Bool = false,
        stallsFirstConnection: Bool = false,
        sendsSparseRateLimitUpdate: Bool = false,
        sendsSparseAccountUpdate: Bool = false,
        sendsRateUpdateDuringReconciliation: Bool = false,
        omitsAccountFactsOnSecondRead: Bool = false,
        omitsLifetimeTokensOnSecondRead: Bool = false,
        sendsMalformedRateLimitLine: Bool = false,
        omitsWeeklyWindow: Bool = false,
        delaysFirstRateLimitResponse: Bool = false,
        initializeUserAgent: String? = nil,
        includesChangingResetDetails: Bool = false
    ) {
        self.dropsFirstConnection = dropsFirstConnection
        self.stallsFirstConnection = stallsFirstConnection
        self.sendsSparseRateLimitUpdate = sendsSparseRateLimitUpdate
        self.sendsSparseAccountUpdate = sendsSparseAccountUpdate
        self.sendsRateUpdateDuringReconciliation = sendsRateUpdateDuringReconciliation
        self.omitsAccountFactsOnSecondRead = omitsAccountFactsOnSecondRead
        self.omitsLifetimeTokensOnSecondRead = omitsLifetimeTokensOnSecondRead
        self.sendsMalformedRateLimitLine = sendsMalformedRateLimitLine
        self.omitsWeeklyWindow = omitsWeeklyWindow
        self.delaysFirstRateLimitResponse = delaysFirstRateLimitResponse
        self.initializeUserAgent = initializeUserAgent
        self.includesChangingResetDetails = includesChangingResetDetails
    }

    func makeConnection() throws -> CodexAppServerConnection {
        let requests = Pipe()
        let responses = Pipe()
        let connectionNumber = lock.withLock {
            connections += 1
            return connections
        }
        Task {
            for try await line in requests.fileHandleForReading.bytes.lines {
                guard let request = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                ) as? [String: Any],
                    let id = request["id"] as? Int,
                    let method = request["method"] as? String else {
                    continue
                }
                var response: String
                switch method {
                case "initialize":
                    lock.withLock { initializations += 1 }
                    if let initializeUserAgent {
                        response = #"{"id":\#(id),"result":{"userAgent":"\#(initializeUserAgent)"}}"#
                    } else {
                        response = #"{"id":\#(id),"result":{}}"#
                    }
                case "account/rateLimits/read":
                    if dropsFirstConnection, connectionNumber == 1 {
                        try? responses.fileHandleForWriting.close()
                        return
                    }
                    let read = lock.withLock {
                        rateLimitReads += 1
                        return rateLimitReads
                    }
                    if delaysFirstRateLimitResponse, read == 1 {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if stallsFirstConnection, connectionNumber == 1 {
                        continue
                    }
                    if sendsMalformedRateLimitLine {
                        response = "not-json"
                    } else {
                        let used = read == 1 ? 20 : (read == 2 ? 30 : 40)
                        let duration = omitsWeeklyWindow ? 300 : 10_080
                        response = #"{"id":\#(id),"result":{"rateLimits":{"limitId":"codex","secondary":{"usedPercent":\#(used),"windowDurationMins":\#(duration),"resetsAt":2000000}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","secondary":{"usedPercent":\#(used),"windowDurationMins":\#(duration),"resetsAt":2000000}}}}}"#
                    }
                    if includesChangingResetDetails,
                       !sendsMalformedRateLimitLine {
                        var object = try! XCTUnwrap(
                            JSONSerialization.jsonObject(
                                with: Data(response.utf8)
                            ) as? [String: Any]
                        )
                        var result = try! XCTUnwrap(
                            object["result"] as? [String: Any]
                        )
                        result["rateLimitResetCredits"] = [
                            "availableCount": 1,
                            "credits": [[
                                "id": "reset-\(read)",
                                "resetType": "codexRateLimits",
                                "status": "available",
                                "grantedAt": 1_900_000,
                                "expiresAt": 2_100_000,
                                "title": "Full reset",
                                "description": "Ready"
                            ]]
                        ]
                        object["result"] = result
                        response = String(
                            data: try! JSONSerialization.data(
                                withJSONObject: object
                            ),
                            encoding: .utf8
                        )!
                    }
                    if sendsRateUpdateDuringReconciliation, read == 2 {
                        let notification = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"secondary":{"usedPercent":40}}}}"#
                        try responses.fileHandleForWriting.write(
                            contentsOf: Data((notification + "\n").utf8)
                        )
                    }
                case "account/usage/read":
                    let read = lock.withLock {
                        usageReads += 1
                        return usageReads
                    }
                    if omitsAccountFactsOnSecondRead {
                        let summary = read == 1
                            ? #""lifetimeTokens":1000,"peakDailyTokens":500"#
                            : #""lifetimeTokens":1200"#
                        response = #"{"id":\#(id),"result":{"summary":{\#(summary)},"dailyUsageBuckets":[]}}"#
                    } else if omitsLifetimeTokensOnSecondRead {
                        let summary = read == 1
                            ? #""lifetimeTokens":1000,"peakDailyTokens":500"#
                            : #""peakDailyTokens":600"#
                        response = #"{"id":\#(id),"result":{"summary":{\#(summary)},"dailyUsageBuckets":[]}}"#
                    } else if sendsSparseAccountUpdate {
                        let lifetimeTokens = read == 1 ? 1_000 : 2_000
                        response = #"{"id":\#(id),"result":{"summary":{"lifetimeTokens":\#(lifetimeTokens)},"dailyUsageBuckets":[]}}"#
                    } else {
                        response = #"{"id":\#(id),"result":{"dailyUsageBuckets":[]}}"#
                    }
                case "account/read":
                    let read = lock.withLock {
                        accountReads += 1
                        return accountReads
                    }
                    if sendsSparseAccountUpdate, read == 1 {
                        let notification = #"{"method":"account/updated","params":{"authMode":"chatgpt","planType":"pro"}}"#
                        try responses.fileHandleForWriting.write(
                            contentsOf: Data((notification + "\n").utf8)
                        )
                    }
                    let email = sendsSparseAccountUpdate && read > 1
                        ? "updated@example.com"
                        : "user@example.com"
                    response = #"{"id":\#(id),"result":{"account":{"type":"chatgpt","email":"\#(email)","planType":"pro"},"requiresOpenaiAuth":true}}"#
                case "thread/list":
                    lock.withLock { threadListReads += 1 }
                    response = #"{"id":\#(id),"result":{"data":[{"id":"task-child","parentThreadId":"task-root","cliVersion":"0.145.0","cwd":"/synthetic/projects/atlas","createdAt":1785146400,"updatedAt":1785146460}],"nextCursor":null}}"#
                case "thread/read":
                    lock.withLock { threadReads += 1 }
                    response = #"{"id":\#(id),"result":{"thread":{"id":"task-child","parentThreadId":"task-root","cliVersion":"0.145.0","cwd":"/synthetic/projects/atlas","createdAt":1785146400,"updatedAt":1785146460}}}"#
                default:
                    continue
                }
                try responses.fileHandleForWriting.write(
                    contentsOf: Data((response + "\n").utf8)
                )
                if method == "account/rateLimits/read",
                   sendsSparseRateLimitUpdate || sendsRateUpdateDuringReconciliation,
                   lock.withLock({ rateLimitReads == 1 }) {
                    let notification = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"secondary":{"usedPercent":40}}}}"#
                    try responses.fileHandleForWriting.write(
                        contentsOf: Data((notification + "\n").utf8)
                    )
                }
            }
        }
        return CodexAppServerConnection(
            input: requests.fileHandleForWriting,
            output: responses.fileHandleForReading,
            isRunning: { true },
            stop: {
                try? requests.fileHandleForWriting.close()
                try? responses.fileHandleForWriting.close()
            }
        )
    }
}

private final class OutOfOrderAppServerFixture: @unchecked Sendable {
    func makeConnection() throws -> CodexAppServerConnection {
        let requests = Pipe()
        let responses = Pipe()
        Task {
            var pending: [(id: Int, method: String)] = []
            for try await line in requests.fileHandleForReading.bytes.lines {
                guard let request = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                ) as? [String: Any],
                    let id = request["id"] as? Int,
                    let method = request["method"] as? String else {
                    continue
                }
                if method == "initialize" {
                    try responses.fileHandleForWriting.write(
                        contentsOf: Data(
                            (#"{"id":\#(id),"result":{}}"# + "\n").utf8
                        )
                    )
                    continue
                }
                pending.append((id, method))
                guard pending.count == 3 else { continue }
                for request in pending.reversed() {
                    let response: String
                    switch request.method {
                    case "account/rateLimits/read":
                        response = #"{"id":\#(request.id),"result":{"rateLimits":{"limitId":"codex","secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}}}}"#
                    case "account/usage/read":
                        response = #"{"id":\#(request.id),"result":{"dailyUsageBuckets":[]}}"#
                    case "account/read":
                        response = #"{"id":\#(request.id),"result":{"account":{"type":"chatgpt","email":"user@example.com"},"requiresOpenaiAuth":true}}"#
                    default:
                        continue
                    }
                    try responses.fileHandleForWriting.write(
                        contentsOf: Data((response + "\n").utf8)
                    )
                }
                pending.removeAll()
            }
        }
        return CodexAppServerConnection(
            input: requests.fileHandleForWriting,
            output: responses.fileHandleForReading,
            isRunning: { true },
            stop: {
                try? requests.fileHandleForWriting.close()
                try? responses.fileHandleForWriting.close()
            }
        )
    }
}
