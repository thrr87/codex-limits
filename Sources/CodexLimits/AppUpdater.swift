import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var availableVersion: String?

    private var started = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    func start() {
        guard !started else { return }
        started = true

        controller.startUpdater()
        controller.updater.updateCheckInterval = 6 * 60 * 60
        controller.updater.checkForUpdatesInBackground()
    }

    func showAvailableUpdate() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
extension AppUpdater: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {}
}
