import Sparkle

@MainActor final class UpdaterController {
    static let shared = UpdaterController()

    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
