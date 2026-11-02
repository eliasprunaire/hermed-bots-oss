public struct AboutVersionSnapshot: Equatable, Sendable {
    public static let unknownLabel = "inconnue"
    public static let appVersionTitle = "Version de l'app"
    public static let appBuildTitle = "Build"
    public static let hermesCLITitle = "Hermes CLI"
    public static let macOSTitle = "macOS"
    public static let updateChannelTitle = "Canal de mise à jour"

    public var appVersion: String?
    public var appBuild: String?
    public var hermesCLI: String?
    public var macOS: String?
    public var updateChannel: String?

    public init(
        appVersion: String? = nil,
        appBuild: String? = nil,
        hermesCLI: String? = nil,
        macOS: String? = nil,
        updateChannel: String? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.hermesCLI = hermesCLI
        self.macOS = macOS
        self.updateChannel = updateChannel
    }

    public static func display(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unknownLabel : trimmed
    }

    public static func macOSString(major: Int, minor: Int, patch: Int) -> String {
        "\(major).\(minor).\(patch)"
    }

    public var displayedAppVersion: String { Self.display(appVersion) }
    public var displayedAppBuild: String { Self.display(appBuild) }
    public var displayedHermesCLI: String { Self.display(hermesCLI) }
    public var displayedMacOS: String { Self.display(macOS) }
    public var displayedUpdateChannel: String { Self.display(updateChannel) }

    public var versionRows: [(title: String, value: String)] {
        [
            (Self.appVersionTitle, displayedAppVersion),
            (Self.appBuildTitle, displayedAppBuild),
            (Self.hermesCLITitle, displayedHermesCLI),
            (Self.macOSTitle, displayedMacOS),
            (Self.updateChannelTitle, displayedUpdateChannel),
        ]
    }
}
