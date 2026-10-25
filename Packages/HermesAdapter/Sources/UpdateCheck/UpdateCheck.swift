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
}

public final class NullUpdateDriver: UpdateDriver {
    public init() {}
    public var canStartCheck: Bool { true }
    public func startCheck() -> Bool { false }
}

public final class UpdateCheck {
    public private(set) var isChecking = false
    public var onChange: (() -> Void)?
    private let driver: any UpdateDriver

    public init(driver: any UpdateDriver) {
        self.driver = driver
    }

    public var canCheck: Bool { driver.canStartCheck && !isChecking }

    public func checkForUpdates() {
        guard canCheck else { return }
        isChecking = true
        onChange?()
        if !driver.startCheck() {
            noteSessionEnded()
        }
    }

    public func noteSessionEnded() {
        guard isChecking else { return }
        isChecking = false
        onChange?()
    }
}
