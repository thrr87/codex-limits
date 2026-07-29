import AppKit
import Charts
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor
    @StateObject private var workspace: AnalyticsWorkspaceStore
    @StateObject private var assistedInsights: CodexAssistedInsightStore
    @Environment(\.openSettings) private var openSettings

    init(
        monitor: UsageMonitor,
        defaults: UserDefaults = .standard,
        assistedInsights: CodexAssistedInsightStore? = nil
    ) {
        self.monitor = monitor
        _workspace = StateObject(
            wrappedValue: AnalyticsWorkspaceStore(defaults: defaults)
        )
        _assistedInsights = StateObject(
            wrappedValue: assistedInsights ?? CodexAssistedInsightStore()
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
                assistedInsights: assistedInsights,
                analyticsPreferencesChanged: {
                    monitor.analyticsPreferencesDidChange(
                        exploration: workspace.state,
                        dispositions: workspace.insightDispositions
                    )
                },
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

@MainActor
struct AnalyticsWorkspaceBody: View {
    let reader: UsageReaderSnapshot
    @ObservedObject var store: AnalyticsWorkspaceStore
    @ObservedObject var assistedInsights: CodexAssistedInsightStore
    let analyticsPreferencesChanged: () -> Void
    let resetReminderState: ResetReminderState
    let setResetReminderEnabled: (Bool) -> Void
    let setResetReminderLeadTime: (ResetReminderLeadTime) -> Void

    init(
        reader: UsageReaderSnapshot,
        store: AnalyticsWorkspaceStore,
        assistedInsights: CodexAssistedInsightStore,
        analyticsPreferencesChanged: @escaping () -> Void = {},
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
        self.assistedInsights = assistedInsights
        self.analyticsPreferencesChanged = analyticsPreferencesChanged
        self.resetReminderState = resetReminderState
        self.setResetReminderEnabled = setResetReminderEnabled
        self.setResetReminderLeadTime = setResetReminderLeadTime
    }

    @ViewBuilder
    var body: some View {
        Group {
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
                InsightsWorkspace(
                    reader: reader,
                    store: store,
                    assistedInsights: assistedInsights
                )
            }
        }
        .onChange(of: store.state) { _, _ in
            analyticsPreferencesChanged()
        }
        .onChange(of: store.insightDispositions) { _, _ in
            analyticsPreferencesChanged()
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
                    Text(
                        weekly.window.remainingPercent,
                        format: .number.precision(.fractionLength(0))
                    )
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    Text("% remaining")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Weekly usage unavailable")
                        .font(.headline)
                }

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
                UsagePerTokenWorkspace(
                    sourceSnapshot: reader.usagePerToken,
                    store: store
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
                .help(
                    "Project, Task Tree, model, and reasoning filters do not change \(store.state.graph.rawValue)."
                )
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

struct UsagePerTokenWorkspace: View {
    let sourceSnapshot: UsagePerTokenSnapshot
    @ObservedObject var store: AnalyticsWorkspaceStore

    @State private var selectedPointID: String?

    private var activePinnedBaselineID: String? {
        guard let current = sourceSnapshot.current,
              store.state.pinnedUsageBaselineAccountPartitionID
                == current.accountPartitionID else {
            return nil
        }
        return store.state.pinnedUsageBaselineID
    }

    private var snapshot: UsagePerTokenSnapshot {
        sourceSnapshot.selectingBaseline(
            activePinnedBaselineID
        )
    }

    private var allEvidence: [WeeklyUsageEvidence] {
        snapshot.history + [snapshot.current].compactMap { $0 }
    }

    private var bounds: DateInterval? {
        guard let first = allEvidence.map(\.interval.start).min(),
              let last = allEvidence.map(\.interval.end).max(),
              last > first else {
            return nil
        }
        return DateInterval(start: first, end: last)
    }

    private var visibleRange: DateInterval? {
        guard let bounds else { return nil }
        if store.state.timeRange == .currentWindow,
           let current = snapshot.current {
            return current.interval
        }
        return store.effectiveRange(
            within: bounds,
            endingAt: snapshot.current?.interval.end ?? bounds.end
        )
    }

    private var visiblePoints: [UsagePerTokenChartPoint] {
        guard let visibleRange else { return [] }
        return snapshot.points.filter {
            $0.date >= visibleRange.start && $0.date <= visibleRange.end
        }
    }

    private var selectedPoint: UsagePerTokenChartPoint? {
        if let selectedPointID,
           let point = visiblePoints.first(where: {
               $0.id == selectedPointID
           }) {
            return point
        }
        return visiblePoints.last(where: \.isCurrent)
            ?? visiblePoints.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    heading
                    Spacer()
                    baselineMenu
                }
                VStack(alignment: .leading, spacing: 10) {
                    heading
                    baselineMenu
                }
            }

            if let comparison = snapshot.comparison,
               let visibleRange {
                chart(
                    comparison: comparison,
                    visibleRange: visibleRange
                )
                selectedPointDetail(comparison: comparison)
                capacity(comparison.equivalentCapacity)
            } else {
                WorkspaceMessage(
                    icon: "chart.xyaxis.line",
                    title: snapshot.reason ?? "Usage per token is unavailable",
                    message: unavailableMessage
                ) {
                    EmptyView()
                }
            }

            if let current = snapshot.current {
                currentFacts(current)
            }
        }
        .onChange(of: store.state.pinnedUsageBaselineID) { _, _ in
            selectedPointID = nil
        }
        .onChange(of: visibleRange) { _, range in
            if let selectedPointID,
               !visiblePoints.contains(where: { $0.id == selectedPointID }) {
                self.selectedPointID = nil
            }
            if range == nil {
                selectedPointID = nil
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Usage per token")
                .font(.title3.weight(.semibold))
            Text("Allowance Intensity compared with your Reference Baseline")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var baselineMenu: some View {
        Menu {
            Button("Previous 4 comparable weeks") {
                store.pinUsageBaseline(nil)
            }
            Divider()
            ForEach(snapshot.eligiblePinnedBaselines) { evidence in
                Button(baselineLabel(evidence)) {
                    store.pinUsageBaseline(
                        evidence.id,
                        accountPartitionID: evidence.accountPartitionID
                    )
                }
            }
        } label: {
            Label(referenceLabel, systemImage: "pin")
        }
        .menuStyle(.borderlessButton)
        .help("Choose a qualifying Reference Baseline")
        .accessibilityLabel("Reference Baseline")
        .accessibilityValue(referenceLabel)
    }

    private var referenceLabel: String {
        if let baseline = snapshot.comparison?.baseline,
           baseline.isPinned {
            return "Pinned week"
        }
        if activePinnedBaselineID != nil {
            return "Pinned week unavailable"
        }
        return "Previous 4 comparable weeks"
    }

    private var unavailableMessage: String {
        if snapshot.current == nil {
            return "Account Movement and Account Token Activity need the same bounded weekly interval."
        }
        if snapshot.reason != "Not enough comparable weeks" {
            return "Raw account and local facts remain visible. The comparison stays hidden until the evidence meets this requirement."
        }
        return "A comparison needs four prior complete weeks with High comparability, or one qualifying pinned week."
    }

    private func chart(
        comparison: UsagePerTokenComparison,
        visibleRange: DateInterval
    ) -> some View {
        let maximum = max(
            visiblePoints.map(\.multiplier).max() ?? 1,
            1
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ChartLegendItem(
                    label: "Current · Account",
                    color: .blue
                )
                ChartLegendItem(
                    label: "Past weeks · Account",
                    color: .secondary
                )
                ChartLegendItem(
                    label: "Reference · 1×",
                    color: .green,
                    dash: [3, 3]
                )
            }

            Chart {
                RuleMark(y: .value("Reference", 1))
                    .foregroundStyle(Color.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

                ForEach(visiblePoints) { point in
                    LineMark(
                        x: .value("Weekly interval", point.date),
                        y: .value("Usage per token", point.multiplier)
                    )
                    .foregroundStyle(Color.secondary.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))

                    PointMark(
                        x: .value("Weekly interval", point.date),
                        y: .value("Usage per token", point.multiplier)
                    )
                    .foregroundStyle(point.isCurrent ? Color.blue : Color.secondary)
                    .symbolSize(point.isCurrent ? 60 : 34)
                }

                if let selectedPoint {
                    RuleMark(
                        x: .value("Selected interval", selectedPoint.date)
                    )
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: visibleRange.start ... visibleRange.end)
            .chartYScale(domain: 0 ... max(1.25, maximum * 1.15))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.16))
                    AxisValueLabel {
                        if let multiplier = value.as(Double.self) {
                            Text(
                                multiplier,
                                format: .number
                                    .precision(.fractionLength(1))
                            )
                            + Text("×")
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
                                selectNearest(
                                    at: location,
                                    proxy: proxy,
                                    geometry: geometry
                                )
                            case .ended:
                                break
                            }
                        }
                }
            }
            .frame(height: 270)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Usage per token")
            .accessibilityValue(
                selectedPoint.map {
                    accessibilityPointSummary(
                        $0,
                        comparison: comparison
                    )
                }
                    ?? "Current Usage per token is \(formattedMultiplier(comparison.multiplier)) the Reference Baseline. \(comparison.confidence.displayName) confidence."
            )
            .accessibilityHint(
                "Use Previous point and Next point for exact values."
            )
        }
    }

    private func selectedPointDetail(
        comparison: UsagePerTokenComparison
    ) -> some View {
        HStack(spacing: 10) {
            if let selectedPoint {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pointSummary(selectedPoint))
                        .fontWeight(.semibold)
                    Text(
                        selectedPoint.evidence.interval.start.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                        + "–"
                        + selectedPoint.evidence.interval.end.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                    .foregroundStyle(.secondary)
                    Text(
                        "Local Token Activity \(selectedPoint.evidence.localTokenActivity.map(compactTokenCount) ?? "Unavailable") · Local Coverage \(localCoverageText(selectedPoint.evidence))"
                    )
                    .foregroundStyle(.secondary)
                    Text(workloadSummary(selectedPoint.evidence))
                        .foregroundStyle(.secondary)
                    Text(
                        "Reference \(baselineLabel(comparison.baseline)) · \(selectedPoint.evidence.coverage.displayName) coverage · \(selectedPoint.confidence.displayName) confidence"
                    )
                    .foregroundStyle(.tertiary)
                    if let reason = selectedPoint.evidence.coverageReason {
                        Text(reason)
                            .foregroundStyle(.tertiary)
                    }
                    if let caveat = selectedPoint.caveat {
                        Text(caveat)
                            .foregroundStyle(.orange)
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
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func capacity(
        _ estimate: EquivalentCapacityEstimate
    ) -> some View {
        WorkspaceCard(title: "Equivalent Capacity") {
            FactRow(
                label: "Estimate",
                value: "\(compactTokenCount(estimate.tokens)) account tokens",
                detail: "Derived estimate under the observed workload mix"
            )
            FactRow(
                label: "Range",
                value: "\(compactTokenCount(estimate.lowerTokens))–\(compactTokenCount(estimate.upperTokens))",
                detail: "Across the current and Reference Baseline intervals"
            )
            FactRow(
                label: "Confidence",
                value: estimate.confidence.displayName
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Equivalent Capacity")
        .accessibilityValue(
            "\(compactTokenCount(estimate.tokens)) account tokens, range \(compactTokenCount(estimate.lowerTokens)) to \(compactTokenCount(estimate.upperTokens)), \(estimate.confidence.displayName) confidence"
        )
    }

    private func currentFacts(
        _ current: WeeklyUsageEvidence
    ) -> some View {
        WorkspaceCard(title: "Current interval") {
            FactRow(
                label: "Range",
                value: baselineLabel(current)
            )
            FactRow(
                label: "Allowance Intensity",
                value: current.allowancePointsPerMillionTokens.map {
                    $0.formatted(
                        .number.precision(.fractionLength(1 ... 2))
                    ) + " percentage points per 1M account tokens"
                } ?? "Unavailable",
                detail: current.intensityUnavailableReason.map {
                    "Derived estimate · \($0)"
                } ?? "Derived estimate · Account Movement and Account Token Activity"
            )
            FactRow(
                label: "Account Movement",
                value: current.accountMovementPoints.formatted(
                    .number.precision(.fractionLength(0 ... 2))
                ) + " percentage points",
                detail: "Account"
            )
            FactRow(
                label: "Account Token Activity",
                value: compactTokenCount(current.accountTokenActivity),
                detail: "Account"
            )
            FactRow(
                label: "Local Token Activity",
                value: current.localTokenActivity.map(compactTokenCount)
                    ?? "Unavailable",
                detail: "Codex local records"
            )
            FactRow(
                label: "Local Coverage",
                value: current.localCoveragePercent.map {
                    $0.formatted(
                        .number.precision(.fractionLength(0 ... 1))
                    ) + "%"
                } ?? "Unavailable",
                detail: localCoverageDetail(current)
            )
            if let cache = current.cachedInputShare {
                FactRow(
                    label: "Cached input share",
                    value: cache.formatted(
                        .percent.precision(.fractionLength(0 ... 1))
                    )
                )
            }
            FactRow(
                label: "Boundary",
                value: current.boundaryQuality.rawValue.capitalized
            )
        }
    }

    private func pointSummary(
        _ point: UsagePerTokenChartPoint
    ) -> String {
        "\(formattedMultiplier(point.multiplier)) baseline · \(point.evidence.accountMovementPoints.formatted(.number.precision(.fractionLength(0 ... 2)))) percentage points · \(compactTokenCount(point.evidence.accountTokenActivity)) account tokens"
    }

    private func accessibilityPointSummary(
        _ point: UsagePerTokenChartPoint,
        comparison: UsagePerTokenComparison
    ) -> String {
        let reason = point.evidence.coverageReason.map {
            " \($0)."
        } ?? ""
        let caveat = point.caveat.map {
            " \($0)."
        } ?? ""
        return "\(pointSummary(point)). Local Token Activity \(point.evidence.localTokenActivity.map(compactTokenCount) ?? "Unavailable"). Local Coverage \(localCoverageText(point.evidence)). Workload mix: \(workloadSummary(point.evidence)). Reference \(baselineLabel(comparison.baseline)). \(point.evidence.coverage.displayName) coverage. \(point.confidence.displayName) confidence.\(reason)\(caveat)"
    }

    private func localCoverageText(
        _ evidence: WeeklyUsageEvidence
    ) -> String {
        evidence.localCoveragePercent.map {
            $0.formatted(
                .number.precision(.fractionLength(0 ... 1))
            ) + "%"
        } ?? "Unavailable"
    }

    private func localCoverageDetail(
        _ evidence: WeeklyUsageEvidence
    ) -> String {
        if let reason = evidence.coverageReason {
            return "Derived estimate · \(reason)"
        }
        return "Derived estimate · Same bounded interval"
    }

    private func workloadSummary(
        _ evidence: WeeklyUsageEvidence
    ) -> String {
        let model = dominantShare(evidence.modelShares)
            .map { "\($0.0) \($0.1.formatted(.percent.precision(.fractionLength(0))))" }
            ?? "Model mix unavailable"
        let modelCoverage = evidence.modelAttributionPercent < 99.9
            ? " · Model metadata \(evidence.modelAttributionPercent.formatted(.percent.scale(1).precision(.fractionLength(0))))"
            : ""
        let reasoning = dominantShare(evidence.reasoningShares)
            .map { "\($0.0) \($0.1.formatted(.percent.precision(.fractionLength(0))))" }
            ?? "Reasoning mix unavailable"
        let reasoningCoverage = evidence.reasoningAttributionPercent < 99.9
            ? " · Reasoning metadata \(evidence.reasoningAttributionPercent.formatted(.percent.scale(1).precision(.fractionLength(0))))"
            : ""
        let cache = evidence.cachedInputShare.map {
            "Cached input \($0.formatted(.percent.precision(.fractionLength(0))))"
        } ?? "Cached input unavailable"
        return "\(model)\(modelCoverage) · \(reasoning)\(reasoningCoverage) · \(cache)"
    }

    private func dominantShare(
        _ shares: [String: Double]
    ) -> (String, Double)? {
        shares.max { $0.value < $1.value }
    }

    private func formattedMultiplier(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(1 ... 2))
        ) + "×"
    }

    private func baselineLabel(
        _ evidence: WeeklyUsageEvidence
    ) -> String {
        let start = evidence.interval.start.formatted(
            date: .abbreviated,
            time: .omitted
        )
        let end = evidence.interval.end.formatted(
            date: .abbreviated,
            time: .omitted
        )
        return "\(start)–\(end)"
    }

    private func baselineLabel(
        _ baseline: ReferenceBaseline
    ) -> String {
        let start = baseline.interval.start.formatted(
            date: .abbreviated,
            time: .omitted
        )
        let end = baseline.interval.end.formatted(
            date: .abbreviated,
            time: .omitted
        )
        return "\(start)–\(end)"
    }

    private func selectNearest(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        let x = location.x - frame.origin.x
        guard x >= 0,
              x <= frame.width,
              let date: Date = proxy.value(atX: x),
              let nearest = visiblePoints.min(by: {
                  abs($0.date.timeIntervalSince(date))
                      < abs($1.date.timeIntervalSince(date))
              }) else {
            return
        }
        selectedPointID = nearest.id
    }

    private func moveSelection(by offset: Int) {
        guard !visiblePoints.isEmpty else { return }
        let index = selectedPoint.flatMap { selected in
            visiblePoints.firstIndex(where: { $0.id == selected.id })
        } ?? (offset < 0 ? visiblePoints.count : -1)
        let next = min(max(index + offset, 0), visiblePoints.count - 1)
        selectedPointID = visiblePoints[next].id
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
        guard let date = chartDate(
            at: location,
            proxy: proxy,
            geometry: geometry
        ) else { return }
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
        guard let date = chartDate(
            at: location,
            proxy: proxy,
            geometry: geometry
        ) else { return }
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
        let availability = reader.activeTimeAvailability
        return VStack(alignment: .leading, spacing: 9) {
            FactRow(
                label: "Active time this week",
                value: activeTimeValue(availability),
                detail: activeTimeInterval(availability)
            )
            FactRow(
                label: "Estimated active time available",
                value: availability.estimate.map(activeTimeRange)
                    ?? "Not enough data",
                detail: availability.reason
                    ?? activeTimeInterval(availability)
            )
            if let estimate = availability.estimate {
                FactRow(
                    label: "Estimate coverage",
                    value: estimate.coverage.displayName
                )
                FactRow(
                    label: "Confidence",
                    value: estimate.confidence.displayName,
                    detail: estimate.caveat
                )
                FactRow(
                    label: "Basis",
                    value: "Current week + "
                        + "\(estimate.referenceIntervalIDs.count) comparable weeks"
                )
            }
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
                label: "Active Time coverage",
                value: availability.activeTimeCoverage.displayName,
                detail: availability.activeTimeReason
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active Time facts")
        .accessibilityValue(activeTimeAccessibilityValue(availability))
    }

    private func activeTimeRange(
        _ estimate: ActiveTimeAvailableEstimate
    ) -> String {
        let lower = duration(Int64(estimate.lowerSeconds.rounded(.down)))
        let upper = duration(Int64(estimate.upperSeconds.rounded(.down)))
        return lower == upper ? lower : "\(lower)–\(upper)"
    }

    private func activeTimeInterval(
        _ availability: ActiveTimeAvailabilitySnapshot
    ) -> String {
        guard let interval = availability.observedInterval else {
            return "Weekly interval unavailable"
        }
        let start = interval.start.formatted(
            date: .abbreviated,
            time: .shortened
        )
        let end = interval.end.formatted(
            date: .abbreviated,
            time: .shortened
        )
        return "Observed \(start)–\(end)"
    }

    private func activeTimeValue(
        _ availability: ActiveTimeAvailabilitySnapshot
    ) -> String {
        if availability.activeTimeCoverage == .unavailable
            || (
                availability.activeTimeThisWeek == 0
                    && availability.activeTimeCoverage == .low
            ) {
            return "Not available"
        }
        return duration(
            Int64(availability.activeTimeThisWeek.rounded(.down))
        )
    }

    private func activeTimeAccessibilityValue(
        _ availability: ActiveTimeAvailabilitySnapshot
    ) -> String {
        var parts = [
            "Active time this week \(activeTimeValue(availability))",
            activeTimeInterval(availability)
        ]
        if let estimate = availability.estimate {
            parts.append(
                estimate.accessibilityValue {
                    duration(Int64($0.rounded(.down)))
                }
            )
        } else {
            parts.append(
                "Estimated active time available, not enough data"
            )
            if let reason = availability.reason {
                parts.append(reason)
            }
        }
        return parts.joined(separator: ". ")
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

func usageReceiptTokenTotalDetail(_ reconciles: Bool?) -> String {
    if reconciles == true {
        return "Input plus output"
    }
    if reconciles == false {
        return "Input and output do not match total"
    }
    return "Input or output is unavailable"
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
                detail: usageReceiptTokenTotalDetail(tokens.reconciles)
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

struct InsightsWorkspace: View {
    let reader: UsageReaderSnapshot
    @ObservedObject var store: AnalyticsWorkspaceStore
    @ObservedObject var assistedInsights: CodexAssistedInsightStore
    @State private var showsAssistedInfo = false
    @State private var showsSourcePreflight = false

    private var snapshot: DeterministicInsightsSnapshot { reader.insights }
    private var assistedPayload: CodexMetadataAnalysisPayload {
        CodexMetadataAnalysisPayload.make(
            reader: reader,
            exploration: store.state
        )
    }
    private var assistedScope: CodexAssistedAnalysisScope {
        CodexAssistedAnalysisScope(
            exploration: store.state,
            accountPartitionID: reader.accountPartitionID,
            payload: assistedPayload
        )
    }
    private var sourceSelection: CodexSourceSelection? {
        let selected = CodexSourceSelection.make(
            reader: reader,
            exploration: store.state
        )
        #if CODEX_LIMITS_QA
        if selected == nil {
            let range = assistedPayload.range
            let start = range.map {
                Date(timeIntervalSince1970: TimeInterval($0.start))
            } ?? Date().addingTimeInterval(-3_600)
            let end = range.map {
                Date(timeIntervalSince1970: TimeInterval($0.end))
            } ?? Date()
            return CodexSourceSelection(
                interval: DateInterval(start: start, end: end),
                rootTaskIDs: ["qa-root"],
                taskIDs: ["qa-task"],
                projectLabel: "codex-limits",
                turnIDsByTask: ["qa-task": ["qa-turn"]]
            )
        }
        #endif
        return selected
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if snapshot.insights.isEmpty {
                WorkspaceCard(title: "Deterministic") {
                    Text("No new insights for this range.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(snapshot.activeInsights) { insight in
                    insightCard(insight)
                }
                ForEach(snapshot.expectedInsights) { insight in
                    insightCard(insight)
                }
            }

            if !snapshot.checks.isEmpty {
                WorkspaceCard(title: "Checks") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(snapshot.checks) { check in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.kind.rawValue)
                                    .font(.callout.weight(.medium))
                                Text(check.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }

            if assistedInsights.showsCard(
                for: assistedScope,
                sourceSelection: sourceSelection
            ) {
                codexAssistedCard
            }
        }
        .task(id: reader.accountPartitionID) {
            await assistedInsights.checkAvailability(
                accountPartitionID: reader.accountPartitionID
            )
        }
        .onChange(of: sourceSelection) { _, selection in
            assistedInsights.invalidateSourcePreflight(for: selection)
            guard selection != nil else {
                showsSourcePreflight = false
                return
            }
            if assistedInsights.sourcePreflight == nil {
                showsSourcePreflight = false
            }
        }
        .sheet(
            isPresented: $showsSourcePreflight,
            onDismiss: {
                assistedInsights.cancelSourcePreflight()
            }
        ) {
            if let draft = assistedInsights.sourcePreflight {
                SourceAnalysisPreflightView(
                    draft: draft,
                    cancel: {
                        assistedInsights.cancelSourcePreflight()
                        showsSourcePreflight = false
                    },
                    analyze: { categories in
                        Task {
                            let started =
                                await assistedInsights.startSourceAnalysis(
                                    metadata: assistedPayload,
                                    scope: assistedScope,
                                    selection: draft.selection,
                                    categories: categories
                                )
                            if started {
                                showsSourcePreflight = false
                            }
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var codexAssistedCard: some View {
        WorkspaceCard(title: "Codex-assisted") {
            VStack(alignment: .leading, spacing: 10) {
                if let result = assistedInsights.result(
                    for: assistedScope,
                    sourceSelection: sourceSelection
                ) {
                    Text(result.title)
                        .font(.headline)
                    Text(result.summary)
                        .foregroundStyle(.secondary)
                    ForEach(
                        Array(result.evidence.enumerated()),
                        id: \.offset
                    ) { _, evidence in
                        Text(evidence)
                            .font(.caption)
                    }
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 16,
                        verticalSpacing: 5
                    ) {
                        insightEvidenceRow(
                            "Source",
                            result.source
                        )
                        insightEvidenceRow(
                            "Confidence",
                            result.confidence.displayName
                        )
                        insightEvidenceRow(
                            "Coverage",
                            result.coverage.displayName
                        )
                        insightEvidenceRow(
                            "Freshness",
                            result.freshness.rawValue.capitalized
                        )
                        if !result.intervals.isEmpty {
                            insightEvidenceRow(
                                "Period",
                                result.intervals
                                    .map(assistedInterval)
                                    .joined(separator: "; ")
                            )
                        }
                        insightEvidenceRow(
                            "Updated",
                            result.observedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                    }
                    .font(.caption)

                } else if assistedInsights.isRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(assistedInsights.progressText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(assistedInsights.progressText)
                    Button(
                        assistedInsights.isCancelling ? "Stopping…" : "Cancel"
                    ) {
                        Task {
                            await assistedInsights.cancelAnalysis()
                        }
                    }
                    .disabled(assistedInsights.isCancelling)
                    .accessibilityHint("Stops this Codex analysis")
                } else {
                    if let error = assistedInsights.errorMessage {
                        Text(error)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(error)
                    } else if assistedInsights.wasCancelled {
                        Text("Analysis stopped.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Ask Codex to analyze the metadata shown here.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let overhead = assistedInsights.overhead {
                    assistedOverhead(overhead)
                }

                if assistedInsights.showsAnalyzeAction,
                   !assistedInsights.isRunning {
                    HStack(spacing: 10) {
                        Button(
                            assistedInsights.result(for: assistedScope) == nil
                                ? "Analyze metadata"
                                : "Analyze metadata again"
                        ) {
                            assistedInsights.startAnalysis(
                                payload: assistedPayload,
                                scope: assistedScope
                            )
                        }
                        .accessibilityHint(
                            "Sends bounded metadata to Codex and uses your allowance"
                        )

                        if let sourceSelection {
                            Button("Analyze Source Content") {
                                Task {
                                    await assistedInsights.prepareSourceAnalysis(
                                        selection: sourceSelection
                                    )
                                    guard assistedInsights.sourcePreflight
                                            != nil else {
                                        return
                                    }
                                    showsSourcePreflight = true
                                }
                            }
                            .disabled(assistedInsights.isPreparingSource)
                            .accessibilityHint(
                                "Reads the selected Codex Tasks locally, then shows a preflight before sending anything"
                            )
                        }

                        Button {
                            showsAssistedInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("About Analyze with Codex")
                        .accessibilityLabel("About Analyze with Codex")
                        .popover(isPresented: $showsAssistedInfo) {
                            Text(CodexAssistedCopy.informationTip)
                                .font(.callout)
                                .frame(width: 280, alignment: .leading)
                                .padding(14)
                        }
                    }
                }

                if assistedInsights.isPreparingSource {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing Source Content…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                } else if let error = assistedInsights.sourcePreparationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if assistedInsights.showsStrongerRetry,
                   let label = assistedInsights.strongerRetryLabel {
                    Button(label) {
                        Task {
                            _ = await assistedInsights
                                .retrySourceWithStrongerProfile()
                        }
                    }
                    .accessibilityHint(
                        "Runs the same accepted Source Content again with a stronger profile and uses more allowance"
                    )
                    Text("This uses more Codex allowance. It never runs on its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func assistedOverhead(
        _ overhead: CodexAnalyticsOverhead
    ) -> some View {
        Divider()
        Text("Analytics Overhead")
            .font(.callout.weight(.medium))
        insightEvidenceRow(
            "Request time",
            assistedDuration(overhead.durationSeconds)
        )
        if let movement = overhead.accountMovement {
            insightEvidenceRow(
                "Account movement",
                "\(percent(movement.startRemainingPercent)) → \(percent(movement.endRemainingPercent)) usage remaining"
            )
            Text(
                "Account movement during this request may include other Codex work."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            insightEvidenceRow(
                "Account movement",
                "Not available"
            )
        }
    }

    private func assistedDuration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(seconds, 0)).formatted(
            .units(
                allowed: [.hours, .minutes, .seconds],
                width: .abbreviated,
                maximumUnitCount: 2,
                zeroValueUnits: .hide
            )
        )
    }

    private func assistedInterval(_ interval: DateInterval) -> String {
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

    private func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0 ... 1))))%"
    }

    @ViewBuilder
    private func insightCard(
        _ insight: DeterministicInsight
    ) -> some View {
        WorkspaceCard(title: insight.kind.rawValue) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(insight.title)
                        .font(.headline)
                    Spacer()
                    if insight.disposition == .expected {
                        Text("Expected")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(insight.message)
                    .foregroundStyle(.secondary)
                Text(insight.measurement)
                    .font(.callout.weight(.medium))

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 16,
                    verticalSpacing: 5
                ) {
                    insightEvidenceRow(
                        "Source",
                        "\(insight.source) · \(insight.freshnessText)"
                    )
                    insightEvidenceRow(
                        "Evidence",
                        insight.evidenceSources.joined(separator: " · ")
                    )
                    insightEvidenceRow(
                        "Coverage",
                        insight.coverage.displayName
                    )
                    insightEvidenceRow(
                        "Confidence",
                        insight.confidence.displayName
                    )
                    if let period = insight.periodText {
                        insightEvidenceRow("Period", period)
                    }
                }
                .font(.caption)

                if let caveat = insight.caveat {
                    Text(caveat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let scopeNote = insight.scopeNote {
                    Text(scopeNote)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 14) {
                    if insight.disposition == .expected {
                        Button("Show again") {
                            store.setInsightDisposition(
                                .active,
                                for: insight.id
                            )
                        }
                        .accessibilityHint(
                            "Returns this insight to the active list"
                        )
                    } else {
                        Button("Mark expected") {
                            store.setInsightDisposition(
                                .expected,
                                for: insight.id
                            )
                        }
                        .accessibilityHint(
                            "Keeps the measured evidence and marks the change as expected"
                        )
                    }
                    Button("Dismiss") {
                        store.setInsightDisposition(
                            .dismissed,
                            for: insight.id
                        )
                    }
                    .accessibilityHint(
                        "Hides this insight without changing source history"
                    )
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(insight.accessibilitySummary)
        }
    }

    @ViewBuilder
    private func insightEvidenceRow(
        _ label: String,
        _ value: String
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SourceAnalysisPreflightView: View {
    let draft: CodexSourceContentDraft
    let cancel: () -> Void
    let analyze: (Set<CodexSourceContentCategory>) -> Void
    @State private var selectedCategories:
        Set<CodexSourceContentCategory>

    init(
        draft: CodexSourceContentDraft,
        cancel: @escaping () -> Void,
        analyze: @escaping (Set<CodexSourceContentCategory>) -> Void
    ) {
        self.draft = draft
        self.cancel = cancel
        self.analyze = analyze
        _selectedCategories = State(
            initialValue: Set(draft.availableCategories)
        )
    }

    private var period: String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(Locale(identifier: "en_US"))
        return "\(draft.selection.interval.start.formatted(style))–\(draft.selection.interval.end.formatted(style))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Review Source Content")
                    .font(.title2.weight(.semibold))
                Text(
                    "Codex will receive only the scope and categories selected below."
                )
                .foregroundStyle(.secondary)
            }

            Grid(
                alignment: .leading,
                horizontalSpacing: 18,
                verticalSpacing: 6
            ) {
                if let project = draft.selection.projectLabel {
                    preflightRow("Project", project)
                }
                preflightRow("Period", period)
                preflightRow(
                    "Task Trees",
                    draft.selection.rootTaskIDs.count.formatted()
                )
                preflightRow(
                    "Tasks",
                    draft.selection.taskIDs.count.formatted()
                )
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 9) {
                Text("Content sent")
                    .font(.headline)
                ForEach(draft.availableCategories, id: \.self) { category in
                    Toggle(
                        category.displayName,
                        isOn: Binding(
                            get: {
                                selectedCategories.contains(category)
                            },
                            set: { isSelected in
                                if isSelected {
                                    selectedCategories.insert(category)
                                } else {
                                    selectedCategories.remove(category)
                                }
                            }
                        )
                    )
                }
            }
            .accessibilityElement(children: .contain)

            Text(
                "Uses GPT-5.6 Luna Medium and your Codex allowance."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Spacer()
                Button("Analyze with Codex") {
                    analyze(selectedCategories)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCategories.isEmpty)
                    .accessibilityHint(
                        "Sends the selected categories to Codex"
                    )
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    @ViewBuilder
    private func preflightRow(
        _ label: String,
        _ value: String
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .accessibilityElement(children: .combine)
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
        .accessibilityElement(children: .combine)
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
