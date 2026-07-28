import AppKit
import Charts
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor
    @StateObject private var workspace: AnalyticsWorkspaceStore
    @Environment(\.openSettings) private var openSettings

    init(
        monitor: UsageMonitor,
        defaults: UserDefaults = .standard
    ) {
        self.monitor = monitor
        _workspace = StateObject(
            wrappedValue: AnalyticsWorkspaceStore(defaults: defaults)
        )
    }

    var body: some View {
        let layout = currentLayout
        VStack(spacing: 0) {
            WorkspaceHeader(
                reader: monitor.readerSnapshot,
                isRefreshing: monitor.isRefreshing,
                isCompact: layout.isCompact,
                refresh: {
                    Task { await monitor.refresh() }
                },
                settings: showSettings
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            Picker(
                "View",
                selection: Binding(
                    get: { workspace.state.section },
                    set: workspace.selectSection
                )
            ) {
                ForEach(AnalyticsSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                workspaceContent
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            workspaceFooter
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: layout.width, height: layout.height)
        .task { await monitor.refresh() }
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    @ViewBuilder
    private var workspaceContent: some View {
        let presentation = AnalyticsWorkspacePresentation.resolve(
            reader: monitor.readerSnapshot,
            isRefreshing: monitor.isRefreshing
        )
        AnalyticsWorkspacePresentationView(
            presentation: presentation,
            refresh: {
                Task { await monitor.refresh() }
            }
        ) {
            AnalyticsWorkspaceBody(
                reader: monitor.readerSnapshot,
                store: workspace
            )
        }
    }

    private var workspaceFooter: some View {
        HStack {
            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }

    private var currentLayout: AnalyticsWorkspaceLayout {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouse, $0.frame, false)
        } ?? NSScreen.main
        return AnalyticsWorkspaceLayout.fitting(
            visibleSize: screen?.visibleFrame.size ?? CGSize(width: 680, height: 852)
        )
    }

    private func showSettings() {
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.windows.first {
                $0.isVisible && $0.styleMask.contains(.titled)
            }?.orderFrontRegardless()
        }
    }
}

struct AnalyticsWorkspacePresentationView<Content: View>: View {
    let presentation: AnalyticsWorkspacePresentation
    let refresh: () -> Void
    @ViewBuilder let content: Content

    init(
        presentation: AnalyticsWorkspacePresentation,
        refresh: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.presentation = presentation
        self.refresh = refresh
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .loading:
            WorkspaceMessage(
                icon: "arrow.clockwise",
                title: "Reading usage",
                message: "Codex Limits is reading your account."
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case let .sourceError(message):
            WorkspaceMessage(
                icon: "exclamationmark.triangle",
                title: "Usage is not available",
                message: message
            ) {
                Button("Try Again", action: refresh)
            }
        case .empty:
            WorkspaceMessage(
                icon: "chart.xyaxis.line",
                title: "No usage data",
                message: "Refresh to check your Codex usage."
            ) {
                Button("Refresh", action: refresh)
            }
        case let .stale(message):
            VStack(alignment: .leading, spacing: 16) {
                StaleDataNotice(message: message)
                content
            }
        case .valid:
            content
        }
    }
}

struct AnalyticsWorkspaceBody: View {
    let reader: UsageReaderSnapshot
    @ObservedObject var store: AnalyticsWorkspaceStore

    @ViewBuilder
    var body: some View {
        switch store.state.section {
        case .graphs:
            GraphsWorkspace(reader: reader, store: store)
        case .facts:
            FactsWorkspace(reader: reader)
        case .insights:
            InsightsWorkspace(reader: reader)
        }
    }
}

private struct WorkspaceHeader: View {
    let reader: UsageReaderSnapshot
    let isRefreshing: Bool
    let isCompact: Bool
    let refresh: () -> Void
    let settings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let weekly = reader.weeklyUsageRemaining {
                    Text("Usage remaining")
                        .font(.headline)
                    Text(
                        weekly.window.remainingPercent,
                        format: .number.precision(.fractionLength(0))
                    )
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    Text("%")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Weekly usage unavailable")
                        .font(.headline)
                }

                Text("Account")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button(action: refresh) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .accessibilityLabel("Refresh usage")

                Button(action: settings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
            }

            if isCompact {
                VStack(alignment: .leading, spacing: 7) {
                    headerFactRows
                }
            } else {
                HStack(spacing: 22) {
                    headerFactRows
                }
            }

            if reader.weeklyUsageRemaining != nil {
                VStack(alignment: .leading, spacing: 3) {
                    Text(reader.guidanceTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(
                            reader.guidance.map { statusColor($0.status) }
                                ?? .secondary
                        )
                    Text(reader.guidanceMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(isCompact ? 2 : 1)
                    Text(reader.evidenceText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var headerFactRows: some View {
        if let weekly = reader.weeklyUsageRemaining {
            HeaderFact(
                label: "Reset",
                value: weekly.window.resetsAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
        }
        HeaderFact(
            label: "Banked resets",
            value: "\(reader.account?.emergencyResetCount ?? 0)"
        )
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HeaderFact(
                label: "Freshness",
                value: reader.updatedText(at: context.date)
                    .replacingOccurrences(of: "Updated ", with: "")
            )
        }
    }

    private func statusColor(_ status: PaceStatus) -> Color {
        switch status {
        case .slowDown: .red
        case .onTrack: .green
        case .roomToUseMore: .blue
        }
    }
}

private struct HeaderFact: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct GraphsWorkspace: View {
    let reader: UsageReaderSnapshot
    @ObservedObject var store: AnalyticsWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            graphToolbar

            switch store.state.graph {
            case .usageRemaining:
                usageRemaining
            case .tokenActivity:
                TokenActivityWorkspace(reader: reader, store: store)
            case .usagePerToken:
                UnavailableGraph(
                    title: "Usage per token",
                    message: "Usage per token is not available for this range."
                )
            case .concurrency:
                UnavailableGraph(
                    title: "Concurrency",
                    message: "Concurrency is not available for this range."
                )
            }
        }
    }

    private var graphToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                graphPicker
                rangePicker
                scopeControl
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                graphPicker
                HStack(spacing: 12) {
                    rangePicker
                    scopeControl
                }
            }
        }
    }

    private var graphPicker: some View {
        Picker(
            "Graph",
            selection: Binding(
                get: { store.state.graph },
                set: store.selectGraph
            )
        ) {
            ForEach(AnalyticsGraph.allCases) { graph in
                Text(graph.rawValue).tag(graph)
            }
        }
        .frame(minWidth: 180)
        .accessibilityLabel("Graph")
    }

    private var rangePicker: some View {
        Picker(
            "Range",
            selection: Binding(
                get: { store.state.timeRange },
                set: store.selectTimeRange
            )
        ) {
            ForEach(AnalyticsTimeRange.allCases.filter {
                $0.isPreset || store.state.timeRange == .selected
            }) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .frame(minWidth: 130)
        .accessibilityLabel("Time range")
    }

    @ViewBuilder
    private var scopeControl: some View {
        if store.state.graph.usesAccountScope {
            Label("Account", systemImage: "person.crop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Project, Task Tree, model, and reasoning filters do not change Usage remaining.")
                .accessibilityLabel("Account scope")
        } else if store.state.graph == .tokenActivity {
            Label("All local activity", systemImage: "laptopcomputer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("This total includes all supported local activity.")
                .accessibilityLabel("All local activity")
        } else {
            WorkspaceFilterMenu(store: store)
        }
    }

    @ViewBuilder
    private var usageRemaining: some View {
        if let weekly = reader.weeklyUsageRemaining {
            VStack(alignment: .leading, spacing: 14) {
                UsageRemainingChart(
                    window: weekly.window,
                    chart: reader.chart,
                    store: store
                )

                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    GridRow {
                        Text("Reset")
                            .foregroundStyle(.secondary)
                        Text(
                            weekly.window.resetsAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                    }
                    GridRow {
                        Text("Suggested pace")
                            .foregroundStyle(.secondary)
                        Text(reader.suggestedPaceText)
                    }
                    GridRow {
                        Text("Runway")
                            .foregroundStyle(.secondary)
                        Text(reader.guidance?.runway.text ?? "Not enough data")
                    }
                    if let range = reader.guidance?.remainingAtResetRange {
                        GridRow {
                            Text("Range")
                                .foregroundStyle(.secondary)
                            Text(range.text)
                        }
                    }
                }
                .font(.callout)
            }
        } else {
            UnavailableGraph(
                title: "Weekly usage unavailable",
                message: "Try refreshing to check again."
            )
        }
    }
}

private struct TokenActivityWorkspace: View {
    let reader: UsageReaderSnapshot
    @ObservedObject var store: AnalyticsWorkspaceStore

    @State private var selectedPoint: LocalTokenActivityPoint?

    private var bounds: DateInterval {
        reader.localTokenActivity.interval
    }

    private var visibleRange: DateInterval {
        store.effectiveRange(
            within: bounds,
            endingAt: min(
                reader.localTokenActivity.observedAt ?? bounds.end,
                bounds.end
            )
        )
    }

    private var localSlice: LocalTokenActivitySlice {
        reader.localTokenActivity.slice(in: visibleRange)
    }

    private var accountCoversVisibleRange: Bool {
        guard let interval = reader.accountTokenActivity.interval else {
            return false
        }
        return abs(interval.start.timeIntervalSince(visibleRange.start)) < 1
            && abs(interval.end.timeIntervalSince(visibleRange.end)) < 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Token activity")
                    .font(.title3.weight(.semibold))
                Text(
                    "Account and local token counts may differ, so we show them separately."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    accountCard
                    localCard
                }
                VStack(spacing: 12) {
                    accountCard
                    localCard
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        chartSourceLabel
                        Spacer()
                        chartIntervalLabel
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        chartSourceLabel
                        chartIntervalLabel
                    }
                }

                if localSlice.points.isEmpty {
                    WorkspaceMessage(
                        icon: "chart.xyaxis.line",
                        title: "No local token activity",
                        message: localEmptyMessage
                    ) {
                        EmptyView()
                    }
                    .frame(minHeight: 170)
                } else {
                    localChart
                }

                selectedPointDetail
            }
        }
        .onChange(of: visibleRange) { _, range in
            if let selectedPoint, !range.contains(selectedPoint.date) {
                self.selectedPoint = nil
            }
        }
    }

    private var chartSourceLabel: some View {
        ChartLegendItem(
            label: "Local Codex records",
            color: .purple
        )
    }

    private var chartIntervalLabel: some View {
        Text(intervalText(visibleRange))
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private var accountCard: some View {
        TokenSourceCard(
            title: "Account",
            source: accountSource,
            value: accountValue,
            detail: accountDetail,
            coverage: accountCoverage,
            freshness: reader.accountTokenActivity.interval?.end,
            freshnessLabel: "Through",
            color: .blue
        )
    }

    private var localCard: some View {
        TokenSourceCard(
            title: "Local",
            source: "Local Codex records",
            value: reader.localTokenActivity.tokens == nil
                ? "Not available"
                : compactTokenCount(localSlice.tokens),
            detail: localDetail,
            coverage: coverageName(localSlice.coverage),
            freshness: reader.localTokenActivity.observedAt,
            freshnessLabel: "Updated",
            color: .purple
        )
    }

    private var accountValue: String {
        guard accountCoversVisibleRange,
              let tokens = reader.accountTokenActivity.tokens else {
            return "Not available"
        }
        return compactTokenCount(tokens)
    }

    private var accountSource: String {
        switch reader.accountTokenActivity.method {
        case .lifetimeDelta:
            "Codex account summary"
        case .dailyBuckets:
            "Codex daily token totals"
        case nil:
            "Codex account"
        }
    }

    private var accountDetail: String {
        guard accountCoversVisibleRange else {
            if reader.accountTokenActivity.tokens != nil {
                return "No account total for this selected range"
            }
            return reader.accountTokenActivity.reason
                ?? "Account token activity is unavailable"
        }
        switch reader.accountTokenActivity.method {
        case .lifetimeDelta:
            return "Change between two account readings"
        case .dailyBuckets:
            return reader.accountTokenActivity.state == .partial
                ? "Sum of complete days"
                : "Complete daily totals"
        case nil:
            return reader.accountTokenActivity.reason
                ?? "Account token activity is unavailable"
        }
    }

    private var accountCoverage: String {
        guard accountCoversVisibleRange else { return "Unavailable" }
        switch reader.accountTokenActivity.state {
        case .exact: return "Complete"
        case .partial: return "Partial"
        case .unavailable: return "Unavailable"
        }
    }

    private var localDetail: String {
        var details: [String] = []
        if let version = reader.localTokenActivity.sourceVersion {
            details.append("Codex \(version)")
        }
        if let reason = localSlice.reason {
            details.append(readerFacingLocalReason(reason))
        }
        return details.isEmpty
            ? "Local Codex records are unavailable"
            : details.joined(separator: " · ")
    }

    private var localEmptyMessage: String {
        localSlice.reason.map(readerFacingLocalReason)
            ?? "No local token events were found in this range."
    }

    private var chartPoints: [LocalTokenActivityPoint] {
        if localSlice.points.first?.date == visibleRange.start {
            return localSlice.points
        }
        return [LocalTokenActivityPoint(date: visibleRange.start, tokens: 0)]
            + localSlice.points
    }

    private var localChart: some View {
        Chart {
            ForEach(chartPoints) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Local tokens", point.tokens),
                    series: .value("Source", "Local Codex records")
                )
                .foregroundStyle(Color.purple)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.stepEnd)
            }

            if let selectedPoint {
                RuleMark(x: .value("Selected time", selectedPoint.date))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(
                    x: .value("Selected time", selectedPoint.date),
                    y: .value("Local tokens", selectedPoint.tokens)
                )
                .foregroundStyle(Color.purple)
                .symbolSize(52)
            }
        }
        .chartXScale(domain: visibleRange.start ... visibleRange.end)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.16))
                AxisValueLabel {
                    if let tokens = value.as(Int64.self) {
                        Text(compactTokenCount(tokens))
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            selectNearestPoint(
                                at: location,
                                proxy: proxy,
                                geometry: geometry
                            )
                        case .ended:
                            selectedPoint = nil
                        }
                    }
            }
        }
        .frame(height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Local token activity")
        .accessibilityValue(
            selectedPoint.map {
                "\(compactTokenCount($0.tokens)) local tokens, \($0.date.formatted(date: .abbreviated, time: .shortened))"
            } ?? "\(compactTokenCount(localSlice.tokens)) local tokens in the selected range"
        )
        .accessibilityHint(
            "Use Previous point and Next point for exact values."
        )
    }

    @ViewBuilder
    private var selectedPointDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                if let selectedPoint {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Text("Local Codex records")
                                .fontWeight(.semibold)
                            Text(compactTokenCount(selectedPoint.tokens))
                                .monospacedDigit()
                            Text(
                                selectedPoint.date.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                            .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("Local Codex records")
                                    .fontWeight(.semibold)
                                Text(compactTokenCount(selectedPoint.tokens))
                                    .monospacedDigit()
                            }
                            Text(
                                selectedPoint.date.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Choose a point for exact details.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    moveSelection(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous point")
                Button {
                    moveSelection(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next point")
            }
            if selectedPoint != nil {
                HStack(spacing: 10) {
                    Text("Account · \(accountSource)")
                        .fontWeight(.semibold)
                    Text(accountValue)
                        .monospacedDigit()
                    Text("selected range")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func moveSelection(by offset: Int) {
        let points = localSlice.points
        guard !points.isEmpty else {
            selectedPoint = nil
            return
        }
        guard let selectedPoint,
              let index = points.firstIndex(of: selectedPoint) else {
            self.selectedPoint = offset < 0 ? points.last : points.first
            return
        }
        let next = min(max(index + offset, 0), points.count - 1)
        self.selectedPoint = points[next]
    }

    private func readerFacingLocalReason(_ reason: String) -> String {
        switch reason {
        case "Local token activity starts from an unbounded counter":
            "The first local reading has no earlier reading"
        case "Local rollout path is unavailable",
             "Local task records are missing":
            "Some local Codex records could not be found"
        case "Local task discovery is incomplete",
             "Local task metadata is incomplete",
             "Local task identity is missing":
            "Some local tasks could not be checked"
        case "This Codex CLI version has not been checked":
            "This Codex version has not been checked"
        case "Installed Codex CLI version is unavailable",
             "Codex CLI version is unavailable":
            "The installed Codex version could not be checked"
        case "Only local activity on this Mac is observed":
            "Only activity on this Mac is included"
        case "Saved local activity could not be read":
            "Saved local activity could not be read"
        case "Local activity could not be saved":
            "Local activity could not be saved"
        case "Local task record continuity changed":
            "A local task record changed"
        default:
            reason
        }
    }

    private func selectNearestPoint(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        guard frame.contains(location),
              let date = proxy.value(
                  atX: location.x - frame.origin.x,
                  as: Date.self
              ) else {
            return
        }
        selectedPoint = localSlice.points.min {
            abs($0.date.timeIntervalSince(date))
                < abs($1.date.timeIntervalSince(date))
        }
    }

    private func coverageName(_ coverage: CoverageLevel) -> String {
        switch coverage {
        case .complete: "Complete"
        case .high: "High"
        case .partial: "Partial"
        case .low: "Low"
        case .unavailable: "Unavailable"
        case .notApplicable: "Not applicable"
        }
    }

    private func intervalText(_ interval: DateInterval) -> String {
        let start = interval.start.formatted(
            date: .abbreviated,
            time: .shortened
        )
        let end = interval.end.formatted(
            date: .abbreviated,
            time: .shortened
        )
        return "\(start)–\(end)"
    }
}

private struct TokenSourceCard: View {
    let title: String
    let source: String
    let value: String
    let detail: String
    let coverage: String
    let freshness: Date?
    let freshnessLabel: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: title == "Account"
                ? "person.crop.circle"
                : "laptopcomputer")
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            Text(source)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack(spacing: 12) {
                Text("Coverage \(coverage)")
                if let freshness {
                    Text(freshnessLabel + " " + freshness.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 155, alignment: .topLeading)
        .background(
            color.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.16))
        }
        .help(
            "\(title), \(source). \(value) tokens. Coverage \(coverage). \(detail)"
        )
    }
}

private struct WorkspaceFilterMenu: View {
    @ObservedObject var store: AnalyticsWorkspaceStore

    var body: some View {
        Menu {
            if store.state.filters.isEmpty {
                Text("All local activity")
            } else {
                filterValue("Project", store.state.filters.projectID)
                filterValue("Task Tree", store.state.filters.taskTreeID)
                filterValue("Model", store.state.filters.model)
                filterValue("Reasoning", store.state.filters.reasoning)
                Divider()
                Button("Clear filters") {
                    store.updateFilters(.all)
                }
            }
        } label: {
            Label(
                store.state.filters.isEmpty ? "All local activity" : "Filters",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityLabel("Local activity filters")
    }

    @ViewBuilder
    private func filterValue(_ label: String, _ value: String?) -> some View {
        if let value {
            Text("\(label): \(value)")
        }
    }
}

private struct UsageRemainingChart: View {
    let window: UsageWindow
    let chart: UsageChartSnapshot
    @ObservedObject var store: AnalyticsWorkspaceStore

    @State private var selection: UsageChartSelection?
    @State private var pendingRange: DateInterval?
    @State private var rangeStart: Date?
    @State private var keyboardRangeStart: Date?

    private var bounds: DateInterval {
        DateInterval(start: window.startsAt, end: window.resetsAt)
    }

    private var visibleRange: DateInterval {
        store.effectiveRange(
            within: bounds,
            endingAt: chart.preferredZoomAnchor ?? min(Date(), bounds.end)
        )
    }

    private var currentColor: Color {
        chart.currentRunsFaster ? .red : .blue
    }

    private var xAxisDates: [Date] {
        let step: TimeInterval = visibleRange.duration <= 2 * 86_400
            ? 6 * 3_600
            : 86_400
        return Array(
            stride(
                from: visibleRange.start,
                to: visibleRange.end,
                by: step
            )
        ) + [visibleRange.end]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { chartLegend }
                VStack(alignment: .leading, spacing: 5) { chartLegend }
            }

            Chart {
                targetMarks
                observedMarks
                estimateMarks
                interactionMarks
            }
            .chartXScale(domain: visibleRange.start ... visibleRange.end)
            .chartYScale(domain: 0 ... 100)
            .chartXAxis {
                AxisMarks(values: xAxisDates) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.2))
                    AxisTick(length: 3)
                        .foregroundStyle(Color.secondary)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(
                                date,
                                format: visibleRange.duration <= 2 * 86_400
                                    ? .dateTime.hour()
                                    : .dateTime.weekday(.abbreviated)
                            )
                        }
                    }
                    .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(
                    position: .leading,
                    values: [0.0, 25.0, 50.0, 75.0, 100.0]
                ) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.2))
                    AxisTick(length: 3)
                        .foregroundStyle(Color.secondary)
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text("\(Int(percent))%")
                        }
                    }
                    .foregroundStyle(Color.secondary)
                }
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                chartOverlay(proxy: proxy)
            }
            .frame(height: 300)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Usage remaining")
            .accessibilityValue(
                selection?.accessibilityValue ?? chart.accessibilityValue
            )
            .accessibilityHint(
                "Use Previous point and Next point for exact values."
            )
            .onChange(of: visibleRange) { _, range in
                if let selection, !range.contains(selection.date) {
                    self.selection = UsageChartSelection.nearest(
                        to: selection.date,
                        in: chart,
                        within: range
                    )
                }
                keyboardRangeStart = nil
            }

            selectedPointDetail

            HStack(spacing: 10) {
                Button {
                    zoom(by: 1.5)
                } label: {
                    Label("Zoom in", systemImage: "plus.magnifyingglass")
                }
                .help("Show a shorter range")

                Button {
                    zoom(by: 1 / 1.5)
                } label: {
                    Label("Zoom out", systemImage: "minus.magnifyingglass")
                }
                .help("Show a longer range")

                if store.state.timeRange == .selected {
                    Button("Reset range") {
                        store.resetVisibleRange()
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    @ViewBuilder
    private var chartLegend: some View {
        ChartLegendItem(label: "Target", color: .green, dash: [3, 3])
        ChartLegendItem(
            label: "Actual · \(chart.observedSource.rawValue)",
            color: .blue
        )
        if !chart.currentProjection.isEmpty {
            ChartLegendItem(
                label: "Current estimate",
                color: currentColor,
                dash: [7, 3]
            )
            ChartLegendItem(
                label: "Past estimate",
                color: .secondary,
                dash: [2, 3]
            )
        }
    }

    @ChartContentBuilder
    private var targetMarks: some ChartContent {
        ForEach(chart.target) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Target", point.remaining),
                series: .value("Series", "Target")
            )
            .foregroundStyle(Color.green.opacity(0.8))
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
    }

    @ChartContentBuilder
    private var observedMarks: some ChartContent {
        ForEach(chart.observed) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Actual", point.remaining),
                series: .value("Series", "Actual")
            )
            .foregroundStyle(Color.blue)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.stepEnd)
        }
    }

    @ChartContentBuilder
    private var estimateMarks: some ChartContent {
        ForEach(chart.currentProjection) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Current estimate", point.remaining),
                series: .value("Series", "Current estimate")
            )
            .foregroundStyle(currentColor)
            .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [7, 3]))
        }

        ForEach(chart.historicalProjection) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Past estimate", point.remaining),
                series: .value("Series", "Past estimate")
            )
            .foregroundStyle(Color.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
        }
    }

    @ChartContentBuilder
    private var interactionMarks: some ChartContent {
        if let pendingRange {
            RectangleMark(
                xStart: .value("Range start", pendingRange.start),
                xEnd: .value("Range end", pendingRange.end),
                yStart: .value("Minimum", 0),
                yEnd: .value("Maximum", 100)
            )
            .foregroundStyle(Color.accentColor.opacity(0.12))
        }

        if let selection {
            RuleMark(x: .value("Selected time", selection.date))
                .foregroundStyle(Color.primary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            PointMark(
                x: .value("Selected time", selection.date),
                y: .value("Selected value", selection.remaining)
            )
            .foregroundStyle(color(for: selection.series))
            .symbolSize(52)
        }
    }

    @ViewBuilder
    private var selectedPointDetail: some View {
        HStack(spacing: 10) {
            if let selection {
                Text(selection.series.rawValue)
                    .font(.callout.weight(.semibold))
                Text("\(Int(selection.remaining.rounded()))% remaining")
                    .monospacedDigit()
                Text(
                    selection.date.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .foregroundStyle(.secondary)
            } else {
                Text("Choose a point for exact details.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                moveSelection(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous point")
            Button {
                moveSelection(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next point")
        }
        .font(.caption)
        .padding(10)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))

        if let selection {
            HStack(spacing: 10) {
                if let keyboardRangeStart {
                    Text(
                        "Range starts \(keyboardRangeStart.formatted(date: .abbreviated, time: .shortened))"
                    )
                    .foregroundStyle(.secondary)
                    Button("Set range end") {
                        selectKeyboardRange(
                            from: keyboardRangeStart,
                            to: selection.date
                        )
                    }
                    Button("Cancel") {
                        self.keyboardRangeStart = nil
                    }
                } else {
                    Button("Set range start") {
                        keyboardRangeStart = selection.date
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func chartOverlay(
        proxy: ChartProxy
    ) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        updateSelection(
                            at: location,
                            proxy: proxy,
                            geometry: geometry
                        )
                    case .ended:
                        if rangeStart == nil {
                            selection = nil
                        }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            guard let date = chartDate(
                                at: value.location,
                                proxy: proxy,
                                geometry: geometry
                            ) else { return }
                            if rangeStart == nil {
                                rangeStart = chartDate(
                                    at: value.startLocation,
                                    proxy: proxy,
                                    geometry: geometry
                                ) ?? date
                            }
                            guard let rangeStart else { return }
                            pendingRange = DateInterval(
                                start: min(rangeStart, date),
                                end: max(rangeStart, date)
                            )
                        }
                        .onEnded { _ in
                            if let pendingRange {
                                store.selectVisibleRange(
                                    pendingRange,
                                    within: bounds
                                )
                            }
                            rangeStart = nil
                            pendingRange = nil
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onEnded { factor in
                            zoom(by: factor)
                        }
                )
        }
    }

    private func updateSelection(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard rangeStart == nil,
              let date = chartDate(
                  at: location,
                  proxy: proxy,
                  geometry: geometry
              ) else { return }
        selection = UsageChartSelection.nearest(
            to: date,
            in: chart,
            within: visibleRange
        )
    }

    private func chartDate(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        guard frame.contains(location) else { return nil }
        return proxy.value(
            atX: location.x - frame.origin.x,
            as: Date.self
        )
    }

    private func zoom(by factor: CGFloat) {
        let anchor = selection?.date
            ?? chart.preferredZoomAnchor
            ?? Date(
                timeIntervalSince1970:
                    (visibleRange.start.timeIntervalSince1970
                        + visibleRange.end.timeIntervalSince1970) / 2
            )
        store.zoom(
            factor: Double(factor),
            anchor: anchor,
            currentRange: visibleRange,
            within: bounds
        )
    }

    private func moveSelection(by offset: Int) {
        selection = UsageChartSelection.stepping(
            from: selection,
            by: offset,
            in: chart,
            within: visibleRange
        )
    }

    private func selectKeyboardRange(from start: Date, to end: Date) {
        store.selectVisibleRange(
            DateInterval(start: min(start, end), end: max(start, end)),
            within: bounds
        )
        keyboardRangeStart = nil
    }

    private func color(for series: UsageChartSeries) -> Color {
        switch series {
        case .observed: .blue
        case .target: .green
        case .currentEstimate: currentColor
        case .pastEstimate: .secondary
        }
    }
}

private struct ChartLegendItem: View {
    let label: String
    let color: Color
    var dash: [CGFloat] = []

    var body: some View {
        HStack(spacing: 5) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 2, dash: dash)
                )
            }
            .frame(width: 20, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

private struct FactsWorkspace: View {
    let reader: UsageReaderSnapshot

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            WorkspaceCard(title: "Account facts") {
                if let facts = reader.accountFacts, !facts.isEmpty {
                    accountFacts(facts)
                } else {
                    Text("Account facts are not available.")
                        .foregroundStyle(.secondary)
                }
            }

            WorkspaceCard(title: "Banked resets") {
                let count = reader.account?.emergencyResetCount ?? 0
                FactRow(
                    label: "Available",
                    value: "\(count) \(count == 1 ? "banked reset" : "banked resets")"
                )
                if count > 0 {
                    Text("Expiry details are not available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            WorkspaceCard(title: "Other limits") {
                if reader.otherLimits.isEmpty {
                    Text("No other limits are available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(reader.otherLimits) { limit in
                        FactRow(
                            label: limit.name,
                            value: "\(Int(limit.window.remainingPercent.rounded()))% remaining"
                        )
                        Text(
                            "Resets \(limit.window.resetsAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            WorkspaceCard(title: "Usage Receipts") {
                Text("No Usage Receipts are available.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func accountFacts(_ facts: AccountFacts) -> some View {
        if let value = facts.lifetimeTokens {
            FactRow(
                label: "Lifetime tokens",
                value: compactTokenCount(value),
                detail: observationDetail(facts.lifetimeTokensObservedAt)
            )
        }
        if let value = facts.peakDailyTokens {
            FactRow(
                label: "Peak daily tokens",
                value: compactTokenCount(value),
                detail: observationDetail(facts.peakDailyTokensObservedAt)
            )
        }
        if let value = facts.longestRunningTurnSeconds {
            FactRow(
                label: "Longest running turn",
                value: duration(value),
                detail: observationDetail(facts.longestRunningTurnObservedAt)
            )
        }
        if let value = facts.currentStreakDays {
            FactRow(
                label: "Current streak",
                value: days(value),
                detail: observationDetail(facts.currentStreakObservedAt)
            )
        }
        if let value = facts.longestStreakDays {
            FactRow(
                label: "Longest streak",
                value: days(value),
                detail: observationDetail(facts.longestStreakObservedAt)
            )
        }
        if let credits = facts.credits {
            FactRow(
                label: "Credits",
                value: credits.unlimited
                    ? "Unlimited"
                    : credits.balance.map(AccountFactFormatter.balance)
                        ?? (credits.hasCredits ? "Available" : "None"),
                detail: observationDetail(
                    credits.balance == nil
                        ? facts.creditsObservedAt
                        : facts.creditBalanceObservedAt
                            ?? facts.creditsObservedAt
                )
            )
        }
        if let spend = facts.spendControl {
            FactRow(
                label: "Spend control",
                value: "\(Int(spend.remainingPercent.rounded()))% remaining",
                detail: observationDetail(facts.spendControlObservedAt)
            )
        }
    }

    private func observationDetail(_ date: Date?) -> String? {
        date.map {
            "Account · \($0.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private func duration(_ seconds: Int64) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }

    private func days(_ value: Int64) -> String {
        "\(value) \(value == 1 ? "day" : "days")"
    }
}

private func compactTokenCount(_ value: Int64) -> String {
    value.formatted(
        .number.notation(.compactName).precision(.fractionLength(0 ... 1))
    )
}

private struct InsightsWorkspace: View {
    let reader: UsageReaderSnapshot

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            WorkspaceCard(title: "Deterministic") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reader.guidanceTitle)
                        .font(.headline)
                    Text(reader.guidanceMessage)
                        .foregroundStyle(.secondary)
                    Text(reader.evidenceText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if let interval = reader.interval {
                        Text(interval.text)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            WorkspaceCard(title: "Codex-assisted") {
                Text("No Codex-assisted insights are available.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkspaceCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

private struct FactRow: View {
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
            }
            .font(.callout)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct UnavailableGraph: View {
    let title: String
    let message: String

    var body: some View {
        WorkspaceMessage(
            icon: "chart.xyaxis.line",
            title: title,
            message: message
        ) {
            EmptyView()
        }
    }
}

private struct StaleDataNotice: View {
    let message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing saved data")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
            }
        } icon: {
            Image(systemName: "clock.badge.exclamationmark")
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color.orange.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}

private struct WorkspaceMessage<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let action: Action

    init(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder action: () -> Action
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding()
    }
}
