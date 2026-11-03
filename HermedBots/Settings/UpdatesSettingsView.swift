import AppSettings
import SwiftUI
import UpdateCheck

struct UpdatesSettingsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                LabeledContent(AboutVersionSnapshot.appVersionTitle) {
                    Text(verbatim: snapshot.displayedAppVersion).accessibilityID(.aboutAppVersion)
                }
                LabeledContent(AboutVersionSnapshot.hermesCLITitle) {
                    Text(verbatim: snapshot.displayedHermesCLI).accessibilityID(.aboutHermes)
                }
                LabeledContent(AboutVersionSnapshot.macOSTitle) {
                    Text(verbatim: snapshot.displayedMacOS).accessibilityID(.aboutMacOS)
                }
                HStack {
                    Button(SettingsCopy.checkForUpdates) { model.checkForUpdates() }
                        .disabled(!model.canCheckForUpdates)
                        .accessibilityID(.updatesCheck)
                    if model.updateState.showsInstall {
                        Button(SettingsCopy.installUpdate) { model.installUpdate() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityID(.updatesInstall)
                    }
                }
            }
            .formStyle(.grouped)

            statusRow
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.updateState {
        case .upToDate:
            Text(UpdateCheckCopy.upToDate)
                .foregroundStyle(.green)
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(UpdateCheckCopy.checking)
                    .foregroundStyle(.secondary)
            }
        case .available(let version):
            (Text("Mise à jour disponible : ") + Text(version).fontWeight(.semibold))
                .foregroundStyle(.secondary)
        case .error:
            Text(UpdateCheckCopy.failed)
                .foregroundStyle(.red)
        }
    }

    private var snapshot: AboutVersionSnapshot {
        AboutVersionSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            hermesCLI: hermesCLIValue,
            macOS: AboutVersionSnapshot.macOSString(
                major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                minor: ProcessInfo.processInfo.operatingSystemVersion.minorVersion,
                patch: ProcessInfo.processInfo.operatingSystemVersion.patchVersion
            )
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
