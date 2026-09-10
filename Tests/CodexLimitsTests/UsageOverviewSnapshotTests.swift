import ClaudeIntegrationCore
import Foundation
import XCTest
@testable import CodexLimits

final class UsageOverviewSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOverviewContainsOnlyCurrentPeriodActualObservations() throws {
        let window = window()
        let current = point(-60, 65)
        let chart = chart(window: window, segments: [[point(-8 * 86_400, 95), point(-600, 80), current, point(60, 60)]])
        let overview = try XCTUnwrap(UsageOverviewSnapshot(chart: chart, window: window, now: now))

        XCTAssertEqual(overview.range, DateInterval(start: window.startsAt, end: window.resetsAt))
        XCTAssertEqual(overview.observedSegments, [[point(-600, 80), current]])
        XCTAssertEqual(overview.latest, current)
        XCTAssertEqual(overview.target, chart.target)
        XCTAssertFalse(overview.observedSegments.flatMap { $0 }.contains(point(3_600, 0)))
    }

    func testCompactionKeepsSegmentEndpointsAndLatestWithinFixedBudget() throws {
        let window = window()
        let segments: [[UsageChartPoint]] = (0 ..< 20).map { segment in
            let start = -10_000 + segment * 400
            return (0 ..< 100).map { index in
                point(Double(start + index), Double(100 - index))
            }
        }
        let overview = try XCTUnwrap(UsageOverviewSnapshot(chart: chart(window: window, segments: segments), window: window, now: now))
        XCTAssertEqual(overview.observedSegments.count, segments.count)
        for (actual, original) in zip(overview.observedSegments, segments) {
            XCTAssertEqual(actual.first, original.first)
            XCTAssertEqual(actual.last, original.last)
            XCTAssertTrue(actual.allSatisfy { original.contains($0) })
        }
        XCTAssertEqual(overview.latest, segments.last?.last)
        XCTAssertLessThanOrEqual(overview.observedSegments.flatMap { $0 }.count + overview.target.count + 1, 256)

        let isolated = (0 ..< 500).map { [point(Double(-600 + $0), 50)] }
        let manyBreaks = try XCTUnwrap(UsageOverviewSnapshot(chart: chart(window: window, segments: isolated), window: window, now: now))
        XCTAssertTrue(manyBreaks.observedSegments.allSatisfy { $0.count == 1 })
        XCTAssertEqual(manyBreaks.latest, isolated.last?.last)
        XCTAssertLessThanOrEqual(manyBreaks.observedSegments.count + manyBreaks.target.count + 1, 256)
    }

    func testInvalidObservationsBreakLinesAndDerivedValuesAreRejected() throws {
        let window = window()
        let segments = [[point(-600, 80), point(-500, .nan), point(-400, 70), point(-300, 101), point(-200, 60)]]
        let overview = try XCTUnwrap(UsageOverviewSnapshot(chart: chart(window: window, segments: segments), window: window, now: now))
        XCTAssertEqual(overview.observedSegments, [[point(-600, 80)], [point(-400, 70)], [point(-200, 60)]])
        XCTAssertNil(UsageOverviewSnapshot(chart: chart(window: window, segments: segments, source: .derivedEstimate), window: window, now: now))
        XCTAssertNil(UsageOverviewSnapshot(chart: chart(window: window, segments: segments), window: window, now: window.resetsAt))
    }

    func testLatestOnlyOverviewNeverFabricatesEarlierHistoryOrUnknownMonthlyTarget() throws {
        let current = observation(at: now.addingTimeInterval(-60))
        let overview = try XCTUnwrap(UsageOverviewSnapshot(observations: [], current: current, now: now, safetyBuffer: 7))
        XCTAssertEqual(overview.observedSegments, [[point(-60, 75)]])
        XCTAssertEqual(overview.latest, point(-60, 75))
        XCTAssertEqual(overview.target.last?.remaining, 7)
        XCTAssertNil(UsageOverviewSnapshot(observations: [current], current: nil, now: now, safetyBuffer: 3))
        XCTAssertNil(UsageOverviewSnapshot(observations: [current], current: current, now: current.resetsAt, safetyBuffer: 3))

        let monthly = observation(at: now.addingTimeInterval(-60), startsAt: nil)
        let unknownStart = try XCTUnwrap(UsageOverviewSnapshot(observations: [], current: monthly, now: now, safetyBuffer: 3))
        XCTAssertTrue(unknownStart.target.isEmpty)
        XCTAssertEqual(unknownStart.observedSegments, [[point(-60, 75)]])
        XCTAssertEqual(UsageOverviewSnapshot.historyReadStart(current: monthly, now: now), now.addingTimeInterval(-31 * 86_400))
    }

    func testProviderCorrectionSourceAndGapBoundariesSurviveOverview() throws {
        let observations = [
            observation(at: now.addingTimeInterval(-90_000), remaining: 90),
            observation(at: now.addingTimeInterval(-3_600), remaining: 80),
            observation(at: now.addingTimeInterval(-3_000), remaining: 85),
            observation(at: now.addingTimeInterval(-1_600), remaining: 70, source: "legacyCredits"),
            observation(at: now.addingTimeInterval(-60), remaining: 60, source: "legacyCredits")
        ]
        let overview = try XCTUnwrap(UsageOverviewSnapshot(observations: observations, current: observations.last, now: now, safetyBuffer: 3))
        XCTAssertEqual(overview.observedSegments.map(\.count), [1, 1, 1, 2])
    }

    private func window() -> UsageWindow {
        UsageWindow(remainingPercent: 65, resetsAt: now.addingTimeInterval(3_600), durationMinutes: 7 * 24 * 60)
    }

    private func point(_ offset: TimeInterval, _ remaining: Double) -> UsageChartPoint {
        UsageChartPoint(date: now.addingTimeInterval(offset), remaining: remaining)
    }

    private func observation(
        at date: Date, remaining: Double = 75,
        startsAt: Date? = Date(timeIntervalSince1970: 1_800_000_000 - 6 * 86_400),
        source: String = "creditUsagePercent"
    ) -> AllowanceObservation {
        AllowanceObservation(metric: "grok-weekly", observedAt: date, remainingPercent: remaining,
                             resetsAt: now.addingTimeInterval(3_600), startsAt: startsAt, source: source)
    }

    private func chart(window: UsageWindow, segments: [[UsageChartPoint]], source: UsageValueSource = .account) -> UsageChartSnapshot {
        UsageChartSnapshot(
            observedSource: source,
            target: [UsageChartPoint(date: window.startsAt, remaining: 100), UsageChartPoint(date: window.resetsAt, remaining: 3)],
            currentProjection: [point(-60, 65), point(3_600, 0)],
            reference: UsageChartReferenceSeries(source: .tokenEstimate, points: [point(-3_600, 99)]),
            currentAllowanceReset: window.resetsAt,
            allowanceWindows: [
                UsageAllowanceWindowSeries(resetsAt: window.startsAt, observedSegments: [[point(-86_400, 99)]]),
                UsageAllowanceWindowSeries(resetsAt: window.resetsAt, observedSegments: segments)
            ], currentRunsFaster: false, accessibilityValue: ""
        )
    }
}
