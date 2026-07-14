import Foundation
@testable import SecurityKit
import Testing

struct AppLockPolicyTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func disabledNeverLocks() {
        #expect(!AppLockPolicy.shouldLock(
            enabled: false, lastUnlocked: nil, backgroundedAt: nil, gracePeriod: 0
        ))
    }

    @Test func freshLaunchAlwaysLocks() {
        #expect(AppLockPolicy.shouldLock(
            enabled: true, lastUnlocked: nil, backgroundedAt: nil, gracePeriod: 300
        ))
    }

    @Test func foregroundStaysUnlocked() {
        #expect(!AppLockPolicy.shouldLock(
            enabled: true, lastUnlocked: base, backgroundedAt: nil, gracePeriod: 0
        ))
    }

    @Test func gracePeriodBoundaries() {
        let backgrounded = base
        #expect(!AppLockPolicy.shouldLock(
            enabled: true, lastUnlocked: base, backgroundedAt: backgrounded,
            gracePeriod: 300, now: base.addingTimeInterval(299)
        ))
        #expect(AppLockPolicy.shouldLock(
            enabled: true, lastUnlocked: base, backgroundedAt: backgrounded,
            gracePeriod: 300, now: base.addingTimeInterval(301)
        ))
        // Immediate lock (grace 0): any backgrounding locks.
        #expect(AppLockPolicy.shouldLock(
            enabled: true, lastUnlocked: base, backgroundedAt: backgrounded,
            gracePeriod: 0, now: base.addingTimeInterval(1)
        ))
    }
}
