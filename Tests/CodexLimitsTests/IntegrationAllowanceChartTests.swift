import ClaudeIntegrationCore
import XCTest
@testable import CodexLimits

final class IntegrationAllowanceChartTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnePointHasNoInventedHistoryAndFreshCompatiblePointsForecast() throws {
        let first = point(0, 80)
        let second = point(600, 75)
        let single = try chart([first], now: 0)
        XCTAssertEqual(single.chart.observed.count, 1)
        XCTAssertTrue(single.chart.currentProjection.isEmpty)
        let recorded = try chart([first, second], now: 600)
        XCTAssertEqual(recorded.chart.observed.map(\.remaining), [80, 75])
        XCTAssertEqual(recorded.chart.currentProjection.first?.date, second.observedAt)
        XCTAssertEqual(recorded.chart.currentProjection.last?.date, second.resetsAt)
        XCTAssertEqual(recorded.chart.currentProjection.last?.remaining, 50)
        XCTAssertEqual(recorded.chart.target.first?.date, first.startsAt)
        XCTAssertNil(recorded.chart.reference)
        XCTAssertTrue(try chart([first, point(30, 79)], now: 30).chart.currentProjection.isEmpty)
    }

    func testGapsCorrectionsResetsStalenessAndConflictsBreakForecasts() throws {
        let first = point(0, 80)
        for next in [point(1_801, 75), point(600, 90), point(600, 75, reset: 7_200)] {
            let value = try chart([first, next], now: next.observedAt.timeIntervalSince(date))
            XCTAssertTrue(value.chart.currentProjection.isEmpty)
            XCTAssertEqual(value.chart.allObservedSegments.count, 2)
        }
        XCTAssertTrue(try chart([first, point(600, 75)], now: 600, stale: true).chart.currentProjection.isEmpty)
        XCTAssertTrue(try chart([first, point(600, 75)], now: 2_400).chart.currentProjection.isEmpty)
        XCTAssertTrue(try chart([first, point(600, 75)], now: 3_601).chart.currentProjection.isEmpty)
        XCTAssertTrue(try chart([first, point(0, 90), point(600, 75)], now: 600).chart.currentProjection.isEmpty)
    }

    func testMetricsStaySeparateAndUnknownMonthlyStartHasNoTarget() throws {
        let monthly = AllowanceObservation(metric: "grok-monthly", observedAt: date, remainingPercent: 25, resetsAt: date.addingTimeInterval(30 * 86_400))
        let other = AllowanceObservation(metric: "claude-five-hour", observedAt: date, remainingPercent: 99, resetsAt: date.addingTimeInterval(3_600))
        let data = try XCTUnwrap(IntegrationAllowanceChart(metric: monthly.metric, observations: [monthly, other], current: nil, now: date, isStale: false, safetyBuffer: 3))
        XCTAssertEqual(data.chart.observed.map(\.remaining), [25])
        XCTAssertTrue(data.chart.target.isEmpty)
        XCTAssertTrue(data.chart.currentProjection.isEmpty)
        XCTAssertNil(IntegrationAllowanceChart(metric: "missing", observations: [monthly], current: nil, now: date, isStale: false, safetyBuffer: 3))
    }

    func testMissingCurrentWindowOrChangedMeasurementCannotExtendOldForecast() throws {
        let first = point(0, 80)
        let second = point(600, 75)
        let noCurrent = try XCTUnwrap(IntegrationAllowanceChart(metric: first.metric, observations: [first, second], current: nil, now: second.observedAt, isStale: false, safetyBuffer: 3))
        XCTAssertEqual(noCurrent.chart.observed.count, 2)
        XCTAssertTrue(noCurrent.chart.currentProjection.isEmpty)
        for changed in [
            AllowanceObservation(metric: first.metric, observedAt: second.observedAt, remainingPercent: 75, resetsAt: first.resetsAt, startsAt: first.startsAt, source: "new-source"),
            AllowanceObservation(metric: first.metric, observedAt: second.observedAt, remainingPercent: 75, resetsAt: first.resetsAt, startsAt: first.startsAt?.addingTimeInterval(60))
        ] {
            let result = try chart([first, changed], now: 600)
            XCTAssertTrue(result.chart.currentProjection.isEmpty)
            XCTAssertEqual(result.chart.allObservedSegments.count, 2)
        }
    }

    @MainActor
    func testChartRangeIsIsolatedFromCodexAndOtherProviderMetrics() {
        let name = "IntegrationAllowanceChartTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        AnalyticsWorkspaceStore(defaults: defaults, keyPrefix: "grok-weekly.").selectTimeRange(.fourWeeks)
        XCTAssertEqual(AnalyticsWorkspaceStore(defaults: defaults, keyPrefix: "grok-weekly.").state.timeRange, .fourWeeks)
        XCTAssertEqual(AnalyticsWorkspaceStore(defaults: defaults, keyPrefix: "claude-seven-day.").state.timeRange, .currentWindow)
        XCTAssertEqual(AnalyticsWorkspaceStore(defaults: defaults).state.timeRange, .currentWindow)
    }

    private func point(_ seconds: TimeInterval, _ remaining: Double, reset: TimeInterval = 3_600) -> AllowanceObservation {
        AllowanceObservation(metric: "grok-weekly", observedAt: date.addingTimeInterval(seconds), remainingPercent: remaining, resetsAt: date.addingTimeInterval(reset), startsAt: date.addingTimeInterval(reset - 7 * 86_400))
    }

    private func chart(_ observations: [AllowanceObservation], now: TimeInterval, stale: Bool = false) throws -> IntegrationAllowanceChart {
        try XCTUnwrap(IntegrationAllowanceChart(metric: "grok-weekly", observations: observations, current: observations.last, now: date.addingTimeInterval(now), isStale: stale, safetyBuffer: 3))
    }
}
