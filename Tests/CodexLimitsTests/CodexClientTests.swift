import XCTest
@testable import CodexLimits

final class CodexClientTests: XCTestCase {
    func testDecodesMainLimitOtherLimitsAndUsageHistory() throws {
        let rateLimits = Data(#"""
        {"id":2,"result":{
          "rateLimits":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
          "rateLimitsByLimitId":{
            "codex":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
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

        XCTAssertEqual(result.mainLimit.window.remainingPercent, 80)
        XCTAssertEqual(result.mainLimit.window.durationMinutes, 10_080)
        XCTAssertEqual(result.mainLimit.window.resetsAt, Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(result.otherLimits.map(\.name), ["Example model"])
        XCTAssertEqual(result.tokenHistory.map(\.tokens), [1_000, 250])
        XCTAssertEqual(result.emergencyResetCount, 3)
        XCTAssertEqual(result.fetchedAt, fetchedAt)
    }
}
