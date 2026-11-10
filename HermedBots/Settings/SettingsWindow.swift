import AppSettings
import SwiftUI

struct SettingsWindow: View {
    let model: AppModel
    @State private var pane: SettingsPane = .connection

    var body: some View {
        // macOS 27: SwiftUI.Tab does not forward accessibilityIdentifier to the
        // native settings tab button (AXUniqueId stays nil), and selection-bound
        // proxy controls behind TabView do not reliably switch the visible pane
        // under XCTest. Use an explicit pane strip so hd.settings.* stay
        // findable and clickable while still listing one control per SettingsPane.
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    ForEach(SettingsPane.allCases, id: \.self) { item in
                        Button {
                            pane = item
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(pane == item ? Color.accentColor.opacity(0.18) : Color.clear)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                        .accessibilityIdentifier(item.accessibilityID)
                        .accessibilityAddTraits(pane == item ? [.isSelected] : [])
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch pane {
                case .connection:
                    ConnectionView(model: model)
                case .updates:
                    UpdatesSettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: SettingsLayout.defaultWidth)
        .preferredColorScheme(model.testDarkAppearance ? .dark : nil)
    }
}
