import HermesAdapter
import SwiftUI

struct DegradedBanner: View {
    let map: CapabilityMap?

    var body: some View {
        if let map, map.isDegraded {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mode dégradé").fontWeight(.semibold).accessibilityID(.bannerDegraded)
                if !map.isVersionKnown {
                    Text("Version de Hermes inconnue. Les fonctions disponibles restent utilisables.")
                }
                ForEach(map.entries, id: \.contract) { entry in
                    if case .disabled(let message) = entry.state {
                        Text(message).accessibilityIdentifier(AccessibilityID.degradedFeature(entry.contract.rawValue))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.12))
        }
    }
}
