public struct UpdatePolicy: Equatable, Sendable {
    public var automaticallyChecks: Bool
    public var automaticallyDownloads: Bool

    public init(automaticallyChecks: Bool, automaticallyDownloads: Bool) {
        self.automaticallyChecks = automaticallyChecks
        self.automaticallyDownloads = automaticallyDownloads
    }

    public static let onDemand = UpdatePolicy(automaticallyChecks: false, automaticallyDownloads: false)

    public static func imposed(on stored: UpdatePolicy) -> UpdatePolicy {
        .onDemand
    }
}

public protocol UpdateDriver: AnyObject {
    var canStartCheck: Bool { get }
    func startCheck() -> Bool
    func startInstall() -> Bool
}

public final class NullUpdateDriver: UpdateDriver {
    public init() {}
    public var canStartCheck: Bool { true }
    public func startCheck() -> Bool { false }
    public func startInstall() -> Bool { false }
}

public enum UpdateCheckCopy {
    public static let upToDate = "Hermed Bots est à jour."
    public static let checking = "Recherche de mises à jour…"
    public static let failed = "La recherche a échoué. Vérifie la connexion, puis réessaie."

    public static func available(_ version: String) -> String {
        "Mise à jour disponible : \(version)"
    }
}

public enum UpdateCheckState: Equatable, Sendable {
    case upToDate
    case checking
    case available(version: String)
    case error

    public var showsInstall: Bool {
        if case .available = self { return true }
        return false
    }

    public var statusText: String {
        switch self {
        case .upToDate: UpdateCheckCopy.upToDate
        case .checking: UpdateCheckCopy.checking
        case .available(let version): UpdateCheckCopy.available(version)
        case .error: UpdateCheckCopy.failed
        }
    }
}

public final class UpdateCheck {
    public private(set) var state: UpdateCheckState = .upToDate
    public var onChange: (() -> Void)?
    private let driver: any UpdateDriver
    private var settled: UpdateCheckState = .upToDate

    public init(driver: any UpdateDriver) {
        self.driver = driver
    }

    public var isChecking: Bool { state == .checking }

    public var canCheck: Bool { driver.canStartCheck && !isChecking }

    public func checkForUpdates() {
        guard canCheck else { return }
        state = .checking
        onChange?()
        if !driver.startCheck() {
            state = settled
            onChange?()
        }
    }

    public func installUpdate() {
        guard state.showsInstall else { return }
        _ = driver.startInstall()
    }

    public func noteAvailable(version: String) {
        settled = .available(version: version)
        publishSettledIfIdle()
    }

    public func noteUpToDate() {
        settled = .upToDate
        publishSettledIfIdle()
    }

    public func noteFailed() {
        settled = .error
        publishSettledIfIdle()
    }

    public func noteSessionEnded() {
        guard isChecking else { return }
        state = settled
        onChange?()
    }

    private func publishSettledIfIdle() {
        guard !isChecking else { return }
        state = settled
        onChange?()
    }
}
