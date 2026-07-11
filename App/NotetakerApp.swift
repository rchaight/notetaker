import SwiftUI

@main
struct NotetakerApp: App {
    init() {
        VaultSmoke.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
        }

        #if os(macOS)
            Settings {
                SettingsView()
            }
        #endif
    }
}
