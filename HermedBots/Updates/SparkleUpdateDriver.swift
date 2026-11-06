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

    func startInstall() -> Bool {
        startCheck()
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

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updates.noteAvailable(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updates.noteUpToDate()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error, !Self.isIgnorableFinishError(error) {
            updates.noteFailed()
        }
        updates.noteSessionEnded()
    }

    private static func isIgnorableFinishError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return true }
        guard ns.domain == SUSparkleErrorDomain else { return false }
        switch ns.code {
        case Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue):
            return true
        default:
            return false
        }
    }
}
