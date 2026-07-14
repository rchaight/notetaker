import Foundation
#if canImport(LocalAuthentication)
    import LocalAuthentication
#endif

/// Grace-period policy for app lock — pure logic, fully testable.
public enum AppLockPolicy {
    /// Whether the app must demand authentication now.
    /// - lastUnlocked: nil = never unlocked this launch (always locks).
    /// - backgroundedAt: when the app last left the foreground; staying
    ///   inside the grace window skips re-auth on quick app switches.
    public static func shouldLock(
        enabled: Bool,
        lastUnlocked: Date?,
        backgroundedAt: Date?,
        gracePeriod: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard enabled else { return false }
        guard lastUnlocked != nil else { return true }
        guard let backgroundedAt else { return false } // still in foreground
        return now.timeIntervalSince(backgroundedAt) > gracePeriod
    }
}

/// Thin LocalAuthentication wrapper: biometrics with system passcode
/// fallback (.deviceOwnerAuthentication handles Touch ID / Face ID /
/// Watch / password in one policy).
public enum BiometricUnlock {
    public static func isAvailable() -> Bool {
        #if canImport(LocalAuthentication)
            var error: NSError?
            return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        #else
            return false
        #endif
    }

    public static func authenticate(reason: String) async -> Bool {
        #if canImport(LocalAuthentication)
            let context = LAContext()
            return await withCheckedContinuation { continuation in
                context.evaluatePolicy(
                    .deviceOwnerAuthentication, localizedReason: reason
                ) { success, _ in
                    continuation.resume(returning: success)
                }
            }
        #else
            return false
        #endif
    }
}
