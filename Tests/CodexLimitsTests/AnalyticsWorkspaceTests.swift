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
        first.selectGraph(.concurrency)
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
        XCTAssertEqual(restored.state.graph, .concurrency)
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
        XCTAssertFalse(AnalyticsGraph.tokenActivity.usesAccountScope)
        XCTAssertFalse(AnalyticsGraph.concurrency.usesAccountScope)
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
        XCTAssertFalse(AnalyticsGraph.tokenActivity.usesAccountScope)
    }

    func testPresetRangeEndsAtLatestObservedTimeAndIsClampedToWindow() {
        let end = Date(timeIntervalSince1970: 10 * 86_400)
        let bounds = DateInterval(
            start: end.addingTimeInterval(-7 * 86_400),
            end: end
        )
        let latestObserved = end.addingTimeInterval(-5 * 86_400)

        XCTAssertEqual(
            AnalyticsTimeRange.oneDay.interval(
                within: bounds,
                endingAt: latestObserved
            ),
            DateInterval(
                start: latestObserved.addingTimeInterval(-86_400),
                end: latestObserved
            )
        )
        XCTAssertEqual(
            AnalyticsTimeRange.currentWindow.interval(
                within: bounds,
                endingAt: latestObserved
            ),
            bounds
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
        let latestObserved = Date(timeIntervalSince1970: 150_000)
        store.selectTimeRange(.oneDay)
        let visible = store.effectiveRange(
            within: bounds,
            endingAt: latestObserved
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
