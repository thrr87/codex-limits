import AppKit
import SwiftUI
import XCTest
@testable import CodexLimits

@MainActor
final class AnalyticsWorkspaceTests: XCTestCase {
    func testUsageReceiptTokenTotalCopyCoversEveryOptionalBooleanState() {
        XCTAssertEqual(
            usageReceiptTokenTotalDetail(true),
            "Input plus output"
        )
        XCTAssertEqual(
            usageReceiptTokenTotalDetail(false),
            "Input and output do not match total"
        )
        XCTAssertEqual(
            usageReceiptTokenTotalDetail(nil),
            "Input or output is unavailable"
        )
    }

    func testExplorationStatePersistsAcrossStores() {
        let suiteName = "AnalyticsWorkspaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AnalyticsWorkspaceStore(defaults: defaults)
        first.selectSection(.facts)
        first.selectGraph(.tokenActivity)
        first.selectTimeRange(.threeDays)
        first.updateFilters(
            WorkspaceFilters(
                projectID: "codex-limits",
                taskTreeID: "task-42",
                model: "gpt-5.6-luna",
                reasoning: "medium"
            )
        )
        first.selectVisibleRange(
            DateInterval(
                start: Date(timeIntervalSince1970: 1_000),
                end: Date(timeIntervalSince1970: 2_000)
            ),
            within: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 3_000)
            )
        )

        let restored = AnalyticsWorkspaceStore(defaults: defaults)

        XCTAssertEqual(restored.state.section, .facts)
        XCTAssertEqual(restored.state.graph, .tokenActivity)
        XCTAssertEqual(restored.state.timeRange, .selected)
        XCTAssertEqual(restored.state.filters.projectID, "codex-limits")
        XCTAssertEqual(restored.state.filters.taskTreeID, "task-42")
        XCTAssertEqual(restored.state.filters.model, "gpt-5.6-luna")
        XCTAssertEqual(restored.state.filters.reasoning, "medium")
        XCTAssertEqual(
            restored.state.visibleRange,
            DateInterval(
                start: Date(timeIntervalSince1970: 1_000),
                end: Date(timeIntervalSince1970: 2_000)
            )
        )
        XCTAssertTrue(
            renders(
                AnalyticsWorkspaceBody(
                    reader: reader(fetchedAt: Date(timeIntervalSince1970: 1_500)),
                    store: restored,
                    assistedInsights: CodexAssistedInsightStore()
                ),
                size: CGSize(width: 640, height: 780)
            )
        )
    }

    func testPinnedUsageBaselinePersistsUntilCleared() {
        let suiteName = "AnalyticsWorkspaceTests-pin-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AnalyticsWorkspaceStore(defaults: defaults)
        first.pinUsageBaseline(
            "weekly|123",
            accountPartitionID: "account-a"
        )

        XCTAssertEqual(
            AnalyticsWorkspaceStore(defaults: defaults)
                .state.pinnedUsageBaselineID,
            "weekly|123"
        )
        XCTAssertEqual(
            AnalyticsWorkspaceStore(defaults: defaults)
                .state.pinnedUsageBaselineAccountPartitionID,
            "account-a"
        )

        first.pinUsageBaseline(nil)

        XCTAssertNil(
            AnalyticsWorkspaceStore(defaults: defaults)
                .state.pinnedUsageBaselineID
        )
        XCTAssertNil(
            AnalyticsWorkspaceStore(defaults: defaults)
                .state.pinnedUsageBaselineAccountPartitionID
        )
    }

    func testUsagePerTokenKeepsAccountScope() {
        XCTAssertTrue(AnalyticsGraph.usagePerToken.usesAccountScope)
        XCTAssertTrue(AnalyticsGraph.tokenActivity.usesAccountScope)
        XCTAssertFalse(AnalyticsGraph.concurrency.usesAccountScope)
    }

    func testLightweightCoreOffersOnlyAccountGraphs() {
        XCTAssertEqual(
            AnalyticsGraph.coreCases,
            [.usageRemaining, .tokenActivity]
        )
    }

    func testAccountTokenRangeSumsOnlyCompleteFullDays() throws {
        let formatter = ISO8601DateFormatter()
        let interval = DateInterval(
            start: try XCTUnwrap(
                formatter.date(from: "2026-07-01T12:00:00Z")
            ),
            end: try XCTUnwrap(
                formatter.date(from: "2026-07-04T12:00:00Z")
            )
        )
        let days = try [
            ("2026-07-01T00:00:00Z", 100, TokenDayCompleteness.complete),
            ("2026-07-02T00:00:00Z", 200, .complete),
            ("2026-07-03T00:00:00Z", 300, .complete),
            ("2026-07-04T00:00:00Z", 400, .partial)
        ].map {
            TokenDay(
                date: try XCTUnwrap(formatter.date(from: $0.0)),
                tokens: Int64($0.1),
                completeness: $0.2
            )
        }

        let range = AccountTokenActivityRange(
            days: days,
            interval: interval
        )

        XCTAssertEqual(range.days.map(\.tokens), [200, 300])
        XCTAssertEqual(range.completeDayCount, 2)
        XCTAssertEqual(range.completeTokens, 500)

        let missingDay = AccountTokenActivityRange(
            days: days.filter { $0.date != days[2].date },
            interval: interval
        )
        XCTAssertNil(missingDay.completeTokens)
    }

    func testRestoredLocalGraphFallsBackToUsageRemaining() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)"
            )
        )
        var state = AnalyticsExplorationState.initial
        state.graph = .concurrency
        defaults.set(
            try JSONEncoder().encode(state),
            forKey: AnalyticsWorkspaceStore.persistenceKey
        )

        XCTAssertEqual(
            AnalyticsWorkspaceStore.restoredState(from: defaults).graph,
            .usageRemaining
        )
    }

    func testChangingGraphKeepsRangeAndFilters() {
        let store = AnalyticsWorkspaceStore(
            defaults: UserDefaults(suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)")!
        )
        let bounds = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 10_000)
        )
        let chosen = DateInterval(
            start: Date(timeIntervalSince1970: 2_000),
            end: Date(timeIntervalSince1970: 7_000)
        )
        let filters = WorkspaceFilters(
            projectID: "codex-limits",
            taskTreeID: nil,
            model: "gpt-5.6-luna",
            reasoning: "medium"
        )

        store.updateFilters(filters)
        store.selectVisibleRange(chosen, within: bounds)
        store.selectGraph(.tokenActivity)

        XCTAssertEqual(store.state.filters, filters)
        XCTAssertEqual(store.state.visibleRange, chosen)
        XCTAssertEqual(store.state.timeRange, .selected)
    }

    func testUsageRemainingAlwaysUsesAccountScope() {
        XCTAssertTrue(AnalyticsGraph.usageRemaining.usesAccountScope)
        XCTAssertTrue(AnalyticsGraph.tokenActivity.usesAccountScope)
    }

    func testTokenActivityRendersAccountDailyBucketsWithoutLocalFacts() {
        let fetchedAt = Date(timeIntervalSince1970: 10 * 86_400)
        let account = UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "weekly",
                name: "Weekly",
                window: UsageWindow(
                    remainingPercent: 75,
                    resetsAt: fetchedAt.addingTimeInterval(3 * 86_400),
                    durationMinutes: 10_080
                )
            ),
            otherLimits: [],
            tokenHistory: [
                TokenDay(
                    date: fetchedAt.addingTimeInterval(-2 * 86_400),
                    tokens: 1_000,
                    completeness: .complete
                ),
                TokenDay(
                    date: fetchedAt.addingTimeInterval(-86_400),
                    tokens: 2_000,
                    completeness: .complete
                ),
                TokenDay(
                    date: fetchedAt,
                    tokens: 500,
                    completeness: .partial
                )
            ],
            emergencyResetCount: 0,
            fetchedAt: fetchedAt
        )
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: fetchedAt,
                previousStatus: nil
            )
        )
        let store = AnalyticsWorkspaceStore(
            defaults: UserDefaults(
                suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)"
            )!
        )
        store.selectGraph(.tokenActivity)

        XCTAssertTrue(
            renders(
                AnalyticsWorkspaceBody(
                    reader: reader,
                    store: store,
                    assistedInsights: CodexAssistedInsightStore()
                ),
                size: CGSize(width: 640, height: 780)
            )
        )
        XCTAssertNil(reader.localTokenActivity.tokens)
    }

    func testRollingTokenActivityViewDistinguishesObservedZeroAndMissing() {
        let now = Date(timeIntervalSince1970: 10 * 86_400)
        let account = usageSnapshot(fetchedAt: now)
        let reset = account.mainLimit!.window.resetsAt
        var exploration = AnalyticsExplorationState.initial
        exploration.graph = .tokenActivity
        exploration.timeRange = .oneDay
        let evaluate: ([UsageSample]) -> UsageReaderSnapshot = { samples in
            UsageIntelligenceEngine.evaluate(
                UsageIntelligenceInput(
                    account: account,
                    samples: samples,
                    safetyBuffer: 3,
                    sourceState: .available,
                    now: now,
                    previousStatus: nil,
                    analyticsExploration: exploration
                )
            )
        }
        let first = UsageSample(
            observedAt: now.addingTimeInterval(-6 * 3_600),
            remainingPercent: 80,
            resetsAt: reset,
            lifetimeTokens: 1_000
        )
        let positive = evaluate([
            first,
            UsageSample(
                observedAt: now,
                remainingPercent: 75,
                resetsAt: reset,
                lifetimeTokens: 1_300
            )
        ])
        let zero = evaluate([
            first,
            UsageSample(
                observedAt: now,
                remainingPercent: 75,
                resetsAt: reset,
                lifetimeTokens: 1_000
            )
        ])
        let missing = evaluate([first])
        let store = AnalyticsWorkspaceStore(
            defaults: UserDefaults(
                suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)"
            )!
        )
        store.selectGraph(.tokenActivity)
        store.selectTimeRange(.oneDay)

        XCTAssertEqual(positive.accountTokenActivity.tokens, 300)
        XCTAssertTrue(
            positive.accountTokenActivity.accessibilityValue.contains(
                "Time without an account reading is empty"
            )
        )
        XCTAssertFalse(
            positive.accountTokenActivity.accessibilityValue.contains(
                "Coverage"
            )
        )
        XCTAssertEqual(zero.accountTokenActivity.tokens, 0)
        XCTAssertTrue(
            zero.accountTokenActivity.accessibilityValue.contains(
                "observed zero-token interval"
            )
        )
        XCTAssertEqual(
            missing.accountTokenActivity.accessibilityValue,
            "No account readings in this range"
        )
        XCTAssertTrue(
            renders(
                AnalyticsWorkspaceBody(
                    reader: positive,
                    store: store,
                    assistedInsights: CodexAssistedInsightStore(),
                    now: now
                ),
                size: CGSize(width: 640, height: 780)
            )
        )
    }

    func testUTCBucketIntervalUsesTheRequestedMacTimeZoneForDisplay() throws {
        let formatter = ISO8601DateFormatter()
        let locale = Locale(identifier: "en_US_POSIX")
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let winter = DateInterval(
            start: try XCTUnwrap(formatter.date(from: "2026-01-01T00:00:00Z")),
            end: try XCTUnwrap(formatter.date(from: "2026-01-02T00:00:00Z"))
        )
        let summer = DateInterval(
            start: try XCTUnwrap(formatter.date(from: "2026-07-01T00:00:00Z")),
            end: try XCTUnwrap(formatter.date(from: "2026-07-02T00:00:00Z"))
        )

        let utcText = accountTokenIntervalText(
            winter,
            timeZone: utc,
            locale: locale
        )
        let cetText = accountTokenIntervalText(
            winter,
            timeZone: berlin,
            locale: locale
        )
        let summerUTCText = accountTokenIntervalText(
            summer,
            timeZone: utc,
            locale: locale
        )
        let cestText = accountTokenIntervalText(
            summer,
            timeZone: berlin,
            locale: locale
        )

        XCTAssertNotEqual(utcText, cetText)
        XCTAssertNotEqual(summerUTCText, cestText)
        XCTAssertEqual(berlin.secondsFromGMT(for: winter.start), 3_600)
        XCTAssertEqual(berlin.secondsFromGMT(for: summer.start), 7_200)
        XCTAssertEqual(winter.duration, 86_400)
        XCTAssertEqual(summer.duration, 86_400)
    }

    func testRollingPresetsEndAtInjectedNowDespiteStaleObservation() throws {
        let now = try date("2026-08-03T09:08:00Z")
        let latestObserved = now.addingTimeInterval(-6 * 3_600)
        let bounds = DateInterval(
            start: now.addingTimeInterval(-12 * 3_600),
            end: latestObserved
        )

        for (range, duration) in [
            (AnalyticsTimeRange.oneDay, 86_400.0),
            (.threeDays, 259_200.0),
            (.fourWeeks, 2_419_200.0),
            (.twelveWeeks, 7_257_600.0)
        ] {
            let resolved = range.interval(within: bounds, now: now)
            XCTAssertEqual(resolved.start, now.addingTimeInterval(-duration))
            XCTAssertEqual(resolved.end, now)
            XCTAssertEqual(resolved.duration, duration)
        }
        XCTAssertNotEqual(
            AnalyticsTimeRange.oneDay.interval(within: bounds, now: now).end,
            latestObserved
        )
        XCTAssertEqual(
            AnalyticsTimeRange.currentWindow.interval(
                within: bounds,
                now: now
            ),
            bounds
        )
    }

    func testRollingPresetDatesKeepElapsedDurationAcrossTimezonesAndDST() throws {
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let losAngeles = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )

        for now in [
            try date("2026-03-29T10:08:00Z"),
            try date("2026-10-25T11:08:00Z")
        ] {
            let interval = AnalyticsTimeRange.oneDay.interval(
                within: DateInterval(
                    start: now.addingTimeInterval(-2 * 86_400),
                    end: now.addingTimeInterval(3_600)
                ),
                now: now
            )
            XCTAssertEqual(interval.start, now.addingTimeInterval(-86_400))
            XCTAssertEqual(interval.end, now)
            XCTAssertEqual(interval.duration, 86_400)
            XCTAssertNotEqual(
                boundaryLabel(interval.start, timeZone: berlin),
                boundaryLabel(interval.end, timeZone: berlin)
            )
        }

        let now = try date("2026-08-03T09:08:00Z")
        let interval = AnalyticsTimeRange.oneDay.interval(
            within: DateInterval(
                start: now.addingTimeInterval(-2 * 86_400),
                end: now.addingTimeInterval(3_600)
            ),
            now: now
        )
        XCTAssertEqual(interval.end, now)
        XCTAssertEqual(interval.duration, 86_400)
        XCTAssertNotEqual(
            boundaryLabel(interval.end, timeZone: berlin),
            boundaryLabel(interval.end, timeZone: losAngeles)
        )
    }

    func testSelectedRangeIsClampedAndRejectsTinySelections() {
        let bounds = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(
            ChartRange.clamped(
                DateInterval(
                    start: Date(timeIntervalSince1970: 0),
                    end: Date(timeIntervalSince1970: 5_000)
                ),
                to: bounds
            ),
            DateInterval(
                start: Date(timeIntervalSince1970: 1_000),
                end: Date(timeIntervalSince1970: 5_000)
            )
        )
        XCTAssertNil(
            ChartRange.clamped(
                DateInterval(
                    start: Date(timeIntervalSince1970: 2_000),
                    end: Date(timeIntervalSince1970: 2_010)
                ),
                to: bounds
            )
        )
    }

    func testSelectedRangeStaysFixedAfterRefresh() throws {
        let store = AnalyticsWorkspaceStore(
            defaults: UserDefaults(
                suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)"
            )!
        )
        let chosen = DateInterval(
            start: try date("2026-08-02T08:15:00Z"),
            end: try date("2026-08-02T14:45:00Z")
        )
        store.selectVisibleRange(
            chosen,
            within: DateInterval(
                start: try date("2026-08-01T00:00:00Z"),
                end: try date("2026-08-03T00:00:00Z")
            )
        )

        XCTAssertEqual(
            store.effectiveRange(
                within: DateInterval(
                    start: try date("2026-08-01T00:00:00Z"),
                    end: try date("2026-08-04T00:00:00Z")
                ),
                now: try date("2026-08-03T12:00:00Z")
            ),
            chosen
        )
    }

    func testSelectedRangeIgnoresAdvancingNowAndPresetsClearIt() {
        let store = AnalyticsWorkspaceStore(
            defaults: UserDefaults(
                suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)"
            )!
        )
        let bounds = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 20_000)
        )
        let chosen = DateInterval(
            start: Date(timeIntervalSince1970: 2_000),
            end: Date(timeIntervalSince1970: 8_000)
        )
        store.selectVisibleRange(chosen, within: bounds)

        XCTAssertEqual(
            store.effectiveRange(
                within: bounds,
                now: Date(timeIntervalSince1970: 15_000)
            ),
            chosen
        )

        store.selectTimeRange(.oneDay)
        XCTAssertNil(store.state.visibleRange)
        store.selectVisibleRange(chosen, within: bounds)
        store.resetVisibleRange()
        XCTAssertEqual(store.state.timeRange, .currentWindow)
        XCTAssertNil(store.state.visibleRange)
    }

    func testSelectedRangeRestoresExactBoundaries() {
        let suite = "AnalyticsWorkspaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let chosen = DateInterval(
            start: Date(timeIntervalSince1970: 2_000),
            end: Date(timeIntervalSince1970: 8_000)
        )
        AnalyticsWorkspaceStore(defaults: defaults).selectVisibleRange(
            chosen,
            within: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 10_000)
            )
        )

        let restored = AnalyticsWorkspaceStore(defaults: defaults)
        XCTAssertEqual(restored.state.timeRange, .selected)
        XCTAssertEqual(restored.state.visibleRange, chosen)
    }

    func testSelectedRangeClampsOneSideWithoutMovingTheOther() {
        let store = AnalyticsWorkspaceStore(
            defaults: UserDefaults(
                suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)"
            )!
        )
        let chosen = DateInterval(
            start: Date(timeIntervalSince1970: 2_000),
            end: Date(timeIntervalSince1970: 8_000)
        )
        store.selectVisibleRange(
            chosen,
            within: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 10_000)
            )
        )

        XCTAssertEqual(
            store.effectiveRange(
                within: DateInterval(
                    start: Date(timeIntervalSince1970: 4_000),
                    end: Date(timeIntervalSince1970: 10_000)
                ),
                now: .now
            ),
            DateInterval(
                start: Date(timeIntervalSince1970: 4_000),
                end: Date(timeIntervalSince1970: 8_000)
            )
        )
    }

    func testSelectedRangeUsesBoundsWhenItNoLongerIntersects() {
        let store = AnalyticsWorkspaceStore(
            defaults: UserDefaults(
                suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)"
            )!
        )
        let chosen = DateInterval(
            start: Date(timeIntervalSince1970: 2_000),
            end: Date(timeIntervalSince1970: 8_000)
        )
        store.selectVisibleRange(
            chosen,
            within: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 10_000)
            )
        )
        let refreshedBounds = DateInterval(
            start: Date(timeIntervalSince1970: 10_000),
            end: Date(timeIntervalSince1970: 20_000)
        )

        XCTAssertEqual(
            store.effectiveRange(within: refreshedBounds, now: .now),
            refreshedBounds
        )
        XCTAssertEqual(store.state.visibleRange, chosen)
    }

    func testZoomInAndOutContinueFromSelectedRange() {
        let store = AnalyticsWorkspaceStore(
            defaults: UserDefaults(
                suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)"
            )!
        )
        let bounds = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 10_000)
        )
        let chosen = DateInterval(
            start: Date(timeIntervalSince1970: 2_000),
            end: Date(timeIntervalSince1970: 8_000)
        )
        let anchor = Date(timeIntervalSince1970: 5_000)
        store.selectVisibleRange(chosen, within: bounds)
        store.zoom(
            factor: 2,
            anchor: anchor,
            currentRange: store.effectiveRange(within: bounds, now: .now),
            within: bounds
        )

        let zoomed = DateInterval(
            start: Date(timeIntervalSince1970: 3_500),
            end: Date(timeIntervalSince1970: 6_500)
        )
        XCTAssertEqual(store.state.visibleRange, zoomed)

        store.zoom(
            factor: 0.5,
            anchor: anchor,
            currentRange: store.effectiveRange(within: bounds, now: .now),
            within: bounds
        )
        XCTAssertEqual(store.state.visibleRange, chosen)
    }

    func testZoomKeepsRangeInsideWindowAndAroundAnchor() {
        let bounds = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 10_000)
        )
        let current = DateInterval(
            start: Date(timeIntervalSince1970: 2_000),
            end: Date(timeIntervalSince1970: 8_000)
        )

        let zoomed = ChartRange.zoomed(
            current,
            factor: 2,
            anchor: Date(timeIntervalSince1970: 5_000),
            within: bounds
        )

        XCTAssertEqual(
            zoomed,
            DateInterval(
                start: Date(timeIntervalSince1970: 3_500),
                end: Date(timeIntervalSince1970: 6_500)
            )
        )
    }

    func testZoomUsesTheVisiblePresetRangeInsteadOfMovingItsEndToTheAnchor() {
        let suite = "AnalyticsWorkspaceTests.zoomPreset"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = AnalyticsWorkspaceStore(defaults: defaults)
        let bounds = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 200_000)
        )
        let now = Date(timeIntervalSince1970: 150_000)
        store.selectTimeRange(.oneDay)
        let visible = store.effectiveRange(
            within: bounds,
            now: now
        )

        store.zoom(
            factor: 2,
            anchor: Date(timeIntervalSince1970: 100_000),
            currentRange: visible,
            within: bounds
        )

        XCTAssertEqual(
            store.state.visibleRange,
            DateInterval(
                start: Date(timeIntervalSince1970: 81_800),
                end: Date(timeIntervalSince1970: 125_000)
            )
        )
    }

    func testNearestPointPrefersObservedValueAtSameTime() {
        let date = Date(timeIntervalSince1970: 4_000)
        let chart = UsageChartSnapshot(
            observedSource: .account,
            target: [UsageChartPoint(date: date, remaining: 60)],
            currentProjection: [UsageChartPoint(date: date, remaining: 48)],
            currentAllowanceReset: date,
            allowanceWindows: [
                UsageAllowanceWindowSeries(
                    resetsAt: date,
                    observedSegments: [[
                        UsageChartPoint(date: date, remaining: 52)
                    ]]
                )
            ],
            currentRunsFaster: true,
            accessibilityValue: "Observed usage"
        )

        let selection = UsageChartSelection.nearest(to: date, in: chart)

        XCTAssertEqual(selection?.series, .observed)
        XCTAssertEqual(selection?.remaining, 52)
        XCTAssertEqual(
            selection?.accessibilityValue,
            "Actual, 52% remaining, Account"
        )
    }

    func testNearestPointIgnoresPointsOutsideVisibleRange() {
        let hidden = Date(timeIntervalSince1970: 1_000)
        let visible = Date(timeIntervalSince1970: 5_000)
        let chart = UsageChartSnapshot(
            observedSource: .account,
            target: [],
            currentProjection: [],
            currentAllowanceReset: visible,
            allowanceWindows: [
                UsageAllowanceWindowSeries(
                    resetsAt: visible,
                    observedSegments: [[
                        UsageChartPoint(date: hidden, remaining: 90),
                        UsageChartPoint(date: visible, remaining: 70)
                    ]]
                )
            ],
            currentRunsFaster: false,
            accessibilityValue: "Observed usage"
        )
        let visibleRange = DateInterval(
            start: Date(timeIntervalSince1970: 4_000),
            end: Date(timeIntervalSince1970: 6_000)
        )

        let selection = UsageChartSelection.nearest(
            to: hidden,
            in: chart,
            within: visibleRange
        )

        XCTAssertEqual(selection?.date, visible)
    }

    func testNearestPointIncludesPriorAllowanceWindows() {
        let historical = Date(timeIntervalSince1970: 1_000)
        let current = Date(timeIntervalSince1970: 5_000)
        let chart = UsageChartSnapshot(
            observedSource: .account,
            target: [],
            currentProjection: [],
            currentAllowanceReset: current,
            allowanceWindows: [
                UsageAllowanceWindowSeries(
                    resetsAt: Date(timeIntervalSince1970: 2_000),
                    observedSegments: [[
                        UsageChartPoint(date: historical, remaining: 40)
                    ]]
                ),
                UsageAllowanceWindowSeries(
                    resetsAt: current,
                    observedSegments: [[
                        UsageChartPoint(date: current, remaining: 70)
                    ]]
                )
            ],
            currentRunsFaster: false,
            accessibilityValue: "Observed usage"
        )

        let selection = UsageChartSelection.nearest(
            to: historical,
            in: chart
        )

        XCTAssertEqual(selection?.date, historical)
        XCTAssertEqual(selection?.remaining, 40)
    }

    func testUsageChartRangeIncludesPriorAllowanceWindows() {
        let historical = Date(timeIntervalSince1970: 1_000)
        let currentWindow = DateInterval(
            start: Date(timeIntervalSince1970: 4_000),
            end: Date(timeIntervalSince1970: 8_000)
        )
        let chart = UsageChartSnapshot(
            observedSource: .account,
            target: [],
            currentProjection: [],
            currentAllowanceReset: currentWindow.end,
            allowanceWindows: [
                UsageAllowanceWindowSeries(
                    resetsAt: Date(timeIntervalSince1970: 2_000),
                    observedSegments: [[
                        UsageChartPoint(date: historical, remaining: 40)
                    ]]
                ),
                UsageAllowanceWindowSeries(
                    resetsAt: currentWindow.end,
                    observedSegments: [[
                        UsageChartPoint(
                            date: Date(timeIntervalSince1970: 5_000),
                            remaining: 70
                        )
                    ]]
                )
            ],
            currentRunsFaster: false,
            accessibilityValue: "Observed usage"
        )

        XCTAssertEqual(
            chart.availableRange(including: currentWindow),
            DateInterval(start: historical, end: currentWindow.end)
        )
    }

    func testObservedSegmentsWithinCurrentWindowExcludePriorWindow() {
        let currentWindow = DateInterval(
            start: Date(timeIntervalSince1970: 4_000),
            end: Date(timeIntervalSince1970: 8_000)
        )
        let currentPoint = UsageChartPoint(
            date: Date(timeIntervalSince1970: 5_000),
            remaining: 70
        )
        let chart = UsageChartSnapshot(
            observedSource: .account,
            target: [],
            currentProjection: [],
            currentAllowanceReset: currentWindow.end,
            allowanceWindows: [
                UsageAllowanceWindowSeries(
                    resetsAt: currentWindow.start,
                    observedSegments: [[
                        UsageChartPoint(
                            date: currentWindow.start,
                            remaining: 40
                        )
                    ]]
                ),
                UsageAllowanceWindowSeries(
                    resetsAt: currentWindow.end,
                    observedSegments: [[currentPoint]]
                )
            ],
            currentRunsFaster: false,
            accessibilityValue: "Observed usage"
        )

        XCTAssertEqual(
            chart.observedSegments(within: currentWindow),
            [[currentPoint]]
        )
    }

    func testHistoricalUsagePresetsReachBeyondTheCurrentWindow() {
        let suite = "AnalyticsWorkspaceTests.historicalUsagePresets"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AnalyticsWorkspaceStore(defaults: defaults)
        let observedAt = Date(timeIntervalSince1970: 10_000_000)
        let oldest = observedAt.addingTimeInterval(-84 * 86_400)
        let currentWindow = DateInterval(
            start: observedAt.addingTimeInterval(-7 * 86_400),
            end: observedAt.addingTimeInterval(86_400)
        )
        let chart = UsageChartSnapshot(
            observedSource: .account,
            target: [],
            currentProjection: [],
            currentAllowanceReset: currentWindow.end,
            allowanceWindows: [
                UsageAllowanceWindowSeries(
                    resetsAt: oldest.addingTimeInterval(7 * 86_400),
                    observedSegments: [[
                        UsageChartPoint(date: oldest, remaining: 100)
                    ]]
                ),
                UsageAllowanceWindowSeries(
                    resetsAt: currentWindow.end,
                    observedSegments: [[
                        UsageChartPoint(date: observedAt, remaining: 70)
                    ]]
                )
            ],
            currentRunsFaster: false,
            accessibilityValue: "Observed usage"
        )
        let bounds = chart.availableRange(including: currentWindow)

        store.selectTimeRange(.fourWeeks)
        XCTAssertEqual(
            store.effectiveRange(within: bounds, now: observedAt),
            DateInterval(
                start: observedAt.addingTimeInterval(-28 * 86_400),
                end: observedAt
            )
        )

        store.selectTimeRange(.twelveWeeks)
        XCTAssertEqual(
            store.effectiveRange(within: bounds, now: observedAt),
            DateInterval(start: oldest, end: observedAt)
        )
    }

    func testKeyboardPointNavigationStartsWithoutPointerSelection() {
        let first = Date(timeIntervalSince1970: 4_000)
        let second = Date(timeIntervalSince1970: 5_000)
        let chart = UsageChartSnapshot(
            observedSource: .account,
            target: [],
            currentProjection: [],
            currentAllowanceReset: second,
            allowanceWindows: [
                UsageAllowanceWindowSeries(
                    resetsAt: second,
                    observedSegments: [[
                        UsageChartPoint(date: first, remaining: 80),
                        UsageChartPoint(date: second, remaining: 70)
                    ]]
                )
            ],
            currentRunsFaster: false,
            accessibilityValue: "Observed usage"
        )
        let visibleRange = DateInterval(
            start: Date(timeIntervalSince1970: 3_000),
            end: Date(timeIntervalSince1970: 6_000)
        )

        XCTAssertEqual(
            UsageChartSelection.stepping(
                from: nil,
                by: 1,
                in: chart,
                within: visibleRange
            )?.date,
            first
        )
        XCTAssertEqual(
            UsageChartSelection.stepping(
                from: nil,
                by: -1,
                in: chart,
                within: visibleRange
            )?.date,
            second
        )
    }

    func testKeyboardPointNavigationIncludesEveryVisibleSeries() {
        let start = Date(timeIntervalSince1970: 4_000)
        let observed = Date(timeIntervalSince1970: 5_000)
        let estimate = Date(timeIntervalSince1970: 6_000)
        let backfill = Date(timeIntervalSince1970: 7_000)
        let chart = UsageChartSnapshot(
            observedSource: .account,
            target: [UsageChartPoint(date: start, remaining: 100)],
            currentProjection: [
                UsageChartPoint(date: estimate, remaining: 50)
            ],
            reference: UsageChartReferenceSeries(
                source: .tokenEstimate,
                points: [UsageChartPoint(date: backfill, remaining: 40)]
            ),
            currentAllowanceReset: observed,
            allowanceWindows: [
                UsageAllowanceWindowSeries(
                    resetsAt: observed,
                    observedSegments: [[
                        UsageChartPoint(date: observed, remaining: 70)
                    ]]
                )
            ],
            currentRunsFaster: true,
            accessibilityValue: "Usage"
        )
        let range = DateInterval(
            start: start.addingTimeInterval(-1),
            end: backfill.addingTimeInterval(1)
        )

        let first = UsageChartSelection.stepping(
            from: nil,
            by: 1,
            in: chart,
            within: range
        )
        let second = UsageChartSelection.stepping(
            from: first,
            by: 1,
            in: chart,
            within: range
        )
        let third = UsageChartSelection.stepping(
            from: second,
            by: 1,
            in: chart,
            within: range
        )
        let fourth = UsageChartSelection.stepping(
            from: third,
            by: 1,
            in: chart,
            within: range
        )

        XCTAssertEqual(
            [first?.series, second?.series, third?.series, fourth?.series],
            [.target, .observed, .currentEstimate, .estimatedBackfill]
        )
        XCTAssertEqual(fourth?.source, .tokenEstimate)
    }

    func testZoomAnchorPrefersTheLatestObservedPoint() {
        let first = Date(timeIntervalSince1970: 2_000)
        let latest = Date(timeIntervalSince1970: 4_000)
        let chart = UsageChartSnapshot(
            observedSource: .account,
            target: [],
            currentProjection: [],
            currentAllowanceReset: latest,
            allowanceWindows: [
                UsageAllowanceWindowSeries(
                    resetsAt: latest,
                    observedSegments: [[
                        UsageChartPoint(date: first, remaining: 80),
                        UsageChartPoint(date: latest, remaining: 60)
                    ]]
                )
            ],
            currentRunsFaster: false,
            accessibilityValue: "Observed usage"
        )

        XCTAssertEqual(chart.preferredZoomAnchor, latest)
    }

    func testAccountBalanceRemovesRawTrailingZeros() {
        XCTAssertEqual(AccountFactFormatter.balance("250.00000000"), "250")
        XCTAssertEqual(AccountFactFormatter.balance("12.345"), "12.34")
        XCTAssertEqual(AccountFactFormatter.balance("Unlimited"), "Unlimited")
    }

    func testWorkspaceLayoutUsesHeightAndReflowsOnSmallScreens() {
        let large = AnalyticsWorkspaceLayout.fitting(
            visibleSize: CGSize(width: 1_920, height: 1_080)
        )
        let small = AnalyticsWorkspaceLayout.fitting(
            visibleSize: CGSize(width: 520, height: 600)
        )

        XCTAssertEqual(large.width, 640)
        XCTAssertEqual(large.height, 780)
        XCTAssertFalse(large.isCompact)
        XCTAssertEqual(small.width, 480)
        XCTAssertEqual(small.height, 528)
        XCTAssertTrue(small.isCompact)
        XCTAssertEqual(
            AnalyticsWorkspaceLayout.fitting(
                visibleSize: CGSize(width: 390, height: 430)
            ),
            AnalyticsWorkspaceLayout(
                width: 390,
                height: 430,
                isCompact: true
            )
        )
    }

    func testWorkspacePresentationCoversLoadingEmptyErrorStaleAndValid() {
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: nil,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: .distantPast,
                previousStatus: nil
            )
        )

        XCTAssertEqual(
            AnalyticsWorkspacePresentation.resolve(
                reader: reader,
                isRefreshing: true
            ),
            .loading
        )
        XCTAssertEqual(
            AnalyticsWorkspacePresentation.resolve(
                reader: reader,
                isRefreshing: false
            ),
            .empty
        )

        let errorReader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: nil,
                samples: [],
                safetyBuffer: 3,
                sourceState: .failed("Couldn’t read Codex usage."),
                now: .distantPast,
                previousStatus: nil
            )
        )
        XCTAssertEqual(
            AnalyticsWorkspacePresentation.resolve(
                reader: errorReader,
                isRefreshing: false
            ),
            .sourceError("Couldn’t read Codex usage.")
        )

        let account = usageSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_000))
        let validReader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: Date(timeIntervalSince1970: 1_000),
                previousStatus: nil
            )
        )
        XCTAssertEqual(
            AnalyticsWorkspacePresentation.resolve(
                reader: validReader,
                isRefreshing: false
            ),
            .valid
        )

        let staleReader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .failed("Refresh failed."),
                now: Date(timeIntervalSince1970: 2_000),
                previousStatus: nil
            )
        )
        XCTAssertEqual(
            AnalyticsWorkspacePresentation.resolve(
                reader: staleReader,
                isRefreshing: false
            ),
            .stale("Refresh failed.")
        )
    }

    func testPresentationViewsRenderEveryStateAtLargeAndSmallSizes() {
        let presentations: [AnalyticsWorkspacePresentation] = [
            .loading,
            .valid,
            .stale("Showing the last update."),
            .empty,
            .sourceError("Couldn’t read Codex usage.")
        ]
        let sizes = [
            CGSize(width: 390, height: 430),
            CGSize(width: 640, height: 780)
        ]

        for presentation in presentations {
            for size in sizes {
                XCTAssertTrue(
                    renders(
                        AnalyticsWorkspacePresentationView(
                            presentation: presentation,
                            refresh: {}
                        ) {
                            Text("Workspace content")
                        },
                        size: size
                    ),
                    "\(presentation) did not render at \(size)"
                )
            }
        }
    }

    func testWorkspaceBodyRendersGraphsFactsAndInsights() {
        let defaults = UserDefaults(
            suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)"
        )!
        let store = AnalyticsWorkspaceStore(defaults: defaults)
        let reader = reader(fetchedAt: Date(timeIntervalSince1970: 10_000))

        for section in AnalyticsSection.allCases {
            store.selectSection(section)
            XCTAssertTrue(
                renders(
                    AnalyticsWorkspaceBody(
                        reader: reader,
                        store: store,
                        assistedInsights: CodexAssistedInsightStore()
                    ),
                    size: CGSize(width: 640, height: 620)
                ),
                "\(section.rawValue) did not render"
            )
        }

        store.selectSection(.graphs)
        for graph in AnalyticsGraph.allCases {
            store.selectGraph(graph)
            XCTAssertTrue(
                renders(
                    AnalyticsWorkspaceBody(
                        reader: reader,
                        store: store,
                        assistedInsights: CodexAssistedInsightStore()
                    ),
                    size: CGSize(width: 640, height: 620)
                ),
                "\(graph.rawValue) did not render"
            )
        }
    }

    func testExpiredCurrentWindowRendersUnavailableAndHistoricalUsage() throws {
        let start = try date("2026-08-01T12:13:00Z")
        let reset = try date("2026-08-08T12:13:00Z")
        let observedAt = try date("2026-08-03T12:13:00Z")
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: UsageSnapshot(
                    mainLimit: LimitReading(
                        limitId: "weekly",
                        name: "Weekly",
                        window: UsageWindow(
                            remainingPercent: 70,
                            resetsAt: reset,
                            durationMinutes: 10_080
                        )
                    ),
                    otherLimits: [],
                    tokenHistory: [],
                    emergencyResetCount: 0,
                    fetchedAt: observedAt
                ),
                samples: [
                    UsageSample(
                        observedAt: start,
                        remainingPercent: 100,
                        resetsAt: reset
                    )
                ],
                safetyBuffer: 3,
                sourceState: .available,
                now: try date("2026-08-09T12:13:00Z"),
                previousStatus: nil
            )
        )
        let store = AnalyticsWorkspaceStore(
            defaults: UserDefaults(
                suiteName: "AnalyticsWorkspaceTests-\(UUID().uuidString)"
            )!
        )

        XCTAssertNil(reader.weeklyUsageRemaining)
        XCTAssertTrue(
            renders(
                AnalyticsWorkspaceBody(
                    reader: reader,
                    store: store,
                    assistedInsights: CodexAssistedInsightStore()
                ),
                size: CGSize(width: 640, height: 780)
            )
        )

        store.selectTimeRange(.fourWeeks)
        XCTAssertTrue(
            renders(
                AnalyticsWorkspaceBody(
                    reader: reader,
                    store: store,
                    assistedInsights: CodexAssistedInsightStore()
                ),
                size: CGSize(width: 640, height: 780)
            )
        )
    }

    func testUsagePerTokenComparisonRendersAtSmallAndLargeSizes() {
        let suiteName =
            "AnalyticsWorkspaceTests-usage-per-token-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AnalyticsWorkspaceStore(defaults: defaults)
        store.selectTimeRange(.fourWeeks)
        let current = comparisonWeek(
            index: 5,
            movement: 40,
            tokens: 10_000_000
        )
        let history = (0 ... 3).map {
            comparisonWeek(
                index: $0,
                movement: Double(($0 + 1) * 10),
                tokens: 10_000_000
            )
        }
        let snapshot = UsagePerTokenEngine.evaluate(
            current: current,
            history: history,
            pinnedBaselineID: nil
        )

        for size in [
            CGSize(width: 390, height: 430),
            CGSize(width: 640, height: 780)
        ] {
            XCTAssertTrue(
                renders(
                    UsagePerTokenWorkspace(
                        sourceSnapshot: snapshot,
                        store: store
                    ),
                    size: size
                ),
                "Usage per token comparison did not render at \(size)"
            )
        }
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func boundaryLabel(
        _ date: Date,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func renders<Content: View>(
        _ view: Content,
        size: CGSize
    ) -> Bool {
        let renderer = ImageRenderer(
            content: view.frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        return renderer.nsImage != nil
    }

    private func reader(fetchedAt: Date) -> UsageReaderSnapshot {
        UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: usageSnapshot(fetchedAt: fetchedAt),
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: fetchedAt,
                previousStatus: nil
            )
        )
    }

    private func usageSnapshot(fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "weekly",
                name: "Weekly",
                window: UsageWindow(
                    remainingPercent: 75,
                    resetsAt: fetchedAt.addingTimeInterval(7 * 86_400),
                    durationMinutes: 10_080
                )
            ),
            otherLimits: [],
            tokenHistory: [],
            emergencyResetCount: 2,
            fetchedAt: fetchedAt
        )
    }

    private func comparisonWeek(
        index: Int,
        movement: Double,
        tokens: Int64
    ) -> WeeklyUsageEvidence {
        let start = Date(timeIntervalSince1970: 10_000)
            .addingTimeInterval(Double(index) * 7 * 86_400)
        return WeeklyUsageEvidence(
            id: "week-\(index)",
            accountPartitionID: "account-a",
            limitID: "weekly",
            windowDurationMinutes: 10_080,
            allowanceResetsAt: start.addingTimeInterval(7 * 86_400),
            interval: DateInterval(start: start, duration: 7 * 86_400),
            isComplete: index < 5,
            accountMovementPoints: movement,
            accountTokenActivity: tokens,
            localTokenActivity: Int64(Double(tokens) * 0.9),
            localCoveragePercent: 90,
            boundaryQuality: .tight,
            maximumAccountGap: 15 * 60,
            modelShares: [
                "gpt-5.6-sol": 0.8,
                "gpt-5.6-luna": 0.2
            ],
            modelAttributionPercent: 100,
            reasoningShares: ["high": 0.8, "medium": 0.2],
            reasoningAttributionPercent: 100,
            cachedInputShare: 0.4,
            containsUnknownCorrection: false,
            containsAccountChange: false,
            containsCounterDecrease: false,
            tokenDefinitionsAlign: true,
            localSourceContinuous: true,
            localSourceReason: nil
        )
    }

}
