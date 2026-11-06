public struct AboutVersionSnapshot: Equatable, Sendable {
    public static let unknownLabel = "inconnue"
    public static let appVersionTitle = "Version de l'app"
    public static let hermesCLITitle = "Hermes CLI"
    public static let macOSTitle = "macOS"

    public var appVersion: String?
    public var hermesCLI: String?
    public var macOS: String?

    public init(
        appVersion: String? = nil,
        hermesCLI: String? = nil,
        macOS: String? = nil
    ) {
        self.appVersion = appVersion
        self.hermesCLI = hermesCLI
        self.macOS = macOS
    }

    public static func display(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unknownLabel : trimmed
    }

    public static func macOSString(major: Int, minor: Int, patch: Int) -> String {
        "\(major).\(minor).\(patch)"
    }

    public var displayedAppVersion: String { Self.display(appVersion) }
    public var displayedHermesCLI: String { Self.display(hermesCLI) }
    public var displayedMacOS: String { Self.display(macOS) }

    public var versionRows: [(title: String, value: String)] {
        [
            (Self.appVersionTitle, displayedAppVersion),
            (Self.hermesCLITitle, displayedHermesCLI),
            (Self.macOSTitle, displayedMacOS),
        ]
    }
}
