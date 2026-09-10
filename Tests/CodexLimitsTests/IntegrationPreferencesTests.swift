import XCTest
@testable import CodexLimits

@MainActor
final class IntegrationPreferencesTests: XCTestCase {
    func testExistingInstallDefaultsToCodexAndItsWeeklyMenuMetric() {
        let preferences = IntegrationPreferences(defaults: defaults())

        XCTAssertEqual(preferences.enabledIntegrations, [.codex])
        XCTAssertEqual(
            preferences.menuBarMetric,
            .codexWeeklyUsageRemaining
        )
        XCTAssertEqual(
            preferences.availableMenuBarMetrics,
            [.none, .codexWeeklyUsageRemaining]
        )
    }

    func testDisablingTheSelectedIntegrationSelectsNoneAndPersists() {
        let defaults = defaults()
        let preferences = IntegrationPreferences(defaults: defaults)

        preferences.setEnabled(false, for: .codex)
        let restored = IntegrationPreferences(defaults: defaults)

        XCTAssertTrue(restored.enabledIntegrations.isEmpty)
        XCTAssertEqual(restored.menuBarMetric, .none)
        XCTAssertEqual(restored.availableMenuBarMetrics, [.none])
    }

    func testMenuMetricRequiresItsIntegrationToBeEnabled() {
        let preferences = IntegrationPreferences(defaults: defaults())

        preferences.selectMenuBarMetric(.claudeSevenDayUsageRemaining)
        XCTAssertEqual(
            preferences.menuBarMetric,
            .codexWeeklyUsageRemaining
        )

        preferences.setEnabled(true, for: .claudeCode)
        preferences.selectMenuBarMetric(.claudeSevenDayUsageRemaining)
        XCTAssertEqual(
            preferences.menuBarMetric,
            .claudeSevenDayUsageRemaining
        )
    }

    func testDeferredIntegrationCannotReturnFromStoredPreferences() {
        let defaults = defaults()
        defaults.set(
            Data(
                """
                {"version":1,"enabledIntegrationIDs":["openCode"],"menuBarMetricID":"openCodeSevenDayLocalTokens"}
                """.utf8
            ),
            forKey: IntegrationPreferences.persistenceKey
        )

        let preferences = IntegrationPreferences(defaults: defaults)

        XCTAssertTrue(preferences.enabledIntegrations.isEmpty)
        XCTAssertEqual(preferences.menuBarMetric, .none)
        XCTAssertEqual(preferences.availableMenuBarMetrics, [.none])
    }

    func testExecutableSelectionsPersistAndCanBeDeleted() {
        let defaults = defaults()
        let preferences = IntegrationPreferences(defaults: defaults)
        let codex = URL(fileURLWithPath: "/custom/bin/codex")
        let claude = URL(fileURLWithPath: "/custom/bin/claude")
        let grok = URL(fileURLWithPath: "/custom/bin/grok")

        preferences.selectCodexExecutable(codex)
        preferences.selectClaudeExecutable(claude)
        preferences.selectGrokExecutable(grok)
        preferences.setEnabled(true, for: .grok)
        preferences.selectMenuBarMetric(.grokCurrentPeriodUsageRemaining)
        var restored = IntegrationPreferences(defaults: defaults)
        XCTAssertEqual(restored.codexExecutableURL, codex)
        XCTAssertEqual(restored.claudeExecutableURL, claude)
        XCTAssertEqual(restored.grokExecutableURL, grok)
        XCTAssertEqual(restored.menuBarMetric, .grokCurrentPeriodUsageRemaining)

        preferences.selectCodexExecutable(nil)
        preferences.selectClaudeExecutable(nil)
        preferences.selectGrokExecutable(nil)
        preferences.setEnabled(false, for: .grok)
        restored = IntegrationPreferences(defaults: defaults)
        XCTAssertNil(restored.codexExecutableURL)
        XCTAssertNil(restored.claudeExecutableURL)
        XCTAssertNil(restored.grokExecutableURL)
        XCTAssertEqual(restored.menuBarMetric, .none)
    }

    func testWorkCoordinatorSerializesAndPrioritizesExplicitWork() async {
        let coordinator = IntegrationWorkCoordinator()
        let probe = IntegrationWorkProbe()
        let first = Task {
            await coordinator.run(priority: .automatic) {
                await probe.begin("automatic")
                try? await Task.sleep(for: .milliseconds(80))
                await probe.end()
            }
        }
        while await probe.startedCount == 0 {
            await Task.yield()
        }
        let settings = Task {
            await coordinator.run(priority: .settings) {
                await probe.begin("settings")
                await probe.end()
            }
        }
        let explicit = Task {
            await coordinator.run(priority: .explicit) {
                await probe.begin("explicit")
                await probe.end()
            }
        }

        await first.value
        await settings.value
        await explicit.value
        let result = await probe.result
        XCTAssertEqual(result.order, ["automatic", "explicit", "settings"])
        XCTAssertEqual(result.maximumActive, 1)
    }

    private func defaults() -> UserDefaults {
        let suite = "IntegrationPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private actor IntegrationWorkProbe {
    private var active = 0
    private var maximumActive = 0
    private var order: [String] = []

    var startedCount: Int { order.count }
    var result: (order: [String], maximumActive: Int) {
        (order, maximumActive)
    }

    func begin(_ name: String) {
        active += 1
        maximumActive = max(maximumActive, active)
        order.append(name)
    }

    func end() {
        active -= 1
    }
}
