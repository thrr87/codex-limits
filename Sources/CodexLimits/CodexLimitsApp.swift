import SwiftUI

@main
struct CodexLimitsApp: App {
    @StateObject private var monitor: UsageMonitor
    @StateObject private var integrations: IntegrationPreferences
    @StateObject private var claudeCode: ClaudeCodeIntegrationStore
    @StateObject private var grok: GrokIntegrationStore
    #if CODEX_LIMITS_QA
    @StateObject private var assistedInsights: CodexAssistedInsightStore
    #endif
    private let analyticsDefaults: UserDefaults

    init() {
        #if CODEX_LIMITS_QA
        let bundleID = Bundle.main.bundleIdentifier ?? "com.github.thrr87.CodexLimits.QA"
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent(
                bundleID,
                isDirectory: true
            ) ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            bundleID,
            isDirectory: true
        )
        let defaults = UserDefaults(
            suiteName: bundleID + ".defaults"
        ) ?? .standard
        let integrations = IntegrationPreferences(defaults: defaults)
        _ = CodexClient.selectExecutable(integrations.codexExecutableURL)
        let integrationWorkCoordinator = IntegrationWorkCoordinator()
        let claudePaths = ClaudeCodeIntegrationPaths.isolatedQA(
            base: base,
            bundleURL: Bundle.main.bundleURL
        )
        _integrations = StateObject(wrappedValue: integrations)
        _grok = StateObject(wrappedValue: GrokIntegrationStore(
            isEnabled: integrations.isEnabled(.grok),
            menuBarSourceActive: integrations.menuBarMetric == .grokCurrentPeriodUsageRemaining,
            selectedExecutableURL: integrations.grokExecutableURL,
            cacheURL: base.appendingPathComponent("Integrations/Grok/snapshot.json"),
            integrationWorkCoordinator: integrationWorkCoordinator
        ))
        _claudeCode = StateObject(
            wrappedValue: ClaudeCodeIntegrationStore(
                isEnabled: integrations.isEnabled(.claudeCode),
                menuBarSourceActive: integrations.menuBarMetric
                    == .claudeSevenDayUsageRemaining,
                service: ClaudeCodeSetupService(
                    paths: claudePaths,
                    selectedExecutableURL: integrations.claudeExecutableURL
                ),
                integrationWorkCoordinator: integrationWorkCoordinator
            )
        )
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
                isEnabled: integrations.isEnabled(.codex),
                menuBarSourceActive: integrations.menuBarMetric
                    == .codexWeeklyUsageRemaining,
                localActivityCollector: collector,
                integrationWorkCoordinator: integrationWorkCoordinator
            )
        )
        _assistedInsights = StateObject(
            wrappedValue: CodexAssistedInsightStore(
                service: QACodexAssistedService(),
                sourceReader: QACodexSourceContentReader()
            )
        )
        #else
        LoginItem.enableByDefault()
        analyticsDefaults = .standard
        let integrations = IntegrationPreferences()
        _ = CodexClient.selectExecutable(integrations.codexExecutableURL)
        let integrationWorkCoordinator = IntegrationWorkCoordinator()
        _integrations = StateObject(wrappedValue: integrations)
        _grok = StateObject(wrappedValue: GrokIntegrationStore(
            isEnabled: integrations.isEnabled(.grok),
            menuBarSourceActive: integrations.menuBarMetric == .grokCurrentPeriodUsageRemaining,
            selectedExecutableURL: integrations.grokExecutableURL,
            integrationWorkCoordinator: integrationWorkCoordinator
        ))
        _claudeCode = StateObject(
            wrappedValue: ClaudeCodeIntegrationStore(
                isEnabled: integrations.isEnabled(.claudeCode),
                menuBarSourceActive: integrations.menuBarMetric
                    == .claudeSevenDayUsageRemaining,
                service: ClaudeCodeSetupService(
                    selectedExecutableURL: integrations.claudeExecutableURL
                ),
                integrationWorkCoordinator: integrationWorkCoordinator
            )
        )
        _monitor = StateObject(
            wrappedValue: UsageMonitor(
                isEnabled: integrations.isEnabled(.codex),
                menuBarSourceActive: integrations.menuBarMetric
                    == .codexWeeklyUsageRemaining,
                integrationWorkCoordinator: integrationWorkCoordinator
            )
        )
        #endif
    }

    @SceneBuilder
    var body: some Scene {
        #if CODEX_LIMITS_QA
        Window("Codex Limits QA", id: "qa-window") {
            MenuContentView(
                monitor: monitor,
                integrations: integrations,
                claudeCode: claudeCode,
                grok: grok,
                defaults: analyticsDefaults,
                assistedInsights: assistedInsights
            )
        }
        .defaultPosition(.center)
        #else
        MenuBarExtra {
            MenuContentView(
                monitor: monitor,
                integrations: integrations,
                claudeCode: claudeCode,
                grok: grok,
                defaults: analyticsDefaults
            )
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                if integrations.menuBarMetric != .none {
                    Text(menuBarText)
                        .monospacedDigit()
                    if selectedMenuMetricIsStale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityLabel(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
        #endif

        Settings {
            SettingsView(
                monitor: monitor,
                integrations: integrations,
                claudeCode: claudeCode,
                grok: grok
            )
            .defaultAppStorage(analyticsDefaults)
        }
    }

    private var menuBarText: String {
        switch integrations.menuBarMetric {
        case .none:
            ""
        case .codexWeeklyUsageRemaining:
            monitor.readerSnapshot.menuBarText
        case .claudeSevenDayUsageRemaining:
            claudeCode.snapshot?.sevenDayMenuBarText(
                now: claudeCode.displayNow
            ) ?? "—"
        case .grokCurrentPeriodUsageRemaining:
            grok.menuBarText
        }
    }

    private var menuBarAccessibilityLabel: String {
        switch integrations.menuBarMetric {
        case .none:
            return "Codex Limits"
        case .codexWeeklyUsageRemaining:
            let value = monitor.readerSnapshot.weeklyUsageRemaining.map {
                $0.window.remainingPercent.formatted(
                    .number.precision(.fractionLength(0 ... 2))
                ) + " percent remaining"
            } ?? "unavailable"
            return "\(integrations.menuBarMetric.displayName), \(value), \(monitor.readerSnapshot.freshness.rawValue)"
        case .claudeSevenDayUsageRemaining:
            let freshness = claudeCode.displayFreshness.map {
                switch $0 {
                case .fresh: "fresh"
                case .stale: "stale"
                case .expired: "new usage observation needed"
                }
            } ?? "unavailable"
            let value = claudeCode.snapshot?.sevenDay.flatMap {
                $0.resetsAt > claudeCode.displayNow ? $0 : nil
            }.map {
                $0.remainingPercent.formatted(
                    .number.precision(.fractionLength(0 ... 2))
                ) + " percent remaining"
            } ?? "unavailable"
            return "\(integrations.menuBarMetric.displayName), \(value), \(freshness)"
        case .grokCurrentPeriodUsageRemaining:
            let value = grok.currentSnapshot.flatMap { snapshot in
                snapshot.remainingPercent.map {
                    $0.formatted(.number.precision(.fractionLength(0 ... 2)))
                        + " percent remaining, \(snapshot.period.rawValue)"
                }
            } ?? "unavailable"
            let freshness = grok.currentSnapshot?.remainingPercent == nil ? "unavailable" : (grok.isStale ? "stale" : "fresh")
            return "\(integrations.menuBarMetric.displayName), \(value), \(freshness)"
        }
    }

    private var selectedMenuMetricIsStale: Bool {
        switch integrations.menuBarMetric {
        case .codexWeeklyUsageRemaining:
            return monitor.readerSnapshot.freshness == .stale
        case .claudeSevenDayUsageRemaining:
            return claudeCode.displayFreshness == .stale
        case .grokCurrentPeriodUsageRemaining:
            return grok.isStale
        case .none:
            return false
        }
    }
}

#if CODEX_LIMITS_QA
private actor QACodexAssistedService: CodexAssistedInsightServicing {
    private let medium = CodexAssistedModelProfile(
        id: "gpt-5.6-luna",
        model: "gpt-5.6-luna",
        reasoningEffort: "medium"
    )

    func eligibleProfile() async throws -> CodexAssistedModelProfile? {
        medium
    }

    func eligibleStrongerProfile() async throws
        -> CodexAssistedModelProfile? {
        CodexAssistedModelProfile(
            id: medium.id,
            model: medium.model,
            reasoningEffort: "high"
        )
    }

    func analyze(
        payload _: CodexMetadataAnalysisPayload,
        profile _: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome {
        .failed(CodexAnalyticsOverhead(
            durationSeconds: 0,
            accountMovement: nil
        ))
    }

    func analyzeSource(
        payload _: CodexSourceAnalysisPayload,
        metadata _: CodexMetadataAnalysisPayload,
        profile _: CodexAssistedModelProfile
    ) async -> CodexAssistedAnalysisOutcome {
        .failed(CodexAnalyticsOverhead(
            durationSeconds: 0,
            accountMovement: nil
        ))
    }

    func cancelAnalysis() async {}
}

private actor QACodexSourceContentReader: CodexSourceContentReading {
    func prepare(
        selection: CodexSourceSelection
    ) async throws -> CodexSourceContentDraft {
        CodexSourceContentDraft(
            selection: selection,
            values: [
                .prompts: ["Build a bounded analytics view"],
                .responses: ["The selected work is ready for review"],
                .code: ["struct UsageView: View"],
                .paths: ["/example/UsageView.swift"],
                .commands: ["swift test"],
                .toolOutput: ["All checks passed"]
            ]
        )
    }
}
#endif
