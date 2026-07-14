import SwiftUI

@main
struct NotetakerApp: App {
    init() {
        // Dev builds change toolbars between installs; restoring a stale
        // saved toolbar plist crashes SwiftUI's NSToolbar bridge on the
        // macOS 27 beta (NSException in _insertNewItemWithItemIdentifier).
        // Purge saved window state before any window is created. Revisit
        // for proper state restoration at release (M10).
        Self.purgeSavedWindowState()
        VaultSmoke.runIfRequested()
    }

    private static func purgeSavedWindowState() {
        #if os(macOS)
            guard let library = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
            let savedState = library
                .appendingPathComponent("Saved Application State", isDirectory: true)
                .appendingPathComponent("com.rchaight.notetaker.savedState", isDirectory: true)
            try? FileManager.default.removeItem(at: savedState)
        #endif
    }

    @AppStorage(VaultRegistry.activeKey) private var activeVault = VaultRegistry.iCloudId

    var body: some Scene {
        WindowGroup {
            // .id: switching vaults rebuilds the shell (fresh model + index
            // service rooted in the new vault).
            AppShell().id(activeVault)
        }
        .defaultSize(width: 1150, height: 720)

        #if os(macOS)
            Settings {
                SettingsView()
            }
            MenuBarExtra("Notetaker Quick Add", systemImage: "square.and.pencil") {
                MenuBarQuickAddView()
            }
            .menuBarExtraStyle(.window)
        #endif
    }
}
