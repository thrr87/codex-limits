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
                resetReminderState: monitor.resetReminderState,
                refresh: {
                    Task { await monitor.refresh() }
                },
                setResetReminderEnabled: { isEnabled in
                    Task {
                        await monitor.setResetReminderEnabled(isEnabled)
                    }
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
                store: workspace,
                resetReminderState: monitor.resetReminderState,
                setResetReminderEnabled: { isEnabled in
                    Task {
                        await monitor.setResetReminderEnabled(isEnabled)
                    }
                },
                setResetReminderLeadTime: { leadTime in
                    Task {
                        await monitor.setResetReminderLeadTime(leadTime)
                    }
                }
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
    let resetReminderState: ResetReminderState
    let setResetReminderEnabled: (Bool) -> Void
    let setResetReminderLeadTime: (ResetReminderLeadTime) -> Void

    init(
        reader: UsageReaderSnapshot,
        store: AnalyticsWorkspaceStore,
        resetReminderState: ResetReminderState = ResetReminderState(
            isEnabled: false,
            leadTime: .hours24,
            authorization: .unknown,
            delivery: .off
        ),
        setResetReminderEnabled: @escaping (Bool) -> Void = { _ in },
        setResetReminderLeadTime: @escaping (ResetReminderLeadTime) -> Void = { _ in }
    ) {
        self.reader = reader
        self.store = store
        self.resetReminderState = resetReminderState
        self.setResetReminderEnabled = setResetReminderEnabled
        self.setResetReminderLeadTime = setResetReminderLeadTime
    }

    @ViewBuilder
    var body: some View {
        switch store.state.section {
        case .graphs:
            GraphsWorkspace(reader: reader, store: store)
        case .facts:
            FactsWorkspace(
                reader: reader,
                store: store,
                resetReminderState: resetReminderState,
                setResetReminderEnabled: setResetReminderEnabled,
                setResetReminderLeadTime: setResetReminderLeadTime
            )
        case .insights:
            InsightsWorkspace(reader: reader)
        }
    }
}

private struct WorkspaceHeader: View {
    let reader: UsageReaderSnapshot
    let isRefreshing: Bool
    let isCompact: Bool
    let resetReminderState: ResetReminderState
    let refresh: () -> Void
    let setResetReminderEnabled: (Bool) -> Void
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
        if let summary = reader.bankedResets {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 5) {
                    HeaderFact(
                        label: "Banked resets",
                        value: summary.headerValue(at: context.date)
                    )
                    .help(summary.inspectionText(at: context.date))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Banked resets")
                    .accessibilityValue(
                        "\(summary.headerValue(at: context.date)) · \(summary.inspectionText(at: context.date))"
                    )

                    if summary.currentNextKnownExpiry(at: context.date) != nil
                        || resetReminderState.isEnabled {
                        Button {
                            setResetReminderEnabled(
                                !resetReminderState.isEnabled
                            )
                        } label: {
                            Image(
                                systemName: resetReminderState.isEnabled
                                    ? "bell.fill"
                                    : "bell"
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            resetReminderState.isEnabled
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .help(resetReminderState.controlHelp)
                        .accessibilityLabel("Reset Reminder")
                        .accessibilityValue(
                            "\(resetReminderState.isEnabled ? "On" : "Off"). \(resetReminderState.statusText)"
                        )
                        .accessibilityHint(
                            resetReminderState.isEnabled
                                ? "Turn reminder off."
                                : "Turn reminder on."
                        )
                    }
                }
            }
        } else {
            HeaderFact(label: "Banked resets", value: "Unavailable")
        }
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
                ConcurrencyWorkspace(reader: reader, store: store)
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
        } else {
            WorkspaceFilterMenu(reader: reader, store: store)
        }
    }

    @ViewBuilder
    private var usageRemaining: some View {
        if let weekly = reader.weeklyUsageRemaining {
            VStack(alignment: .leading, spacing: 14) {
                UsageRemainingChart(
                    window: weekly.window,
                    chart: reader.chart,
                    evidence: reader.evidence,
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
                    if let gap = reader.guidance?.runway.gapText {
                        GridRow {
                            Text("Gap to reset")
                                .foregroundStyle(.secondary)
                            Text(gap)
                        }
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

private struct ConcurrencyWorkspace: View {
    let reader: UsageReaderSnapshot
    @ObservedObject var store: AnalyticsWorkspaceStore

    @State private var selectedPoint: ConcurrencyPoint?

    private var bounds: DateInterval {
        reader.activityTimeline.interval
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

    private var slice: ActivityTimelineSlice {
        reader.activityTimeline.slice(
            in: visibleRange,
            filters: store.state.filters
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Concurrency")
                    .font(.title3.weight(.semibold))
                Text("Active Task Trees over time")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    ChartLegendItem(
                        label: "Active Task Trees · Codex local records",
                        color: .purple
                    )
                    Spacer()
                    intervalLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    ChartLegendItem(
                        label: "Active Task Trees · Codex local records",
                        color: .purple
                    )
                    intervalLabel
                }
            }

            if slice.points.isEmpty {
                WorkspaceMessage(
                    icon: "chart.xyaxis.line",
                    title: "No Concurrency data",
                    message: slice.reason
                        ?? "No completed Active Turns were observed."
                ) {
                    EmptyView()
                }
                .frame(minHeight: 190)
            } else {
                chart
                selectedPointDetail
                zoomControls
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("Active Time")
                        .foregroundStyle(.secondary)
                    Text(duration(slice.activeTime))
                }
                GridRow {
                    Text("Peak concurrency")
                        .foregroundStyle(.secondary)
                    Text("\(slice.maximumConcurrency)")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Coverage")
                        .foregroundStyle(.secondary)
                    Text(slice.coverage.displayName)
                }
            }
            .font(.callout)

            if let reason = slice.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onChange(of: visibleRange) { _, range in
            if let selectedPoint, !range.contains(selectedPoint.date) {
                self.selectedPoint = nil
            }
        }
        .onChange(of: store.state.filters) { _, _ in
            selectedPoint = nil
        }
    }

    private var intervalLabel: some View {
        Text(
            "\(visibleRange.start.formatted(date: .abbreviated, time: .shortened))–\(visibleRange.end.formatted(date: .abbreviated, time: .shortened))"
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private var chart: some View {
        Chart {
            ForEach(slice.points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Active Task Trees", point.count)
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
                    y: .value("Active Task Trees", selectedPoint.count)
                )
                .foregroundStyle(Color.purple)
                .symbolSize(52)
            }
        }
        .chartXScale(domain: visibleRange.start ... visibleRange.end)
        .chartYScale(domain: 0 ... max(1, slice.maximumConcurrency))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.16))
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text("\(count)")
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
        .frame(height: 260)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Concurrency")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(
            "Use Previous point and Next point for exact values."
        )
    }

    private var accessibilityValue: String {
        if let selectedPoint {
            return pointSummary(selectedPoint)
        }
        let trees = slice.maximumConcurrency == 1
            ? "Active Task Tree"
            : "Active Task Trees"
        return "\(duration(slice.activeTime)) Active Time, peak \(slice.maximumConcurrency) \(trees), \(slice.coverage.displayName) coverage"
    }

    private var selectedPointDetail: some View {
        HStack(spacing: 10) {
            if let selectedPoint {
                let taskTrees = taskTreeLabels(selectedPoint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(
                            "\(selectedPoint.count) \(selectedPoint.count == 1 ? "Active Task Tree" : "Active Task Trees")"
                        )
                        .fontWeight(.semibold)
                        Text(
                            selectedPoint.date.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                    Text(
                        taskTrees.isEmpty
                            ? "No Active Task Trees"
                            : taskTrees.joined(separator: " · ")
                    )
                        .foregroundStyle(.secondary)
                    Text(
                        "Codex local records · \(slice.coverage.displayName) coverage"
                    )
                    .foregroundStyle(.tertiary)
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
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var zoomControls: some View {
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

    private func taskTreeLabels(_ point: ConcurrencyPoint) -> [String] {
        let projects = Dictionary(
            reader.localTaskProjections.map {
                ($0.taskID, $0.projectLabel)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        return point.taskTreeIDs.map { taskID in
            let task = "Task \(taskID.prefix(8))"
            return projects[taskID].flatMap { $0 }.map {
                "\($0) · \(task)"
            } ?? task
        }
    }

    private func pointSummary(_ point: ConcurrencyPoint) -> String {
        let trees = taskTreeLabels(point).joined(separator: ", ")
        let countLabel = point.count == 1
            ? "Active Task Tree"
            : "Active Task Trees"
        let treeDetail = trees.isEmpty ? "No Active Task Trees" : trees
        return "\(point.count) \(countLabel) at \(point.date.formatted(date: .abbreviated, time: .shortened)). \(treeDetail). Codex local records. \(slice.coverage.displayName) coverage."
    }

    private func moveSelection(by offset: Int) {
        selectedPoint = steppedPoint(
            in: slice.points,
            from: selectedPoint,
            by: offset
        )
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
        selectedPoint = nearestPoint(
            in: slice.points,
            to: date,
            date: \.date
        )
    }

    private func zoom(by factor: CGFloat) {
        let anchor = selectedPoint?.date ?? Date(
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

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(
            .units(
                allowed: [.hours, .minutes, .seconds],
                width: .abbreviated,
                maximumUnitCount: 2,
                zeroValueUnits: .hide
            )
        )
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
        guard !store.state.filters.isEmpty else {
            return reader.localTokenActivity.slice(in: visibleRange)
        }
        let receipts = reader.usageReceipts.slice(
            in: visibleRange,
            filters: store.state.filters
        )
        return LocalTokenActivitySlice(
            tokens: receipts.totalTokens,
            points: receipts.points,
            coverage: receipts.coverage,
            reason: receipts.reason
        )
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
        selectedPoint = steppedPoint(
            in: localSlice.points,
            from: selectedPoint,
            by: offset
        )
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
        selectedPoint = nearestPoint(
            in: localSlice.points,
            to: date,
            date: \.date
        )
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
    let reader: UsageReaderSnapshot
    @ObservedObject var store: AnalyticsWorkspaceStore

    private var range: DateInterval {
        let bounds = reader.usageReceipts.interval
        return store.effectiveRange(
            within: bounds,
            endingAt: min(
                reader.localTokenActivity.observedAt ?? bounds.end,
                bounds.end
            )
        )
    }

    private var options: UsageReceiptFilterOptions {
        reader.usageReceipts.filterOptions(in: range)
    }

    var body: some View {
        Menu {
            Picker(
                "Project",
                selection: filterBinding(\.projectID)
            ) {
                Text("All Projects").tag(nil as String?)
                ForEach(options.projects, id: \.self) { project in
                    Text(project).tag(Optional(project))
                }
            }
            Picker(
                "Task Tree",
                selection: filterBinding(\.taskTreeID)
            ) {
                Text("All Task Trees").tag(nil as String?)
                ForEach(options.taskTrees, id: \.self) { task in
                    Text("Task \(String(task.prefix(8)))")
                        .tag(Optional(task))
                }
            }
            Picker(
                "Model",
                selection: filterBinding(\.model)
            ) {
                Text("All Models").tag(nil as String?)
                ForEach(options.models, id: \.self) { model in
                    Text(model).tag(Optional(model))
                }
            }
            Picker(
                "Reasoning",
                selection: filterBinding(\.reasoning)
            ) {
                Text("All Reasoning Levels").tag(nil as String?)
                ForEach(options.reasoningLevels, id: \.self) { reasoning in
                    Text(reasoning.capitalized)
                        .tag(Optional(reasoning))
                }
            }
            if !store.state.filters.isEmpty {
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

    private func filterBinding(
        _ keyPath: WritableKeyPath<WorkspaceFilters, String?>
    ) -> Binding<String?> {
        Binding(
            get: { store.state.filters[keyPath: keyPath] },
            set: { value in
                var filters = store.state.filters
                filters[keyPath: keyPath] = value
                store.updateFilters(filters)
            }
        )
    }
}

private struct UsageRemainingChart: View {
    let window: UsageWindow
    let chart: UsageChartSnapshot
    let evidence: UsageEvidence
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
            selectedRangeDetail

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
    private var selectedRangeDetail: some View {
        if store.state.timeRange == .selected,
           let range = store.state.visibleRange {
            let points = chart.observed
                .filter { range.contains($0.date) }
                .sorted { $0.date < $1.date }
            if let first = points.first, let last = points.last {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        "\(Int(first.remaining.rounded()))% \(first.date.formatted(date: .abbreviated, time: .shortened)) – \(Int(last.remaining.rounded()))% \(last.date.formatted(date: .abbreviated, time: .shortened))"
                    )
                    .monospacedDigit()
                    Text(
                        "\(chart.observedSource.rawValue) · \(evidence.coverage.displayName) coverage · \(evidence.confidence.displayName) confidence"
                    )
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
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
        }
        if !chart.historicalProjection.isEmpty {
            ChartLegendItem(
                label: "Past estimate",
                color: .secondary,
                dash: [2, 3]
            )
        }
        if !chart.estimatedBackfill.isEmpty {
            ChartLegendItem(
                label: "Estimated backfill · Token activity",
                color: .orange,
                dash: [1, 4]
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
        ForEach(
            Array(chart.observedSegments.enumerated()),
            id: \.offset
        ) { segmentIndex, segment in
            ForEach(segment) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Actual", point.remaining),
                    series: .value("Series", "Actual \(segmentIndex)")
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.stepEnd)

                PointMark(
                    x: .value("Time", point.date),
                    y: .value("Actual", point.remaining)
                )
                .foregroundStyle(Color.blue)
                .symbolSize(12)
            }
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

        ForEach(chart.estimatedBackfill) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Estimated backfill", point.remaining),
                series: .value("Series", "Estimated backfill")
            )
            .foregroundStyle(Color.orange)
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [1, 4]))
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
                Text(selection.source.label)
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
            Text(
                "\(evidence.coverage.displayName) coverage · \(evidence.confidence.displayName) confidence"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                "\(evidence.coverage.displayName) coverage, \(evidence.confidence.displayName) confidence"
            )

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
        case .estimatedBackfill: .orange
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
    @ObservedObject var store: AnalyticsWorkspaceStore
    let resetReminderState: ResetReminderState
    let setResetReminderEnabled: (Bool) -> Void
    let setResetReminderLeadTime: (ResetReminderLeadTime) -> Void

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
                if let summary = reader.bankedResets {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            FactRow(
                                label: "Available",
                                value: "\(summary.availableCount)"
                            )
                            FactRow(
                                label: "Reset detail",
                                value: summary.detailCoverage.displayName,
                                detail: resetDetailText(summary)
                            )
                            if let expiry = summary.currentNextKnownExpiry(
                                at: context.date
                            ) {
                                FactRow(
                                    label: summary.detailCoverage == .complete
                                        ? "Next expiry"
                                        : "Next known expiry",
                                    value: summary.timeUntilNextKnownExpiry(
                                        at: context.date
                                    ).map { "In \($0)" } ?? "Unavailable",
                                    detail: expiry.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                                )
                            } else if summary.availableCount > 0 {
                                Text(
                                    summary.nextKnownExpiry == nil
                                        ? "Expiry dates unavailable"
                                        : "Expiry dates need refresh"
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            FactRow(
                                label: "Source",
                                value: "Account",
                                detail: summary.sourceStatusText(
                                    at: context.date
                                )
                            )
                            Divider()
                            Toggle(
                                "Reset Reminder",
                                isOn: Binding(
                                    get: {
                                        resetReminderState.isEnabled
                                    },
                                    set: setResetReminderEnabled
                                )
                            )
                            .disabled(
                                !resetReminderState.isEnabled
                                    && summary.currentNextKnownExpiry(
                                        at: context.date
                                    ) == nil
                            )
                            .help(resetReminderState.controlHelp)

                            Picker(
                                "Remind me",
                                selection: Binding(
                                    get: {
                                        resetReminderState.leadTime
                                    },
                                    set: setResetReminderLeadTime
                                )
                            ) {
                                ForEach(ResetReminderLeadTime.allCases) {
                                    leadTime in
                                    Text(
                                        "\(leadTime.displayName) before"
                                    )
                                    .tag(leadTime)
                                }
                            }
                            .disabled(!resetReminderState.isEnabled)

                            Text(resetReminderState.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Banked resets are unavailable.")
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

            WorkspaceCard(title: "Active Time") {
                activeTimeContent
            }

            WorkspaceCard(title: "Usage Receipts") {
                receiptContent
            }
        }
    }

    private var activeTimeContent: some View {
        let slice = reader.activityTimeline.slice(
            in: reader.activityTimeline.interval,
            filters: store.state.filters
        )
        return VStack(alignment: .leading, spacing: 9) {
            FactRow(
                label: "Active Time",
                value: activeTimeValue(slice),
                detail: "Current weekly Allowance Window"
            )
            FactRow(
                label: "Peak concurrency",
                value: "\(slice.maximumConcurrency)"
            )
            FactRow(
                label: "Waiting",
                value: slice.waitingTime.map {
                    duration(Int64($0.rounded(.down)))
                } ?? "Unavailable"
            )
            FactRow(
                label: "Polling",
                value: slice.pollingTime.map {
                    duration(Int64($0.rounded(.down)))
                } ?? "Unavailable",
                detail: slice.activityBreakdownReason
            )
            FactRow(
                label: "Source",
                value: "Codex local records"
            )
            FactRow(
                label: "Coverage",
                value: slice.coverage.displayName,
                detail: slice.reason
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active Time facts")
    }

    private func activeTimeValue(_ slice: ActivityTimelineSlice) -> String {
        if slice.points.isEmpty,
           slice.coverage == .low || slice.coverage == .unavailable {
            return "Not available"
        }
        return duration(Int64(slice.activeTime.rounded(.down)))
    }

    @ViewBuilder
    private var receiptContent: some View {
        let slice = reader.usageReceipts.slice(
            in: receiptRange,
            filters: store.state.filters
        )
        if slice.receipts.isEmpty {
            Text(slice.reason ?? "No Usage Receipts are available.")
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("\(compactTokenCount(slice.totalTokens)) local tokens")
                Spacer()
                Text("\(slice.receiptCoverage.displayName) coverage")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            if let receiptReason = slice.receiptReason {
                Text(receiptReason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if slice.unattributedTokens > 0 {
                Text(
                    "\(compactTokenCount(slice.unattributedTokens)) local tokens could not be matched to a Task."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(receiptProjects(in: slice), id: \.self) { project in
                DisclosureGroup {
                    ForEach(
                        slice.receipts.filter {
                            $0.projectLabel == project
                        }
                    ) { receipt in
                        receiptDisclosure(receipt)
                    }
                } label: {
                    Label(
                        project ?? "Project unavailable",
                        systemImage: "folder"
                    )
                    .font(.headline)
                }
            }
        }
    }

    private var receiptRange: DateInterval {
        let bounds = reader.usageReceipts.interval
        return store.effectiveRange(
            within: bounds,
            endingAt: min(
                reader.localTokenActivity.observedAt ?? bounds.end,
                bounds.end
            )
        )
    }

    private func receiptProjects(
        in slice: UsageReceiptSlice
    ) -> [String?] {
        Array(Set(slice.receipts.map(\.projectLabel))).sorted {
            ($0 ?? "") < ($1 ?? "")
        }
    }

    @ViewBuilder
    private func receiptDisclosure(_ receipt: UsageReceipt) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                FactRow(
                    label: "Local Token Activity",
                    value: compactTokenCount(receipt.tokens)
                )
                FactRow(
                    label: "Task Tree",
                    value: "\(receipt.taskCount) \(receipt.taskCount == 1 ? "Task" : "Tasks")"
                )
                FactRow(
                    label: "Range",
                    value: receipt.intervalText
                )
                UsageReceiptDiagnosticsView(
                    diagnostics: receipt.diagnostics
                )
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Task Tree")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(
                        "Open a Task to see its agents and turns. Models are the effective settings recorded for each turn."
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    UsageReceiptTaskTreeView(
                        node: receipt.taskTree,
                        isRoot: true
                    )
                }
                UsageReceiptBreakdownView(
                    title: "Models",
                    values: receipt.models
                )
                UsageReceiptBreakdownView(
                    title: "Reasoning",
                    values: receipt.reasoningLevels
                )
                FactRow(
                    label: "Coverage",
                    value: receipt.coverage.displayName,
                    detail: receipt.reason
                )
            }
            .padding(.leading, 4)
        } label: {
            HStack {
                Text("Task \(receipt.displayTaskID)")
                Spacer()
                Text(compactTokenCount(receipt.tokens))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(receipt.accessibilityValue)
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

    private func resetDetailText(_ summary: BankedResetSummary) -> String {
        switch summary.detailCoverage {
        case .complete:
            return "Expiry dates known for every available reset"
        case .partial:
            return "\(summary.knownExpiryCount) of \(summary.availableCount) expiry dates known"
        case .unavailable:
            return "Expiry dates unavailable"
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

private func steppedPoint<Point: Equatable>(
    in points: [Point],
    from selected: Point?,
    by offset: Int
) -> Point? {
    guard !points.isEmpty else { return nil }
    guard let selected, let index = points.firstIndex(of: selected) else {
        return offset < 0 ? points.last : points.first
    }
    return points[min(max(index + offset, 0), points.count - 1)]
}

private func nearestPoint<Point>(
    in points: [Point],
    to target: Date,
    date: KeyPath<Point, Date>
) -> Point? {
    points.min {
        abs($0[keyPath: date].timeIntervalSince(target))
            < abs($1[keyPath: date].timeIntervalSince(target))
    }
}

private struct UsageReceiptTaskTreeView: View {
    let node: UsageReceiptTaskNode
    let isRoot: Bool

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                FactRow(
                    label: "Direct Local Token Activity",
                    value: compactTokenCount(node.directTokens),
                    detail: sourceNames(node.tokenSources)
                )
                if node.unattributedTurnTokens > 0 {
                    FactRow(
                        label: "Not linked to a Turn",
                        value: compactTokenCount(
                            node.unattributedTurnTokens
                        ),
                        detail: "Turn metadata is missing"
                    )
                }
                if let relationshipSource = node.relationshipSource {
                    FactRow(
                        label: "Task relationship",
                        value: isRoot ? "Root" : "Observed",
                        detail: sourceName(relationshipSource)
                    )
                }
                if !node.turns.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Turns")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(node.turns) { turn in
                            UsageReceiptTurnView(turn: turn)
                        }
                    }
                }
                if !node.children.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Agent Tasks")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(node.children) { child in
                            UsageReceiptTaskTreeView(
                                node: child,
                                isRoot: false
                            )
                            .padding(.leading, 12)
                        }
                    }
                }
                FactRow(
                    label: "Coverage",
                    value: node.coverage.displayName,
                    detail: node.reason
                )
            }
            .padding(.leading, 6)
            .padding(.top, 5)
        } label: {
            HStack(spacing: 7) {
                Image(
                    systemName: isRoot
                        ? "text.bubble"
                        : "person.crop.circle"
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if !isRoot {
                        Text("Task \(node.displayTaskID)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text(compactTokenCount(node.subtreeTokens))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(node.accessibilityValue)
            .accessibilityHint("Open to show turns and child Tasks")
        }
    }

    private var title: String {
        if isRoot {
            return "Root Task \(node.displayTaskID)"
        }
        return node.agentLabel.map { "Agent \($0)" } ?? "Agent Task"
    }

}

private struct UsageReceiptTurnView: View {
    let turn: UsageReceiptTurn

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                FactRow(
                    label: "Local Token Activity",
                    value: compactTokenCount(turn.tokens),
                    detail: sourceNames(turn.tokenSources)
                )
                UsageReceiptBreakdownView(
                    title: "Effective model",
                    values: turn.effectiveModels
                )
                UsageReceiptBreakdownView(
                    title: "Reasoning",
                    values: turn.reasoningLevels
                )
                UsageReceiptDiagnosticsView(
                    diagnostics: turn.diagnostics
                )
                FactRow(
                    label: "Coverage",
                    value: turn.coverage.displayName,
                    detail: turn.reason
                )
            }
            .padding(.leading, 6)
            .padding(.top, 4)
        } label: {
            HStack {
                Text("Turn \(turn.displayTurnID)")
                Spacer()
                Text(compactTokenCount(turn.tokens))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(turn.accessibilityValue)
            .accessibilityHint(
                "Open to show token, context, time, tool, and compaction facts"
            )
        }
    }

}

private struct UsageReceiptDiagnosticsView: View {
    let diagnostics: UsageReceiptDiagnostics

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                tokenFacts
                Divider()
                contextFacts
                Divider()
                timeFacts
                Divider()
                toolFacts
                Divider()
                compactionFacts
                FactRow(
                    label: "Source",
                    value: sourceNames(diagnostics.sources) ?? "Unavailable"
                )
                FactRow(
                    label: "Coverage",
                    value: diagnostics.coverage.displayName,
                    detail: diagnostics.reason
                )
            }
            .padding(.leading, 6)
            .padding(.top, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Local diagnostics")
        } label: {
            HStack {
                Label("Diagnostics", systemImage: "waveform.path.ecg")
                Spacer()
                Text(diagnostics.coverage.displayName)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityHint(
                "Open to show local token, context, time, tool, and compaction facts"
            )
        }
    }

    @ViewBuilder
    private var tokenFacts: some View {
        Text("Token activity")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        if let tokens = diagnostics.tokens {
            FactRow(
                label: "Input",
                value: tokenValue(tokens.inputTokens)
            )
            FactRow(
                label: "Cached input",
                value: tokenValue(tokens.cachedInputTokens),
                detail: "Included in input"
            )
            FactRow(
                label: "Cache write input",
                value: tokenValue(tokens.cacheWriteInputTokens),
                detail: "Included in input"
            )
            FactRow(
                label: "Output",
                value: tokenValue(tokens.outputTokens)
            )
            FactRow(
                label: "Reasoning output",
                value: tokenValue(tokens.reasoningOutputTokens),
                detail: "Included in output"
            )
            FactRow(
                label: "Total",
                value: compactTokenCount(tokens.totalTokens),
                detail: tokenTotalDetail(tokens.reconciles)
            )
        } else {
            FactRow(
                label: "Token breakdown",
                value: "Unavailable",
                detail: "No bounded token change was observed"
            )
        }
    }

    @ViewBuilder
    private var contextFacts: some View {
        Text("Context")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        if let context = diagnostics.context {
            FactRow(
                label: "Last sample",
                value: context.windowTokens.map {
                    "\(compactTokenCount(context.usedTokens)) of \(compactTokenCount($0))"
                } ?? compactTokenCount(context.usedTokens),
                detail: context.observedAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            FactRow(
                label: "Peak",
                value: compactTokenCount(context.peakTokens)
            )
            if let change = context.changeTokens {
                FactRow(
                    label: "Change",
                    value: change.formatted(.number.sign(strategy: .always())),
                    detail: "\(context.sampleCount) local samples"
                )
            }
        } else {
            FactRow(
                label: "Last sample",
                value: "Unavailable"
            )
        }
    }

    @ViewBuilder
    private var timeFacts: some View {
        Text("Time")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        FactRow(
            label: "Elapsed",
            value: durationText(
                diagnostics.duration.elapsedMilliseconds
            )
        )
        FactRow(
            label: "Execution",
            value: durationText(
                diagnostics.duration.executionMilliseconds
            )
        )
        FactRow(
            label: "Tool activity",
            value: durationText(
                diagnostics.duration.toolMilliseconds
            )
        )
        FactRow(
            label: "Waiting",
            value: durationText(
                diagnostics.duration.waitingMilliseconds
            )
        )
        FactRow(
            label: "Polling",
            value: durationText(
                diagnostics.duration.pollingMilliseconds
            )
        )
        if let unclassified = diagnostics.duration.unclassifiedMilliseconds {
            FactRow(
                label: "Not classified",
                value: durationText(unclassified),
                detail: "Observed Turn time not covered by the facts above"
            )
        }
        if diagnostics.duration.reconciles == false {
            Text("Recorded activity exceeds observed Turn time.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Time facts do not match. Recorded activity exceeds observed Turn time."
                )
        }
    }

    @ViewBuilder
    private var toolFacts: some View {
        Text("Tool activity")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        if diagnostics.tools.isEmpty {
            FactRow(
                label: "Recorded tools",
                value: "None observed",
                detail: "Coverage may be partial"
            )
        } else {
            ForEach(diagnostics.tools) { tool in
                FactRow(
                    label: toolName(tool.toolClass),
                    value: "\(tool.count)"
                )
            }
        }
    }

    @ViewBuilder
    private var compactionFacts: some View {
        Text("Compaction")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        if diagnostics.compactions.isEmpty {
            FactRow(
                label: "Events",
                value: "None observed"
            )
        } else {
            ForEach(diagnostics.compactions) { event in
                FactRow(
                    label: "Compaction",
                    value: event.date.formatted(
                        date: .abbreviated,
                        time: .standard
                    )
                )
            }
        }
    }

    private func durationText(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "Unavailable" }
        if milliseconds < 60_000 {
            let seconds = Double(milliseconds) / 1_000
            return seconds.formatted(
                .number.precision(.fractionLength(seconds < 10 ? 1 : 0))
            ) + " sec"
        }
        let totalSeconds = milliseconds / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes) min \(seconds) sec"
    }

    private func tokenValue(_ value: Int64?) -> String {
        value.map(compactTokenCount) ?? "Unavailable"
    }

    private func tokenTotalDetail(_ reconciles: Bool?) -> String {
        switch reconciles {
        case true:
            "Input plus output"
        case false:
            "Input and output do not match total"
        case nil:
            "Input or output is unavailable"
        }
    }

    private func toolName(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

private struct UsageReceiptBreakdownView: View {
    let title: String
    let values: [UsageReceiptBreakdown]

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(values) { value in
                    HStack {
                        Text(value.label)
                        Spacer()
                        Text(compactTokenCount(value.tokens))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }
}

private func sourceName(_ source: LocalActivitySourceKind) -> String {
    switch source {
    case .appServerThreadList:
        return "Codex Task list"
    case .rolloutJSONL:
        return "Codex local records"
    }
}

private func sourceNames(
    _ sources: [LocalActivitySourceKind]
) -> String? {
    guard !sources.isEmpty else { return nil }
    return sources.map(sourceName).joined(separator: " · ")
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
