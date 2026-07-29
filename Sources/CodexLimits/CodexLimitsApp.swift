import SwiftUI

@main
struct CodexLimitsApp: App {
    @StateObject private var monitor: UsageMonitor
    #if CODEX_LIMITS_QA
    @StateObject private var assistedInsights: CodexAssistedInsightStore
    #endif
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
        _assistedInsights = StateObject(
            wrappedValue: CodexAssistedInsightStore(
                service: QACodexAssistedService(),
                sourceReader: QACodexSourceContentReader()
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
                defaults: analyticsDefaults,
                assistedInsights: assistedInsights
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
