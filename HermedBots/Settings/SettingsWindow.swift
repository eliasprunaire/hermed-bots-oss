import AppSettings
import SwiftUI

struct SettingsWindow: View {
    let model: AppModel

    var body: some View {
        TabView {
            ForEach(SettingsPane.allCases, id: \.self) { pane in
                Tab(pane.title, systemImage: pane.systemImage) {
                    switch pane {
                    case .connection: ConnectionView(model: model)
                    case .updates: UpdatesSettingsView(model: model)
                    }
                }
                .accessibilityIdentifier(pane.accessibilityID)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
