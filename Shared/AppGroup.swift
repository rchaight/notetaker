import Foundation

/// The app-group container shared by the app and its widget extension.
///
/// Apple spells this identifier differently per platform: iOS requires a
/// `group.` prefix, macOS requires the team-ID prefix. A universal target
/// therefore cannot use one literal — the iOS entitlements file carries
/// the `group.` form, the macOS one the team-ID form, and this constant
/// must stay in lockstep with both.
enum AppGroup {
    static let identifier: String = {
        #if os(macOS)
            "6A2NHN89Q8.com.rchaight.notetaker"
        #else
            "group.com.rchaight.notetaker"
        #endif
    }()

    /// Container URL, or nil when the group isn't provisioned (ad-hoc
    /// dev builds) — callers treat that as "no widget sharing today".
    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        )
    }
}
