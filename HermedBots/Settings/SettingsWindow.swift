import AppSettings
import SwiftUI

struct SettingsWindow: View {
    let model: AppModel

    var body: some View {
        TabView {
            ForEach(SettingsPane.allCases, id: \.self) { pane in
                Tab {
                    switch pane {
                    case .connection: ConnectionView(model: model)
                    case .updates: UpdatesSettingsView(model: model)
                    }
                } label: {
                    Label(pane.title, systemImage: pane.systemImage)
                        .accessibilityLabel(pane.title)
                        .accessibilityIdentifier(pane.accessibilityID)
                }
            }
        }
        .frame(minWidth: SettingsLayout.defaultWidth)
    }
}
