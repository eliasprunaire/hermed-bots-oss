import HermesAdapter
import SwiftUI

/// Le mode dégradé : chaque fonction que la version de Hermes ne sert plus, avec son message ; le reste marche
struct DegradedBanner: View {
    let map: CapabilityMap?

    var body: some View {
        if let map, map.showsBanner {
            NoticeCard(tint: .orange, symbol: "bandage.fill") {
                Text("Mode dégradé").fontWeight(.semibold).accessibilityID(.bannerDegraded)
                if let notice = map.versionNotice {
                    Text(verbatim: notice + ". Les fonctions disponibles restent utilisables.")
                        .accessibilityID(.bannerVersionNotice)
                }
                ForEach(map.entries, id: \.contract) { entry in
                    if case .disabled(let message) = entry.state {
                        Text(message).accessibilityIdentifier(AccessibilityID.degradedFeature(entry.contract.rawValue))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }
}
