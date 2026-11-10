import AppSettings
import HermesAdapter
import SwiftUI
import UpdateCheck

struct UpdatesSettingsView: View {
    let model: AppModel

    var body: some View {
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
            LabeledContent("Compatibilité Hermes") {
                Text(compatibilityDetail).accessibilityID(.aboutCompat)
            }
            VStack(alignment: .leading, spacing: 8) {
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
                statusRow
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.updateState {
        case .idle:
            EmptyView()
        case .upToDate:
            Text(UpdateCheckCopy.upToDate)
                .foregroundStyle(.secondary)
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

    private var compatibilityDetail: String {
        if model.isCheckingAPI { return CompatibilityStatus.connectingLabel }
        if case .failed(let message) = model.compatibility { return message }
        if let map = model.capabilities {
            if map.hasDisabledFeature {
                return map.entries.compactMap {
                    if case .disabled(let message) = $0.state { return message }
                    return nil
                }.joined(separator: " ")
            }
            if let notice = map.versionNotice {
                return notice + ". Toutes les fonctions répondent."
            }
            if let version = map.version {
                return "Hermes \(version) testée. Toutes les fonctions répondent."
            }
        }
        return AboutVersionSnapshot.unknownLabel
    }
}
