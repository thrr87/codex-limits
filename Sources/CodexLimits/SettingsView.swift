import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var integrations: IntegrationPreferences
    @ObservedObject var claudeCode: ClaudeCodeIntegrationStore
    @ObservedObject var grok: GrokIntegrationStore
    @AppStorage(UsageMonitor.safetyBufferKey) private var safetyBuffer = 3.0
    @AppStorage(LoginItem.preferenceKey) private var launchAtLogin = true
    @State private var loginItemError: String?
    @State private var confirmsHistoryDeletion = false
    @State private var confirmsClaudeSetup = false
    @State private var confirmsClaudeDataDeletion = false
    @State private var codexExecutableError: String?
    @State private var claudeExecutableError: String?
    @State private var grokExecutableError: String?
    @State private var confirmsGrokDataDeletion = false

    var body: some View {
        Form {
            Section("Integrations") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Codex")
                        if integrations.isEnabled(.codex) {
                            Text(codexReadiness)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle(
                        "Codex",
                        isOn: Binding(
                            get: { integrations.isEnabled(.codex) },
                            set: setCodexEnabled
                        )
                    )
                    .labelsHidden()
                }

                if integrations.isEnabled(.codex), !monitor.isRefreshing {
                    if codexNotFound {
                        Button("Locate…", action: locateCodexExecutable)
                    }
                    if monitor.readerSnapshot.account == nil {
                        Button("Check again") {
                            Task { await monitor.refresh() }
                        }
                    }
                }
                if let codexExecutableError {
                    Text(codexExecutableError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Claude Code")
                            Text("Beta")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if integrations.isEnabled(.claudeCode)
                            || claudeCode.readiness == .manualCleanupRequired {
                            Text(claudeReadiness)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle(
                        "Claude Code",
                        isOn: Binding(
                            get: {
                                integrations.isEnabled(.claudeCode)
                            },
                            set: setClaudeEnabled
                        )
                    )
                    .labelsHidden()
                }

                claudeActions

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Grok")
                            Text("Beta")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if integrations.isEnabled(.grok) {
                            Text(grok.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("Grok", isOn: Binding(
                        get: { integrations.isEnabled(.grok) },
                        set: setGrokEnabled
                    ))
                    .labelsHidden()
                }
                if integrations.isEnabled(.grok) {
                    HStack {
                        Button("Check again") { Task { await grok.refresh() } }
                            .disabled(!grok.canRefresh)
                        Button("Locate…", action: locateGrokExecutable)
                            .disabled(grok.isRefreshing)
                    }
                    if grok.error == .notFound || grok.error == .unsupported {
                        Link("Install or update Grok Build", destination: URL(string: "https://x.ai/cli")!)
                    }
                }
                if let grokExecutableError {
                    Text(grokExecutableError).font(.caption).foregroundStyle(.secondary)
                }
                if let issue = grok.storageIssue {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                }
                if grok.hasStoredData || integrations.grokExecutablePath != nil {
                    Button("Delete Grok data…", role: .destructive) {
                        confirmsGrokDataDeletion = true
                    }
                }
            }

            Section("Menu bar") {
                Picker(
                    "Metric",
                    selection: Binding(
                        get: { integrations.menuBarMetric },
                        set: selectMenuBarMetric
                    )
                ) {
                    ForEach(integrations.availableMenuBarMetrics) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
            }

            Stepper(
                value: Binding(
                    get: { SafetyBufferPolicy.normalized(safetyBuffer) },
                    set: { safetyBuffer = SafetyBufferPolicy.normalized($0) }
                ),
                in: SafetyBufferPolicy.range,
                step: 1
            ) {
                Text(
                    "Safety buffer: \(Int(SafetyBufferPolicy.normalized(safetyBuffer)))%"
                )
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
                    if monitor.historyDeletionStatus == .pendingSync {
                        Button("Choose Folder…", action: chooseHistoryFolder)
                    }
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

            Section("Analytics history") {
                Text("Codex Limits keeps analytics history on this Mac until you delete it.")
                    .foregroundStyle(.secondary)

                if monitor.historyDeletionStatus == .pendingSync {
                    Label("Deletion pending", systemImage: "exclamationmark.triangle")
                    Text("Make the sync folder available, or choose it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry deletion") {
                        Task { await monitor.retryHistoryDeletion() }
                    }
                    .disabled(monitor.isUpdatingHistory)
                } else if monitor.historyDeletionStatus == .pendingLocal {
                    Label("Deletion pending", systemImage: "exclamationmark.triangle")
                    Text("Codex Limits couldn’t remove local history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry deletion") {
                        Task { await monitor.retryHistoryDeletion() }
                    }
                    .disabled(monitor.isUpdatingHistory)
                } else if monitor.historyDeletionStatus == .complete {
                    Label("Analytics history deleted", systemImage: "checkmark.circle")

                    if monitor.canRebuildAvailableHistory {
                        Button("Rebuild available history") {
                            Task { await monitor.rebuildAvailableHistory() }
                        }
                        .disabled(monitor.isUpdatingHistory)
                        Text("Rebuild uses Codex data that still exists. It may restore only part of your history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Delete analytics history…", role: .destructive) {
                    confirmsHistoryDeletion = true
                }
                .disabled(monitor.isUpdatingHistory)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .task {
            await claudeCode.settingsPresented()
            guard !Task.isCancelled else { return }
            await grok.settingsPresented()
        }
        .onDisappear { grok.settingsDismissed() }
        .alert("Delete Grok integration data?", isPresented: $confirmsGrokDataDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete integration data", role: .destructive) {
                integrations.setEnabled(false, for: .grok)
                integrations.selectGrokExecutable(nil)
                grokExecutableError = nil
                Task { await grok.deleteData() }
            }
        } message: {
            Text("This disables Grok and deletes its usage history saved by Codex Limits. It doesn’t delete Grok Build data or change your subscription.")
        }
        .alert("Set up Claude Code?", isPresented: $confirmsClaudeSetup) {
            Button("Cancel", role: .cancel) {}
            Button("Set up") {
                Task { await claudeCode.setUp() }
            }
        } message: {
            Text(
                "This adds a Codex Limits command to Claude Code’s user status line. Claude Code will run it during activity, and its footer will show usage remaining. Project or managed settings can override it. Usage data is available on eligible Pro and Max accounts."
            )
        }
        .alert(
            "Delete Claude Code integration data?",
            isPresented: $confirmsClaudeDataDeletion
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete integration data", role: .destructive) {
                integrations.setEnabled(false, for: .claudeCode)
                integrations.selectClaudeExecutable(nil)
                claudeExecutableError = nil
                Task { await claudeCode.deleteData() }
            }
        } message: {
            Text(
                "This disables Claude Code and deletes its usage history and setup records saved by Codex Limits. It doesn’t delete Claude Code data."
            )
        }
        .alert("Delete analytics history?", isPresented: $confirmsHistoryDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete analytics history", role: .destructive) {
                Task { await monitor.deleteAnalyticsHistory() }
            }
        } message: {
            Text(
                "This removes all Codex Limits analytics history from this Mac and the selected sync folder, including history from other Macs. It keeps your settings. You may not be able to rebuild all history."
            )
        }
    }

    private var codexReadiness: String {
        if monitor.isRefreshing { return "Checking" }
        if let sourceMessage = monitor.readerSnapshot.sourceMessage {
            return sourceMessage
        }
        return monitor.readerSnapshot.account == nil ? "Set up" : "Ready"
    }

    private var codexNotFound: Bool {
        monitor.readerSnapshot.sourceMessage
            == CodexClientError.cliNotFound.localizedDescription
    }

    private var claudeReadiness: String {
        switch claudeCode.readiness {
        case .disabled:
            ""
        case .checking:
            "Checking"
        case .notFound:
            "Not found"
        case .setUp:
            "Set up"
        case .waitingForData:
            "Waiting for data"
        case .ready:
            "Ready"
        case .conflict:
            "Existing status line"
        case .updateRequired:
            "Update required"
        case .manualCleanupRequired:
            "Remove the Codex Limits command from your Claude Code status line."
        case .failed:
            "Claude Code usage couldn’t be read."
        }
    }

    @ViewBuilder
    private var claudeActions: some View {
        if integrations.isEnabled(.claudeCode) {
            switch claudeCode.readiness {
            case .notFound:
                Button("Locate…", action: locateClaudeExecutable)
                Link(
                    "Install Claude Code",
                    destination: URL(
                        string: "https://code.claude.com/docs/en/setup"
                    )!
                )
                Button("Check again") {
                    Task { await claudeCode.settingsPresented() }
                }
            case .setUp:
                Button("Set up…") {
                    confirmsClaudeSetup = true
                }
            case .waitingForData:
                Text("Usage data is available on eligible Pro and Max accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("It appears after the first response in a session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check for new observation") {
                    Task { await claudeCode.checkForNewObservation() }
                }
            case .ready:
                if let observedAt = claudeCode.snapshot?.observedAt {
                    Text("Last observed \(observedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Check for new observation") {
                    Task { await claudeCode.checkForNewObservation() }
                }
            case .conflict:
                Text("Codex Limits won’t change your existing status line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check again") {
                    Task { await claudeCode.settingsPresented() }
                }
            case .updateRequired:
                Button("Check again") {
                    Task { await claudeCode.settingsPresented() }
                }
            case .failed:
                Button("Check again") {
                    Task { await claudeCode.settingsPresented() }
                }
            case .disabled, .checking, .manualCleanupRequired:
                EmptyView()
            }
        }
        if let claudeExecutableError {
            Text(claudeExecutableError)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if claudeCode.hasStoredData
            || integrations.claudeExecutablePath != nil {
            Button("Delete Claude Code data…", role: .destructive) {
                confirmsClaudeDataDeletion = true
            }
        }
    }

    private func setCodexEnabled(_ enabled: Bool) {
        if !enabled { codexExecutableError = nil }
        integrations.setEnabled(enabled, for: .codex)
        let codexSelected = integrations.menuBarMetric
            == .codexWeeklyUsageRemaining
        Task {
            await monitor.setMenuBarSourceActive(codexSelected)
            await monitor.setEnabled(enabled)
        }
    }

    private func setClaudeEnabled(_ enabled: Bool) {
        if !enabled { claudeExecutableError = nil }
        integrations.setEnabled(enabled, for: .claudeCode)
        let claudeSelected = integrations.menuBarMetric
            == .claudeSevenDayUsageRemaining
        Task {
            await claudeCode.setMenuBarSourceActive(claudeSelected)
            await claudeCode.setEnabled(enabled)
        }
    }

    private func selectMenuBarMetric(_ metric: MenuBarMetric) {
        integrations.selectMenuBarMetric(metric)
        let codexSelected = integrations.menuBarMetric
            == .codexWeeklyUsageRemaining
        let claudeSelected = integrations.menuBarMetric
            == .claudeSevenDayUsageRemaining
        let grokSelected = integrations.menuBarMetric == .grokCurrentPeriodUsageRemaining
        Task {
            // Stop the previous source before a selected source can await a read.
            if !codexSelected { await monitor.setMenuBarSourceActive(false) }
            guard integrations.menuBarMetric == metric else { return }
            if !claudeSelected { await claudeCode.setMenuBarSourceActive(false) }
            guard integrations.menuBarMetric == metric else { return }
            if !grokSelected { await grok.setMenuBarSourceActive(false) }
            guard integrations.menuBarMetric == metric else { return }
            if codexSelected { await monitor.setMenuBarSourceActive(true) }
            if claudeSelected { await claudeCode.setMenuBarSourceActive(true) }
            if grokSelected { await grok.setMenuBarSourceActive(true) }
        }
    }

    private func setGrokEnabled(_ enabled: Bool) {
        if !enabled { grokExecutableError = nil }
        integrations.setEnabled(enabled, for: .grok)
        let selected = integrations.menuBarMetric == .grokCurrentPeriodUsageRemaining
        Task {
            await grok.setMenuBarSourceActive(selected)
            await grok.setEnabled(enabled)
        }
    }

    private func locateGrokExecutable() {
        guard let url = chooseExecutable(message: "Choose the Grok Build executable.") else { return }
        Task {
            if await grok.selectExecutable(url) {
                integrations.selectGrokExecutable(url)
                grokExecutableError = nil
            } else {
                grokExecutableError = "Choose a regular executable file."
            }
        }
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

    private func locateClaudeExecutable() {
        guard let url = chooseExecutable(
            message: "Choose the Claude Code executable."
        ) else { return }
        Task {
            if await claudeCode.selectExecutable(url) {
                integrations.selectClaudeExecutable(url)
                claudeExecutableError = nil
            } else {
                claudeExecutableError = "Choose a regular executable file."
            }
        }
    }

    private func locateCodexExecutable() {
        guard let url = chooseExecutable(
            message: "Choose the Codex executable."
        ) else { return }
        guard CodexClient.selectExecutable(url) else {
            codexExecutableError = "Choose a regular executable file."
            return
        }
        integrations.selectCodexExecutable(url)
        codexExecutableError = nil
        Task { await monitor.refresh() }
    }

    private func chooseExecutable(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
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
