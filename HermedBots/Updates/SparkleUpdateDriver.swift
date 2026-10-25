import Sparkle
import UpdateCheck

final class SparkleUpdateDriver: UpdateDriver {
    private var controller: SPUStandardUpdaterController?

    func attach(_ controller: SPUStandardUpdaterController) {
        self.controller = controller
    }

    var canStartCheck: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func startCheck() -> Bool {
        controller?.checkForUpdates(nil)
        return true
    }
}

final class SparkleCycleDelegate: NSObject, SPUUpdaterDelegate {
    private let updates: UpdateCheck

    init(updates: UpdateCheck) {
        self.updates = updates
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        Task { @MainActor in
            self.updates.noteSessionEnded()
        }
    }
}
