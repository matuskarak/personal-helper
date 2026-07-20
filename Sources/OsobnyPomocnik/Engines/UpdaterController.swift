import Sparkle

/// Thin wrapper around Sparkle's standard updater — background checks (interval set
/// via SUScheduledCheckInterval in Info.plist) plus a manual "Skontrolovať aktualizácie…" trigger.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
