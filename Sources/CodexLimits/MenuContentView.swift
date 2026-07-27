import AppKit
import Charts
import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let account = monitor.readerSnapshot.account {
                dashboard(reader: monitor.readerSnapshot, account: account)
            } else {
                emptyState
            }
        }
        .frame(width: 420)
        .padding(16)
        .task { await monitor.refresh() }
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private func dashboard(
        reader: UsageReaderSnapshot,
        account: UsageSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.mainLimit.window.remainingPercent, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("% remaining")
                    .foregroundStyle(.secondary)
                Text(reader.accountSource.rawValue)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    if monitor.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .accessibilityLabel("Refresh usage")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(reader.guidanceTitle)
                    .font(.headline)
                    .foregroundStyle(
                        reader.guidance.map { statusColor($0.status) } ?? .secondary
                    )
                Text(reader.guidanceMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(reader.evidenceText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let interval = reader.interval {
                    Text(interval.text)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let caveat = reader.guidance?.caveat {
                    Text(caveat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            BurnDownChart(
                window: account.mainLimit.window,
                chart: reader.chart
            )

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                    Text("Reset")
                        .foregroundStyle(.secondary)
                    Text(account.mainLimit.window.resetsAt.formatted(date: .abbreviated, time: .shortened))
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

            if !account.otherLimits.isEmpty {
                Divider()
                Text("Other limits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(account.otherLimits) { limit in
                    HStack {
                        Text(limit.name)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(limit.window.remainingPercent.rounded()))%")
                            .monospacedDigit()
                        Text(limit.window.resetsAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }

            Divider()
            HStack {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(reader.updateStatusText(at: context.date))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    openSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.windows.first {
                            $0.isVisible && $0.styleMask.contains(.titled)
                        }?.orderFrontRegardless()
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if monitor.isRefreshing {
                ProgressView()
                Text("Reading Codex usage…")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                Text(
                    monitor.readerSnapshot.sourceMessage
                        ?? "Codex usage is not available."
                )
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await monitor.refresh() }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func statusColor(_ status: PaceStatus) -> Color {
        switch status {
        case .slowDown: .red
        case .onTrack: .green
        case .roomToUseMore: .blue
        }
    }

}

private struct BurnDownChart: View {
    let window: UsageWindow
    let chart: UsageChartSnapshot

    private var currentColor: Color {
        chart.currentRunsFaster ? .red : .blue
    }

    private var xAxisDates: [Date] {
        let step: TimeInterval = window.durationMinutes <= 24 * 60 ? 3_600 : 86_400
        var dates: [Date] = []
        var date = window.startsAt
        while date < window.resetsAt {
            dates.append(date)
            date = date.addingTimeInterval(step)
        }
        dates.append(window.resetsAt)
        return dates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ChartLegendItem(label: "Target", color: .green, dash: [3, 3])
                ChartLegendItem(
                    label: "Actual · \(chart.observedSource.rawValue)",
                    color: .blue
                )
                if !chart.currentProjection.isEmpty {
                    ChartLegendItem(label: "Current estimate", color: currentColor, dash: [7, 3])
                    ChartLegendItem(label: "Past estimate", color: .secondary, dash: [2, 3])
                }
            }

            Chart {
                ForEach(chart.target) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Target", point.remaining),
                        series: .value("Series", "Target")
                    )
                    .foregroundStyle(Color.green.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }

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

                ForEach(chart.currentProjection) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Current", point.remaining),
                        series: .value("Series", "Current")
                    )
                    .foregroundStyle(currentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [7, 3]))
                }

                ForEach(chart.historicalProjection) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Historical", point.remaining),
                        series: .value("Series", "Historical")
                    )
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                }

                if let current = chart.observed.last {
                    RuleMark(x: .value("Now", current.date))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

                    PointMark(
                        x: .value("Now", current.date),
                        y: .value("Remaining now", current.remaining)
                    )
                    .foregroundStyle(currentColor)
                    .symbolSize(55)
                    .annotation(position: .top, spacing: 5) {
                        Text("Now")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                    }
                }

                if let target = chart.target.last {
                    PointMark(
                        x: .value("Reset", target.date),
                        y: .value("Target", target.remaining)
                    )
                    .foregroundStyle(Color.green)
                    .symbolSize(38)
                }

                if let endpoint = chart.currentProjection.last {
                    PointMark(
                        x: .value("Current endpoint", endpoint.date),
                        y: .value("Current endpoint", endpoint.remaining)
                    )
                    .foregroundStyle(currentColor)
                    .symbolSize(32)
                }
            }
            .chartXScale(domain: window.startsAt ... window.resetsAt)
            .chartYScale(domain: 0 ... 100)
            .chartXAxis {
                AxisMarks(values: xAxisDates) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.2))
                    AxisTick(length: 3)
                        .foregroundStyle(Color.secondary)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            if window.durationMinutes <= 24 * 60 {
                                Text(date, format: .dateTime.hour())
                                    .offset(x: date == window.startsAt ? 8 : date == window.resetsAt ? -8 : 0)
                            } else {
                                Text(date, format: .dateTime.weekday(.abbreviated))
                                    .offset(x: date == window.startsAt ? 8 : date == window.resetsAt ? -8 : 0)
                            }
                        }
                    }
                    .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.0, 25.0, 50.0, 75.0, 100.0]) { value in
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
            .frame(height: 190)
            .padding(.horizontal, 8)
            .accessibilityLabel("Usage forecast")
            .accessibilityValue(chart.accessibilityValue)
        }
    }
}

private struct ChartLegendItem: View {
    let label: String
    let color: Color
    var dash: [CGFloat] = []

    var body: some View {
        HStack(spacing: 4) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
            }
            .frame(width: 18, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @AppStorage(UsageMonitor.safetyBufferKey) private var safetyBuffer = 3.0
    @AppStorage(LoginItem.preferenceKey) private var launchAtLogin = true
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Stepper(value: $safetyBuffer, in: 1 ... 10, step: 1) {
                Text("Safety buffer: \(Int(safetyBuffer))%")
            }
            .onChange(of: safetyBuffer) { _, value in
                monitor.updateSafetyBuffer(value)
            }

            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: updateLaunchAtLogin
            ))

            if let loginItemError {
                Text(loginItemError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History sync") {
                Text("Keep usage history in a folder available on your other Macs.")
                    .foregroundStyle(.secondary)

                if let folderName = monitor.syncFolderName {
                    LabeledContent("Folder", value: folderName)
                    Button("Stop Syncing") {
                        Task { await monitor.stopHistorySync() }
                    }
                } else {
                    Button("Choose Folder…", action: chooseHistoryFolder)
                }

                Text("Use this folder only on Macs signed in to the same Codex account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Choose a private folder that isn’t shared with other people.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let syncErrorMessage = monitor.syncErrorMessage {
                    Label(syncErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 380)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            loginItemError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = "Couldn’t update the login setting."
        }
    }

    private func chooseHistoryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { await monitor.connectHistoryFolder(directory) }
    }
}

enum LoginItem {
    static let preferenceKey = "launchAtLogin"

    static func enableByDefault() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: preferenceKey) == nil else { return }
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            defaults.set(true, forKey: preferenceKey)
        } catch {
            defaults.set(false, forKey: preferenceKey)
        }
    }
}
