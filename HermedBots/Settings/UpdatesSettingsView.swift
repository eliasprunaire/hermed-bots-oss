import AppSettings
import SwiftUI

struct UpdatesSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Button(SettingsCopy.checkForUpdates) { model.checkForUpdates() }
                .disabled(!model.canCheckForUpdates)
                .accessibilityID(.updatesCheck)
        }
        .formStyle(.grouped)
    }
}
