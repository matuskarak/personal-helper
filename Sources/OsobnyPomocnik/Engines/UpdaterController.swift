import Observation
import Sparkle

/// Thin wrapper around Sparkle's standard updater — background checks (interval set
/// via SUScheduledCheckInterval in Info.plist) plus a manual "Skontrolovať aktualizácie…" trigger.
/// Remembers a found update so the menu keeps offering it after the Sparkle alert was
/// dismissed ("Pripomenúť neskôr") or opened behind other windows (no Dock icon).
@MainActor @Observable
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    /// Version string of an update Sparkle found and the user hasn't installed or skipped.
    private(set) var availableVersion: String?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { availableVersion = nil }
    }
}
