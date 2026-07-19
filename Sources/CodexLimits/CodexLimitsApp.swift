import SwiftUI

@main
struct CodexLimitsApp: App {
    @StateObject private var monitor: UsageMonitor

    init() {
        LoginItem.enableByDefault()
        _monitor = StateObject(wrappedValue: UsageMonitor())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                Text(monitor.menuBarText)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(monitor: monitor)
        }
    }
}
