import Darwin
import XCTest
@testable import CodexLimits

final class GrokBillingClientTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let current = #"{"config":{"creditUsagePercent":25.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2030-01-01T00:00:00+00:00","end":"2030-01-08T00:00:00.123456+00:00"},"prepaidBalance":{},"onDemandUsed":{"val":125},"onDemandCap":{"val":2500},"isUnifiedBillingUser":true},"subscription_tier":"Super\u0007Grok","private":"do-not-retain"}"#

    func testCurrentAndLegacyAllowancesKeepOnlyValidatedFacts() throws {
        let decoded = try decode(current)
        XCTAssertEqual(decoded.remainingPercent, 74.5)
        XCTAssertEqual(decoded.period, .weekly)
        XCTAssertEqual(decoded.subscriptionTier, "SuperGrok")
        XCTAssertEqual(decoded.prepaidBalanceUSD, 0)
        XCTAssertEqual(decoded.onDemandUsedUSD, 1.25)
        XCTAssertEqual(decoded.onDemandCapUSD, 25)
        XCTAssertEqual(decoded.isUnifiedBilling, true)
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.measurementSource, "creditUsagePercent")
        XCTAssertEqual(try XCTUnwrap(decoded.startsAt).timeIntervalSince1970, 1_893_456_000)
        XCTAssertEqual(decoded.resetsAt.timeIntervalSince1970, 1_894_060_800.123456, accuracy: 0.001)
        let encoded = try JSONEncoder().encode(decoded)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("do-not-retain"))
        XCTAssertEqual(try JSONDecoder().decode(GrokAllowanceSnapshot.self, from: encoded), decoded)

        let legacy = try decode(#"{"config":{"monthlyLimit":{"val":10000},"used":{},"billingPeriodEnd":"2030-02-01T00:00:00Z"}}"#)
        XCTAssertEqual(legacy.period, .monthly)
        XCTAssertEqual(legacy.remainingPercent, 100)
        XCTAssertEqual(legacy.measurementSource, "legacyCredits")
        XCTAssertNil(legacy.prepaidBalanceUSD)
        XCTAssertNil(legacy.startsAt)
        let above = try decode(current.replacingOccurrences(of: "25.5", with: "120"))
        XCTAssertEqual(above.reportedUsedPercent, 120)
        XCTAssertEqual(above.remainingPercent, 0)
        XCTAssertTrue(above.isValid)
        let monthly = try decode(current.replacingOccurrences(of: "TYPE_WEEKLY", with: "TYPE_MONTHLY"))
        XCTAssertEqual(monthly.period, .monthly)
    }

    func testPeriodStartIsRetainedWhenSuppliedAndNeverInferredWhenMissing() throws {
        let legacy = try decode(#"{"config":{"monthlyLimit":{"val":10000},"used":{"val":100},"billingPeriodStart":"2030-01-03T12:00:00+02:00","billingPeriodEnd":"2030-02-03T10:00:00Z"}}"#)
        XCTAssertEqual(try XCTUnwrap(legacy.startsAt).timeIntervalSince1970, 1_893_664_800)
        XCTAssertTrue(legacy.isValid)

        let monthly = current.replacingOccurrences(of: "TYPE_WEEKLY", with: "TYPE_MONTHLY")
        for fixture in [
            monthly.replacingOccurrences(of: #""start":"2030-01-01T00:00:00+00:00","#, with: ""),
            monthly.replacingOccurrences(of: #""start":"2030-01-01T00:00:00+00:00""#, with: #""start":null"#)
        ] {
            let snapshot = try decode(fixture)
            XCTAssertNil(snapshot.startsAt)
            XCTAssertEqual(snapshot.period, .monthly)
            XCTAssertTrue(snapshot.isValid)
        }
    }

    func testOldLatestSnapshotDecodesWithoutInventingStartAndCorruptDatesAreInvalid() throws {
        let original = try decode(current)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        saved.removeValue(forKey: "startsAt")
        let migrated = try JSONDecoder().decode(GrokAllowanceSnapshot.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertNil(migrated.startsAt)
        XCTAssertEqual(migrated.remainingPercent, original.remainingPercent)
        XCTAssertEqual(migrated.observedAt, original.observedAt)
        XCTAssertEqual(migrated.resetsAt, original.resetsAt)
        XCTAssertTrue(migrated.isValid)

        for (key, invalidDate) in [
            ("startsAt", original.resetsAt),
            ("startsAt", Date.distantPast.addingTimeInterval(-1)),
            ("resetsAt", Date.distantFuture.addingTimeInterval(1)),
            ("observedAt", Date.distantFuture.addingTimeInterval(1))
        ] {
            var corrupted = saved
            corrupted[key] = invalidDate.timeIntervalSinceReferenceDate
            let snapshot = try JSONDecoder().decode(GrokAllowanceSnapshot.self, from: JSONSerialization.data(withJSONObject: corrupted))
            XCTAssertFalse(snapshot.isValid, key)
        }
    }

    func testInvalidCurrentFieldsNeverFallBackToLegacyOrInventZero() throws {
        let fixtures: [(String, GrokBillingError)] = [
            (#"{"config":null}"#, .missingAllowance),
            (#"{"config":{"monthlyLimit":{},"used":{},"billingPeriodEnd":"2030-02-01T00:00:00Z"}}"#, .missingAllowance),
            (#"{"config":{"creditUsagePercent":null,"monthlyLimit":{"val":100},"used":{},"billingPeriodEnd":"2030-02-01T00:00:00Z"}}"#, .missingAllowance),
            (current.replacingOccurrences(of: "25.5", with: "true"), .missingAllowance),
            (current.replacingOccurrences(of: "TYPE_WEEKLY", with: "TYPE_DAILY"), .unknownPeriod),
            (current.replacingOccurrences(of: "2030-01-08T00:00:00.123456+00:00", with: "bad"), .invalidReset),
            (current.replacingOccurrences(of: "2030-01-01T00:00:00+00:00", with: "2030-02-01T00:00:00Z"), .invalidReset),
            (current.replacingOccurrences(of: "2030-01-01T00:00:00+00:00", with: "2030-01-08T00:00:00.123456+00:00"), .invalidReset),
            (current.replacingOccurrences(of: "2030-01-01T00:00:00+00:00", with: "bad"), .invalidReset),
            (current.replacingOccurrences(of: "2030-01-08T00:00:00.123456+00:00", with: "5000-01-08T00:00:00Z"), .invalidReset)
        ]
        for (fixture, error) in fixtures {
            XCTAssertThrowsError(try decode(fixture)) {
                XCTAssertEqual($0 as? GrokBillingError, error)
            }
        }
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decode(current))) as? [String: Any])
        saved["subscriptionTier"] = "bad\u{001b}text"
        let corrupted = try JSONDecoder().decode(GrokAllowanceSnapshot.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertFalse(corrupted.isValid)
        XCTAssertThrowsError(try GrokAllowanceSnapshot.decode(
            Data(current.utf8), observedAt: .distantFuture.addingTimeInterval(1), sourceVersion: nil
        )) {
            XCTAssertEqual($0 as? GrokBillingError, .invalidResponse)
        }
    }

    func testTransportUsesPrefixedBillingAfterInitializeAndCleansItsWorkingDirectory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("requests")
        let cwd = directory.appendingPathComponent("cwd")
        let executable = try script(in: directory, body: """
        printf '%s\\n' "$*" > '\(record.path)'
        pwd > '\(cwd.path)'
        IFS= read -r line
        printf '%s\\n' "$line" >> '\(record.path)'
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"_meta":{"agentVersion":"9.8.7"}}}'
        IFS= read -r line
        printf '%s\\n' "$line" >> '\(record.path)'
        case "$line" in
          *'"method":"_x.ai/billing"'*) printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":\(current)}' ;;
          *) printf '%s\\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32601}}' ;;
        esac
        """)
        let result = try await GrokBillingClient().fetch(executableURL: executable)
        XCTAssertEqual(result.sourceVersion, "9.8.7")
        XCTAssertEqual(result.remainingPercent, 74.5)
        let lines = try String(contentsOf: record).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "agent --no-leader stdio")
        let initRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(initRequest["method"] as? String, "initialize")
        let params = try XCTUnwrap(initRequest["params"] as? [String: Any])
        let capabilities = try XCTUnwrap(params["clientCapabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["terminal"] as? Bool, false)
        let fs = try XCTUnwrap(capabilities["fs"] as? [String: Bool])
        XCTAssertEqual(fs, ["readTextFile": false, "writeTextFile": false])
        let workingDirectory = try String(contentsOf: cwd).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(workingDirectory.contains("CodexLimits-Grok-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory))
        XCTAssertFalse(GrokBillingClient.isExecutable(directory))
    }

    func testTransportRejectsProtocolErrorsAndBoundsTotalOutput() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (code, expected) in [(-32601, GrokBillingError.unsupported), (-32000, .authenticationRequired), (-32603, .failed)] {
            let executable = try script(in: directory, body: """
            IFS= read -r line
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"error":{"code":\(code),"message":"PRIVATE"}}'
            """)
            do {
                _ = try await GrokBillingClient().fetch(executableURL: executable)
                XCTFail("Expected an error")
            } catch {
                XCTAssertEqual(error as? GrokBillingError, expected)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
            }
        }
        let oversized = try script(in: directory, body: """
        IFS= read -r line
        /usr/bin/head -c 1048577 /dev/zero
        """)
        do {
            _ = try await GrokBillingClient().fetch(executableURL: oversized)
            XCTFail("Expected output rejection")
        } catch {
            XCTAssertEqual(error as? GrokBillingError, .invalidResponse)
        }
    }

    func testDeadlineAndCancellationTerminateTheOwnedProcessGroup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for cancellation in [false, true] {
            let record = directory.appendingPathComponent(UUID().uuidString)
            let executable = try script(in: directory, body: """
            /bin/sleep 60 &
            child=$!
            trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM
            printf '%s %s\\n' "$$" "$child" > '\(record.path)'
            wait "$child"
            """)
            let started = Date()
            let task = Task {
                try await GrokBillingClient(timeout: cancellation ? 10 : 0.2)
                    .fetch(executableURL: executable)
            }
            if cancellation {
                for _ in 0..<100 where !FileManager.default.fileExists(atPath: record.path) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                task.cancel()
            }
            do {
                _ = try await task.value
                XCTFail("Expected interruption")
            } catch {
                if cancellation { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? GrokBillingError, .timedOut) }
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            let pids = try String(contentsOf: record).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            XCTAssertEqual(pids.count, 2)
            for pid in pids {
                // The kernel can reap a killed descendant after its parent exits.
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while kill(pid, 0) == 0, ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let result = kill(pid, 0)
                let processError = errno
                XCTAssertEqual(result, -1)
                XCTAssertEqual(processError, ESRCH)
            }
        }
    }

    private func decode(_ json: String) throws -> GrokAllowanceSnapshot {
        try GrokAllowanceSnapshot.decode(Data(json.utf8), observedAt: observedAt, sourceVersion: "1.2.3")
    }

    private func script(in directory: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-grok")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}
