import ClaudeIntegrationCore
import XCTest

final class ClaudeRelayTests: XCTestCase {
    func testBoundedReaderConsumesMultipleChunksAndStopsAtTheCap() throws {
        let root = temporaryDirectory()
        let inputURL = root.appendingPathComponent("input.json")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var input = Data(repeating: 0x20, count: 70 * 1_024)
        input.append(Data(
            #"{"rate_limits":{"seven_day":{"used_percentage":40,"resets_at":2200000}}}"#.utf8
        ))
        try input.write(to: inputURL)

        var handle = try FileHandle(forReadingFrom: inputURL)
        var read = try ClaudeRelay.readBoundedInput(from: handle)
        try handle.close()
        XCTAssertEqual(read, input)
        XCTAssertNoThrow(try ClaudeRelay.decode(read, observedAt: Date()))

        try Data(
            repeating: 0x20,
            count: ClaudeRelay.maximumInputBytes + 100
        ).write(to: inputURL)
        handle = try FileHandle(forReadingFrom: inputURL)
        read = try ClaudeRelay.readBoundedInput(from: handle)
        try handle.close()
        XCTAssertEqual(read.count, ClaudeRelay.maximumInputBytes + 1)
    }

    func testUnavailableStatusLineIsUsefulAndNeutral() {
        XCTAssertEqual(ClaudeRelay.unavailableStatusLine, "Usage unavailable")
    }

    func testDecodesOnlyBoundedAllowanceWindows() throws {
        let observedAt = Date(timeIntervalSince1970: 2_000_000)
        let snapshot = try ClaudeRelay.decode(
            Data(#"{"version":"2.1.92","session_id":"private","model":{"display_name":"Private"},"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":2100000},"seven_day":{"used_percentage":40,"resets_at":2200000}}}"#.utf8),
            observedAt: observedAt
        )

        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.cliVersion, "2.1.92")
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 75)
        XCTAssertEqual(snapshot.sevenDay?.remainingPercent, 60)
        XCTAssertEqual(
            ClaudeRelay.statusLine(for: snapshot),
            "7d 60% remaining · 5h 75% remaining"
        )
        let encoded = String(
            data: try JSONEncoder().encode(snapshot),
            encoding: .utf8
        )!
        XCTAssertFalse(encoded.contains("session"))
        XCTAssertFalse(encoded.contains("model"))
        XCTAssertFalse(encoded.contains("Private"))
    }

    func testRejectsInvalidOrUnboundedInput() {
        XCTAssertThrowsError(try ClaudeRelay.decode(
            Data(#"{"rate_limits":{"seven_day":{"used_percentage":101,"resets_at":2200000}}}"#.utf8),
            observedAt: Date()
        ))
        XCTAssertThrowsError(try ClaudeRelay.decode(
            Data(repeating: 0x20, count: ClaudeRelay.maximumInputBytes + 1),
            observedAt: Date()
        ))
        XCTAssertThrowsError(try ClaudeRelay.decode(
            Data(#"{"rate_limits":{}}"#.utf8),
            observedAt: Date()
        ))
    }

    func testOlderWriterCannotReplaceNewerSnapshot() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let cache = root.appendingPathComponent("snapshot.json")
        let marker = root.appendingPathComponent("enabled")
        try Data().write(to: marker)
        let newer = snapshot(observedAt: 200, remaining: 60)
        let older = snapshot(observedAt: 100, remaining: 80)

        _ = try ClaudeRelay.storeIfNewer(
            newer,
            at: cache,
            enabledMarkerURL: marker
        )
        _ = try ClaudeRelay.storeIfNewer(
            older,
            at: cache,
            enabledMarkerURL: marker
        )

        XCTAssertEqual(try ClaudeRelay.readSnapshot(at: cache), newer)
    }

    func testEquivalentObservationWithinThirtySecondsDoesNotRewriteCache() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let cache = root.appendingPathComponent("snapshot.json")
        let marker = root.appendingPathComponent("enabled")
        try Data().write(to: marker)
        let first = snapshot(observedAt: 100, remaining: 80)
        let equivalent = snapshot(observedAt: 110, remaining: 80)
        let changed = snapshot(observedAt: 111, remaining: 79)

        XCTAssertTrue(try ClaudeRelay.storeIfNewer(
            first,
            at: cache,
            enabledMarkerURL: marker
        ))
        XCTAssertFalse(try ClaudeRelay.storeIfNewer(
            equivalent,
            at: cache,
            enabledMarkerURL: marker
        ))
        XCTAssertTrue(try ClaudeRelay.storeIfNewer(
            changed,
            at: cache,
            enabledMarkerURL: marker
        ))
        XCTAssertEqual(try ClaudeRelay.readSnapshot(at: cache), changed)
    }

    func testClockRollbackReplacesFutureCacheWithoutSeedingItAndKeepsWriterOrdering() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("snapshot.json")
        let marker = root.appendingPathComponent("enabled")
        try Data().write(to: marker)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func reading(offset: TimeInterval, remaining: Double) -> ClaudeAllowanceSnapshot {
            ClaudeAllowanceSnapshot(
                observedAt: now.addingTimeInterval(offset), cliVersion: "2.1.92", fiveHour: nil,
                sevenDay: ClaudeAllowanceWindowSnapshot(remainingPercent: remaining, resetsAt: now.addingTimeInterval(86_400))
            )
        }
        let future = reading(offset: 3_600, remaining: 90)
        try JSONEncoder().encode(future).write(to: cache)
        XCTAssertThrowsError(try ClaudeRelay.readSnapshot(at: cache, now: now))
        let current = reading(offset: 0, remaining: 70)

        XCTAssertTrue(try ClaudeRelay.storeIfNewer(current, at: cache, enabledMarkerURL: marker, now: { now }))
        XCTAssertEqual(try ClaudeRelay.readSnapshot(at: cache, now: now), current)
        let history = try AllowanceHistory.read(in: ClaudeRelay.historyDirectory(for: cache), now: now.addingTimeInterval(7_200))
        XCTAssertEqual(history, current.historyObservations, "Rejected future cache must not seed the history")

        let delayed = reading(offset: -120, remaining: 80)
        XCTAssertFalse(try ClaudeRelay.storeIfNewer(delayed, at: cache, enabledMarkerURL: marker, now: { now.addingTimeInterval(180) }))
        XCTAssertThrowsError(try ClaudeRelay.storeIfNewer(future, at: cache, enabledMarkerURL: marker, now: { now }))
        XCTAssertEqual(try ClaudeRelay.readSnapshot(at: cache, now: now), current)
    }

    func testReaderRejectsTamperedCache() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let cache = root.appendingPathComponent("snapshot.json")
        try JSONEncoder().encode(
            snapshot(observedAt: 100, remaining: 200)
        ).write(to: cache)

        XCTAssertThrowsError(try ClaudeRelay.readSnapshot(at: cache))

        try JSONEncoder().encode(ClaudeAllowanceSnapshot(
            observedAt: Date(timeIntervalSince1970: 100),
            cliVersion: "private\nvalue",
            fiveHour: nil,
            sevenDay: ClaudeAllowanceWindowSnapshot(
                remainingPercent: 50,
                resetsAt: Date(timeIntervalSince1970: 1_000)
            )
        )).write(to: cache)
        XCTAssertThrowsError(try ClaudeRelay.readSnapshot(at: cache))
    }

    func testMissingEnabledMarkerPreventsPersistence() {
        let root = temporaryDirectory()
        let cache = root.appendingPathComponent("snapshot.json")

        XCTAssertThrowsError(try ClaudeRelay.storeIfNewer(
            snapshot(observedAt: 100, remaining: 80),
            at: cache,
            enabledMarkerURL: root.appendingPathComponent("missing")
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    private func snapshot(
        observedAt: TimeInterval,
        remaining: Double
    ) -> ClaudeAllowanceSnapshot {
        ClaudeAllowanceSnapshot(
            observedAt: Date(timeIntervalSince1970: observedAt),
            cliVersion: "2.1.92",
            fiveHour: nil,
            sevenDay: ClaudeAllowanceWindowSnapshot(
                remainingPercent: remaining,
                resetsAt: Date(timeIntervalSince1970: 1_000)
            )
        )
    }
}
