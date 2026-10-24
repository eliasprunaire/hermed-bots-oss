import SwiftUI

struct StopAllButton: View {
    let model: KillSwitch
    var inApproval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(role: .destructive) { Task { await model.stopAll() } } label: {
                Label("Tout arrêter", systemImage: "stop.circle.fill")
            }
            .accessibilityID(inApproval ? .approvalStopAll : .stopAll)
            .disabled(model.isDisabled)
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityID(inApproval ? .approvalStopStatus : .stopAllStatus)
            }
        }
    }
}
