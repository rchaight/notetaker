import CryptoKit

/// In-memory keys of the locked notes unlocked this session, keyed by note id. A note's id is
/// its vault-relative PATH, so every operation that changes a path (Move To, rename) must call
/// `rekey` — otherwise an unlocked note stops matching its key, and the next save of its text
/// takes the plain-note branch and writes the plaintext to disk.
///
/// Nothing here is persisted: quitting relocks everything.
public struct UnlockedKeyring {
    private var keys: [String: SymmetricKey] = [:]

    public init() {}

    public subscript(id: String) -> SymmetricKey? {
        get { keys[id] }
        set { keys[id] = newValue }
    }

    /// Moves the key (if there is one) from `oldID` to `newID`. Any key already sitting at
    /// `newID` is dropped either way: it belonged to whatever note used to live at that path,
    /// and a stale key on a plain note would make its saves silently do nothing.
    public mutating func rekey(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        keys[newID] = keys.removeValue(forKey: oldID)
    }

    public func contains(_ id: String) -> Bool {
        keys[id] != nil
    }
}
