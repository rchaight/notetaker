#if os(macOS)
    import AppKit
    import Carbon.HIToolbox
    import SwiftUI

    /// System-wide ⌃⌥⌘N → floating quick-capture panel. Carbon hotkeys are
    /// the only sanctioned global-shortcut API that works without the
    /// accessibility permission prompt.
    @MainActor
    enum GlobalHotkey {
        private static var hotKeyRef: EventHotKeyRef?
        private static var panel: NSPanel?

        static func register() {
            guard hotKeyRef == nil else { return }
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in GlobalHotkey.togglePanel() }
                return noErr
            }, 1, &eventType, nil, nil)
            let hotKeyID = EventHotKeyID(signature: OSType(0x4E54_4B52), id: 1) // "NTKR"
            // ⌃⌥⌘N
            RegisterEventHotKey(
                UInt32(kVK_ANSI_N),
                UInt32(controlKey | optionKey | cmdKey),
                hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
            )
        }

        static func togglePanel() {
            if let panel, panel.isVisible {
                panel.close()
                return
            }
            let panel = panel ?? makePanel()
            self.panel = panel
            panel.center()
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }

        private static func makePanel() -> NSPanel {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                backing: .buffered, defer: false
            )
            panel.title = "Quick Add"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: MenuBarQuickAddView())
            panel.isReleasedWhenClosed = false
            return panel
        }
    }
#endif
