import SwiftUI

@main
struct CodexLimitsApp: App {
    @StateObject private var monitor: UsageMonitor
    private let analyticsDefaults: UserDefaults

    init() {
        #if CODEX_LIMITS_QA
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent(
                "com.github.thrr87.CodexLimits.QA",
                isDirectory: true
            ) ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "com.github.thrr87.CodexLimits.QA",
            isDirectory: true
        )
        let defaults = UserDefaults(
            suiteName: "com.github.thrr87.CodexLimits.QA.defaults"
        ) ?? .standard
        analyticsDefaults = defaults
        let collector = LocalActivityCollector(
            stateDirectory: base.appendingPathComponent(
                "local-activity",
                isDirectory: true
            ),
            projectionSource: ReadOnlyThreadProjectionSource { request in
                try await CodexClient.shared.threadProjectionResponse(
                    for: request
                )
            },
            installedCLIVersion: {
                try? await CodexClient.shared.installedCLIVersion()
            }
        )
        _monitor = StateObject(
            wrappedValue: UsageMonitor(
                defaults: defaults,
                historyDirectory: base.appendingPathComponent(
                    "History",
                    isDirectory: true
                ),
                localActivityCollector: collector
            )
        )
        #else
        LoginItem.enableByDefault()
        analyticsDefaults = .standard
        _monitor = StateObject(wrappedValue: UsageMonitor())
        #endif
    }

    @SceneBuilder
    var body: some Scene {
        #if CODEX_LIMITS_QA
        Window("Codex Limits QA", id: "qa-window") {
            MenuContentView(
                monitor: monitor,
                defaults: analyticsDefaults
            )
        }
        .defaultPosition(.center)
        #else
        MenuBarExtra {
            MenuContentView(
                monitor: monitor,
                defaults: analyticsDefaults
            )
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                Text(monitor.readerSnapshot.menuBarText)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
        #endif

        Settings {
            SettingsView(monitor: monitor)
        }
    }
}
