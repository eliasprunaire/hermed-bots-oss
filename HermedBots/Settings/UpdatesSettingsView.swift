import AppSettings
import SwiftUI

struct UpdatesSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            LabeledContent(AboutVersionSnapshot.appVersionTitle) {
                Text(verbatim: snapshot.displayedAppVersion).accessibilityID(.aboutAppVersion)
            }
            LabeledContent(AboutVersionSnapshot.appBuildTitle) {
                Text(verbatim: snapshot.displayedAppBuild).accessibilityID(.aboutAppBuild)
            }
            LabeledContent(AboutVersionSnapshot.hermesCLITitle) {
                Text(verbatim: snapshot.displayedHermesCLI).accessibilityID(.aboutHermes)
            }
            LabeledContent(AboutVersionSnapshot.macOSTitle) {
                Text(verbatim: snapshot.displayedMacOS).accessibilityID(.aboutMacOS)
            }
            LabeledContent(AboutVersionSnapshot.updateChannelTitle) {
                Text(verbatim: snapshot.displayedUpdateChannel).accessibilityID(.aboutChannel)
            }
            Button(SettingsCopy.checkForUpdates) { model.checkForUpdates() }
                .disabled(!model.canCheckForUpdates)
                .accessibilityID(.updatesCheck)
        }
        .formStyle(.grouped)
    }

    private var snapshot: AboutVersionSnapshot {
        AboutVersionSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            hermesCLI: hermesCLIValue,
            macOS: AboutVersionSnapshot.macOSString(
                major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                minor: ProcessInfo.processInfo.operatingSystemVersion.minorVersion,
                patch: ProcessInfo.processInfo.operatingSystemVersion.patchVersion
            ),
            updateChannel: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }

    private var hermesCLIValue: String? {
        switch model.version {
        case .loading: "…"
        case .known(let version): version
        case .unknown: nil
        }
    }
}
