import Foundation

enum IntegrationID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claudeCode
    case grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .grok: "Grok"
        }
    }
}

enum MenuBarMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case codexWeeklyUsageRemaining
    case claudeSevenDayUsageRemaining
    case grokCurrentPeriodUsageRemaining

    var id: String { rawValue }

    var integration: IntegrationID? {
        switch self {
        case .none: nil
        case .codexWeeklyUsageRemaining: .codex
        case .claudeSevenDayUsageRemaining: .claudeCode
        case .grokCurrentPeriodUsageRemaining: .grok
        }
    }

    var displayName: String {
        switch self {
        case .none: "None"
        case .codexWeeklyUsageRemaining:
            "Codex — Weekly usage remaining"
        case .claudeSevenDayUsageRemaining:
            "Claude Code — 7-day usage remaining"
        case .grokCurrentPeriodUsageRemaining:
            "Grok — Current-period usage remaining"
        }
    }
}

@MainActor
final class IntegrationPreferences: ObservableObject {
    static let persistenceKey = "integrationPreferences"

    @Published private(set) var enabledIntegrations: Set<IntegrationID>
    @Published private(set) var menuBarMetric: MenuBarMetric
    @Published private(set) var codexExecutablePath: String?
    @Published private(set) var claudeExecutablePath: String?
    @Published private(set) var grokExecutablePath: String?

    private struct Stored: Codable {
        let version: Int
        let enabledIntegrationIDs: [String]
        let menuBarMetricID: String
        let codexExecutablePath: String?
        let claudeExecutablePath: String?
        let grokExecutablePath: String?
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.persistenceKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.version == 1 {
            enabledIntegrations = Set(
                stored.enabledIntegrationIDs.compactMap(IntegrationID.init)
            )
            menuBarMetric = MenuBarMetric(rawValue: stored.menuBarMetricID)
                ?? .none
            if let integration = menuBarMetric.integration,
               !enabledIntegrations.contains(integration) {
                menuBarMetric = .none
            }
            codexExecutablePath = stored.codexExecutablePath
            claudeExecutablePath = stored.claudeExecutablePath
            grokExecutablePath = stored.grokExecutablePath
        } else {
            enabledIntegrations = [.codex]
            menuBarMetric = .codexWeeklyUsageRemaining
            codexExecutablePath = nil
            claudeExecutablePath = nil
            grokExecutablePath = nil
        }
    }

    func isEnabled(_ integration: IntegrationID) -> Bool {
        enabledIntegrations.contains(integration)
    }

    func setEnabled(_ enabled: Bool, for integration: IntegrationID) {
        if enabled {
            enabledIntegrations.insert(integration)
        } else {
            enabledIntegrations.remove(integration)
            if menuBarMetric.integration == integration {
                menuBarMetric = .none
            }
        }
        persist()
    }

    func selectMenuBarMetric(_ metric: MenuBarMetric) {
        guard metric.integration.map(enabledIntegrations.contains) ?? true else {
            return
        }
        menuBarMetric = metric
        persist()
    }

    var availableMenuBarMetrics: [MenuBarMetric] {
        MenuBarMetric.allCases.filter {
            $0.integration.map(enabledIntegrations.contains) ?? true
        }
    }

    var claudeExecutableURL: URL? {
        claudeExecutablePath.map(URL.init(fileURLWithPath:))
    }

    var codexExecutableURL: URL? {
        codexExecutablePath.map(URL.init(fileURLWithPath:))
    }

    var grokExecutableURL: URL? {
        grokExecutablePath.map(URL.init(fileURLWithPath:))
    }

    func selectCodexExecutable(_ url: URL?) {
        codexExecutablePath = url?.standardizedFileURL.path
        persist()
    }

    func selectClaudeExecutable(_ url: URL?) {
        claudeExecutablePath = url?.standardizedFileURL.path
        persist()
    }

    func selectGrokExecutable(_ url: URL?) {
        grokExecutablePath = url?.standardizedFileURL.path
        persist()
    }

    private func persist() {
        let stored = Stored(
            version: 1,
            enabledIntegrationIDs: enabledIntegrations
                .map(\.rawValue)
                .sorted(),
            menuBarMetricID: menuBarMetric.rawValue,
            codexExecutablePath: codexExecutablePath,
            claudeExecutablePath: claudeExecutablePath,
            grokExecutablePath: grokExecutablePath
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.persistenceKey)
        }
    }
}
