import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @AppStorage(UsageMonitor.safetyBufferKey) private var safetyBuffer = 3.0
    @AppStorage(LoginItem.preferenceKey) private var launchAtLogin = true
    @State private var loginItemError: String?
    @State private var confirmsHistoryDeletion = false

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
        .frame(width: 380)
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
