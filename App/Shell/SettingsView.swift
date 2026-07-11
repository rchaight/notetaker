import SwiftUI

/// App settings; sections fill in as their milestones land (vault location,
/// AI providers, appearance, security).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Section("General") {
                        LabeledContent("Version", value: "0.1.0 (pre-alpha)")
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Vault", systemImage: "icloud") {
                VaultDebugView()
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}

#Preview {
    SettingsView()
}
