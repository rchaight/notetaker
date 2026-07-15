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

struct NoteCryptoTests {
    /// Low rounds in tests: correctness, not KDF stretching, is under test.
    private let rounds = 1000

    @Test func roundTripEncryptDecrypt() throws {
        let salt = NoteCrypto.makeSalt()
        let key = try NoteCrypto.deriveKey(passphrase: "correct horse", salt: salt, rounds: rounds)
        let sealed = try NoteCrypto.encrypt("# Secret\nplans within\n", key: key)
        #expect(try NoteCrypto.decrypt(sealed, key: key) == "# Secret\nplans within\n")
    }

    @Test func wrongPassphraseFailsClosed() throws {
        let salt = NoteCrypto.makeSalt()
        let key = try NoteCrypto.deriveKey(passphrase: "right", salt: salt, rounds: rounds)
        let wrong = try NoteCrypto.deriveKey(passphrase: "wrong", salt: salt, rounds: rounds)
        let sealed = try NoteCrypto.encrypt("secret", key: key)
        #expect(throws: NoteCrypto.CryptoError.wrongPassphraseOrTampered) {
            _ = try NoteCrypto.decrypt(sealed, key: wrong)
        }
    }

    @Test func tamperedCiphertextFailsClosed() throws {
        let salt = NoteCrypto.makeSalt()
        let key = try NoteCrypto.deriveKey(passphrase: "pw", salt: salt, rounds: rounds)
        var sealed = try NoteCrypto.encrypt("secret", key: key)
        sealed[sealed.count - 1] ^= 0xFF
        #expect(throws: NoteCrypto.CryptoError.wrongPassphraseOrTampered) {
            _ = try NoteCrypto.decrypt(sealed, key: key)
        }
    }

    @Test func fileFormatRoundTrips() throws {
        let salt = NoteCrypto.makeSalt()
        let key = try NoteCrypto.deriveKey(passphrase: "pw", salt: salt, rounds: rounds)
        let sealed = try NoteCrypto.encrypt("body", key: key)
        let rendered = LockedNoteFile.render(
            title: "T", salt: salt, rounds: rounds, ciphertext: sealed
        )
        #expect(!rendered.contains("body"), "plaintext must never appear in the file")
        // Reparse through the same shallow frontmatter shape the app uses.
        var values: [String: String] = [:]
        for line in rendered.split(separator: "\n").dropFirst() {
            if line == "---" {
                break
            }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                values[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let body = rendered.components(separatedBy: "---\n").last ?? ""
        let envelope = try #require(LockedNoteFile.parse(frontmatterValues: values, body: body))
        #expect(envelope.salt == salt)
        #expect(envelope.rounds == rounds)
        #expect(try NoteCrypto.decrypt(envelope.ciphertext, key: key) == "body")
    }
}
