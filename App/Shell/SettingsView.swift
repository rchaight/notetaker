import SwiftUI

/// App settings; sections fill in as their milestones land (vault location,
/// AI providers, appearance, security).
struct SettingsView: View {
    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Version", value: "0.1.0 (pre-alpha)")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 240)
    }
}

#Preview {
    SettingsView()
}
