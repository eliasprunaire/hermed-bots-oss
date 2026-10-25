import Sparkle
import UpdateCheck

final class SparkleUpdateDriver: UpdateDriver {
    private var controller: SPUStandardUpdaterController?

    func attach(_ controller: SPUStandardUpdaterController) {
        onMain {
            self.controller = controller
            Self.imposeOnDemandPolicy(controller.updater)
        }
    }

    static func imposeOnDemandPolicy(_ updater: SPUUpdater) {
        let stored = UpdatePolicy(
            automaticallyChecks: updater.automaticallyChecksForUpdates,
            automaticallyDownloads: updater.automaticallyDownloadsUpdates
        )
        let policy = UpdatePolicy.imposed(on: stored)
        updater.automaticallyChecksForUpdates = policy.automaticallyChecks
        updater.automaticallyDownloadsUpdates = policy.automaticallyDownloads
    }

    var canStartCheck: Bool {
        onMain { controller?.updater.canCheckForUpdates ?? false }
    }

    func startCheck() -> Bool {
        onMain {
            controller?.checkForUpdates(nil)
            return true
        }
    }

    private func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
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
