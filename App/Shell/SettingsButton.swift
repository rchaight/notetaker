import SwiftUI

extension View {
    /// iOS: a gear in the navigation bar that opens Settings as a sheet. macOS already has
    /// the ⌘, Settings scene (and its toolbar bridge is fragile), so there this is a no-op.
    @ViewBuilder
    func settingsButton() -> some View {
        #if os(iOS)
            modifier(SettingsButtonModifier())
        #else
            self
        #endif
    }
}

#if os(iOS)
    /// Owns its own sheet state, so each tab adds the gear without plumbing a binding
    /// through `AppShell` (every tab has its own navigation container).
    private struct SettingsButtonModifier: ViewModifier {
        @State private var showingSettings = false

        func body(content: Content) -> some View {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") {
                            showingSettings = true
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView()
                }
        }
    }
#endif
