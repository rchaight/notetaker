import CommonCrypto
import CryptoKit
import Foundation

/// Per-note encryption: PBKDF2-HMAC-SHA256 (600k rounds) derives the key,
/// AES-GCM seals the body. The synced file holds ONLY ciphertext + public
/// parameters — iCloud never sees plaintext. Passphrases are unrecoverable
/// by design; the UI must say so loudly.
public enum NoteCrypto {
    public static let defaultRounds = 600_000

    public enum CryptoError: Error, Equatable {
        case derivationFailed
        case wrongPassphraseOrTampered
        case malformed
    }

    public static func makeSalt() -> Data {
        Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) })
    }

    public static func deriveKey(
        passphrase: String, salt: Data, rounds: Int = defaultRounds
    ) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let password = Array(passphrase.utf8)
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphrase, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(rounds),
                    output.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        guard status == kCCSuccess else { throw CryptoError.derivationFailed }
        return SymmetricKey(data: derived)
    }

    public static func encrypt(_ plaintext: String, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw CryptoError.malformed }
        return combined
    }

    public static func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> String {
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            let plain = try AES.GCM.open(box, using: key)
            guard let text = String(data: plain, encoding: .utf8) else {
                throw CryptoError.malformed
            }
            return text
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.wrongPassphraseOrTampered
        }
    }
}

/// The on-disk shape of a locked note: plain frontmatter carrying the
/// public parameters, base64 ciphertext as the body. Still a valid .md
/// file — it syncs, previews as gibberish, and never leaks content.
public enum LockedNoteFile {
    public struct Envelope: Equatable, Sendable {
        public let salt: Data
        public let rounds: Int
        public let ciphertext: Data
    }

    /// Renders the full locked-file contents.
    public static func render(
        title: String, salt: Data, rounds: Int, ciphertext: Data
    ) -> String {
        """
        ---
        locked: true
        salt: \(salt.base64EncodedString())
        rounds: \(rounds)
        ---
        \(ciphertext.base64EncodedString())
        """ + "\n"
    }

    /// Parses a locked file; nil when the contents aren't a locked note.
    public static func parse(frontmatterValues: [String: String], body: String) -> Envelope? {
        guard frontmatterValues["locked"] == "true",
              let saltB64 = frontmatterValues["salt"],
              let salt = Data(base64Encoded: saltB64),
              let ciphertext = Data(
                  base64Encoded: body.trimmingCharacters(in: .whitespacesAndNewlines)
              )
        else { return nil }
        let rounds = frontmatterValues["rounds"].flatMap(Int.init) ?? NoteCrypto.defaultRounds
        return Envelope(salt: salt, rounds: rounds, ciphertext: ciphertext)
    }
}
