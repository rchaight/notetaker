import SwiftUI

@main
struct NotetakerApp: App {
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
