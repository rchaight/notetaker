import Foundation
import GRDB

/// `STATE_DIR/tokens.sqlite` (spec 07): authorization codes, token families and
/// tokens. Only SHA-256 digests of codes and tokens are stored — a copy of this
/// file mints nothing. Every state transition (code redemption, refresh
/// rotation, reuse → family revocation) is one SQLite transaction, so two racing
/// requests can never both redeem one code or rotate one refresh token.
public final class TokenStore: Sendable {
    public static let schemaVersion = 1

    private let db: DatabaseQueue
    private let url: URL?

    /// Opens (creating 0600) the store at `url`. The containing directory is
    /// created 0700 if missing.
    public init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        // Create with 0600 before SQLite ever touches it, and re-assert the mode
        // on an existing file (SQLite gives the -wal/-shm files the same mode).
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        fchmod(descriptor, 0o600)
        close(descriptor)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        db = try DatabaseQueue(path: url.path, configuration: configuration)
        self.url = url
        try migrate()
        Self.tightenSidecars(of: url)
    }

    /// In-memory store (tests only).
    init() throws {
        db = try DatabaseQueue()
        url = nil
        try migrate()
    }

    private static func tightenSidecars(of url: URL) {
        for suffix in ["-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                chmod(path, 0o600)
            }
        }
    }

    private func migrate() throws {
        try db.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if version != 0, version != Self.schemaVersion {
                // Tokens are disposable: an unknown layout is dropped, and the
                // user reconnects. Nothing here is a source of truth.
                try db
                    .execute(
                        sql: "DROP TABLE IF EXISTS family; DROP TABLE IF EXISTS token; DROP TABLE IF EXISTS auth_code"
                    )
            }
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS family(
              id TEXT PRIMARY KEY NOT NULL, client_id TEXT NOT NULL, sub TEXT NOT NULL, aud TEXT NOT NULL,
              created_at REAL NOT NULL, absolute_expiry REAL NOT NULL, revoked_at REAL, revoke_reason TEXT);
            CREATE TABLE IF NOT EXISTS token(
              hash TEXT PRIMARY KEY NOT NULL, family_id TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('access','refresh')),
              issued_at REAL NOT NULL, expires_at REAL NOT NULL, superseded_at REAL, revoked_at REAL, last_used_at REAL);
            CREATE INDEX IF NOT EXISTS token_family ON token(family_id);
            CREATE TABLE IF NOT EXISTS auth_code(
              hash TEXT PRIMARY KEY NOT NULL, client_id TEXT NOT NULL, redirect_uri TEXT NOT NULL,
              code_challenge TEXT NOT NULL, resource TEXT NOT NULL, sub TEXT NOT NULL,
              expires_at REAL NOT NULL, used_at REAL, family_id TEXT);
            PRAGMA user_version = \(Self.schemaVersion);
            """)
        }
    }

    // MARK: - Records

    public struct CodeRecord: Sendable, Equatable {
        public var clientID: String
        public var redirectURI: String
        public var codeChallenge: String
        public var resource: String
        public var sub: String
    }

    /// Digests of freshly minted secrets plus their lifetimes.
    struct NewTokens: Sendable {
        var familyID: String
        var accessHash: String
        var refreshHash: String
        var accessExpiry: Date
        var refreshExpiry: Date
    }

    struct FamilyRecord: Sendable, Equatable {
        var id: String
        var clientID: String
        var sub: String
        var aud: String
        var createdAt: Date
        var absoluteExpiry: Date
        var revokedAt: Date?
    }

    // MARK: - Authorization codes

    func insertCode(hash: String, record: CodeRecord, expiresAt: Date) async throws {
        try await db.write { db in
            try db.execute(
                sql: """
                INSERT INTO auth_code(hash, client_id, redirect_uri, code_challenge, resource, sub, expires_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    hash, record.clientID, record.redirectURI, record.codeChallenge, record.resource, record.sub,
                    expiresAt.timeIntervalSince1970,
                ]
            )
        }
    }

    enum CodeOutcome: Sendable, Equatable {
        case issued(familyID: String)
        case notFound
        case expired
        /// The code was already redeemed: every family it produced is now revoked.
        case reused(familyID: String?)
        /// Redeemed (and therefore burned) but a binding check failed.
        case rejected(reason: String)
    }

    /// Redeems a code in one transaction: single use is enforced before any
    /// binding check runs, so a failed attempt also burns the code.
    func redeemCode(
        hash: String,
        now: Date,
        check: @escaping @Sendable (CodeRecord) -> String?,
        family: @escaping @Sendable (CodeRecord) -> (FamilyRecord, NewTokens)
    ) async throws -> CodeOutcome {
        try await db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM auth_code WHERE hash = ?", arguments: [hash])
            else {
                return .notFound
            }
            if row["used_at"] as Double? != nil {
                let familyID: String? = row["family_id"]
                if let familyID {
                    try Self.revokeFamily(db, id: familyID, reason: "code_reuse", now: now)
                }
                return .reused(familyID: familyID)
            }
            let expiresAt: Double = row["expires_at"]
            guard expiresAt > now.timeIntervalSince1970 else { return .expired }
            try db.execute(
                sql: "UPDATE auth_code SET used_at = ? WHERE hash = ?",
                arguments: [now.timeIntervalSince1970, hash]
            )
            let record = CodeRecord(
                clientID: row["client_id"], redirectURI: row["redirect_uri"], codeChallenge: row["code_challenge"],
                resource: row["resource"], sub: row["sub"]
            )
            if let reason = check(record) {
                return .rejected(reason: reason)
            }
            let (familyRecord, tokens) = family(record)
            try Self.insertFamily(db, familyRecord)
            try Self.insertTokens(db, tokens, now: now)
            try db.execute(
                sql: "UPDATE auth_code SET family_id = ? WHERE hash = ?",
                arguments: [familyRecord.id, hash]
            )
            return .issued(familyID: familyRecord.id)
        }
    }

    // MARK: - Refresh rotation

    enum RefreshOutcome: Sendable, Equatable {
        case rotated(familyID: String, absoluteExpiry: Date)
        case notFound
        /// A superseded refresh token was presented: the family is now revoked.
        case reused(familyID: String)
        case rejected(reason: String, familyID: String)
    }

    func rotateRefresh(
        hash: String,
        clientID: String,
        now: Date,
        mint: @escaping @Sendable (FamilyRecord) -> NewTokens
    ) async throws -> RefreshOutcome {
        try await db.write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM token WHERE hash = ? AND kind = 'refresh'", arguments: [hash]
            ) else { return .notFound }
            let familyID: String = row["family_id"]
            if row["superseded_at"] as Double? != nil {
                try Self.revokeFamily(db, id: familyID, reason: "refresh_reuse", now: now)
                return .reused(familyID: familyID)
            }
            guard let family = try Self.family(db, id: familyID) else {
                return .rejected(reason: "family_missing", familyID: familyID)
            }
            let moment = now.timeIntervalSince1970
            if family.revokedAt != nil || row["revoked_at"] as Double? != nil {
                return .rejected(reason: "revoked", familyID: familyID)
            }
            if moment >= family.absoluteExpiry.timeIntervalSince1970 {
                return .rejected(reason: "absolute_expired", familyID: familyID)
            }
            let expiresAt: Double = row["expires_at"]
            if moment >= expiresAt {
                return .rejected(reason: "idle_expired", familyID: familyID)
            }
            if family.clientID != clientID {
                return .rejected(reason: "client_mismatch", familyID: familyID)
            }
            try db.execute(sql: "UPDATE token SET superseded_at = ? WHERE hash = ?", arguments: [moment, hash])
            try Self.insertTokens(db, mint(family), now: now)
            return .rotated(familyID: familyID, absoluteExpiry: family.absoluteExpiry)
        }
    }

    // MARK: - Bearer validation

    struct AccessGrant: Sendable, Equatable {
        var familyID: String
        var clientID: String
        var sub: String
    }

    /// Valid only if the token exists, is an access token, is neither revoked nor
    /// expired, its family is live, and its audience and client match.
    func validateAccess(hash: String, audience: String, clientID: String, now: Date) async throws -> AccessGrant? {
        try await db.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT t.revoked_at AS t_revoked, t.expires_at AS t_expires, f.id AS f_id, f.client_id AS f_client,
                       f.sub AS f_sub, f.aud AS f_aud, f.revoked_at AS f_revoked, f.absolute_expiry AS f_absolute
                FROM token t JOIN family f ON f.id = t.family_id
                WHERE t.hash = ? AND t.kind = 'access'
                """,
                arguments: [hash]
            ) else { return nil }
            let moment = now.timeIntervalSince1970
            guard row["t_revoked"] as Double? == nil, row["f_revoked"] as Double? == nil,
                  (row["t_expires"] as Double) > moment, (row["f_absolute"] as Double) > moment,
                  row["f_aud"] as String == audience, row["f_client"] as String == clientID
            else { return nil }
            try db.execute(sql: "UPDATE token SET last_used_at = ? WHERE hash = ?", arguments: [moment, hash])
            return AccessGrant(familyID: row["f_id"], clientID: row["f_client"], sub: row["f_sub"])
        }
    }

    // MARK: - Revocation (RFC 7009)

    enum RevokeOutcome: Sendable, Equatable {
        case family(String)
        case access(familyID: String)
        case unknown
    }

    /// A refresh token kills its whole family; an access token only itself.
    func revoke(hash: String, now: Date) async throws -> RevokeOutcome {
        try await db.write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT family_id, kind FROM token WHERE hash = ?", arguments: [hash]
            ) else { return .unknown }
            let familyID: String = row["family_id"]
            if row["kind"] as String == "refresh" {
                try Self.revokeFamily(db, id: familyID, reason: "revoked", now: now)
                return .family(familyID)
            }
            try db.execute(
                sql: "UPDATE token SET revoked_at = COALESCE(revoked_at, ?) WHERE hash = ?",
                arguments: [now.timeIntervalSince1970, hash]
            )
            return .access(familyID: familyID)
        }
    }

    // MARK: - Housekeeping

    /// Deletes rows whose lifetime ended more than 24 h ago. Returns rows removed.
    @discardableResult
    public func housekeep(now: Date) async throws -> Int {
        let cutoff = now.timeIntervalSince1970 - 86400
        return try await db.write { db in
            try db.execute(sql: "DELETE FROM auth_code WHERE expires_at < ?", arguments: [cutoff])
            var removed = db.changesCount
            try db.execute(sql: "DELETE FROM token WHERE expires_at < ?", arguments: [cutoff])
            removed += db.changesCount
            try db.execute(sql: "DELETE FROM family WHERE absolute_expiry < ?", arguments: [cutoff])
            removed += db.changesCount
            try db.execute(sql: "DELETE FROM token WHERE family_id NOT IN (SELECT id FROM family)")
            removed += db.changesCount
            return removed
        }
    }

    // MARK: - Internals (also used by tests to plant rows)

    static func insertFamily(_ db: Database, _ family: FamilyRecord) throws {
        try db.execute(
            sql: """
            INSERT INTO family(id, client_id, sub, aud, created_at, absolute_expiry, revoked_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                family.id, family.clientID, family.sub, family.aud, family.createdAt.timeIntervalSince1970,
                family.absoluteExpiry.timeIntervalSince1970, family.revokedAt?.timeIntervalSince1970,
            ]
        )
    }

    static func insertTokens(_ db: Database, _ tokens: NewTokens, now: Date) throws {
        for (hash, kind, expiry) in [
            (tokens.accessHash, "access", tokens.accessExpiry), (tokens.refreshHash, "refresh", tokens.refreshExpiry),
        ] {
            try db.execute(
                sql: "INSERT INTO token(hash, family_id, kind, issued_at, expires_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [hash, tokens.familyID, kind, now.timeIntervalSince1970, expiry.timeIntervalSince1970]
            )
        }
    }

    static func revokeFamily(_ db: Database, id: String, reason: String, now: Date) throws {
        let moment = now.timeIntervalSince1970
        try db.execute(
            sql: "UPDATE family SET revoked_at = COALESCE(revoked_at, ?), revoke_reason = COALESCE(revoke_reason, ?) WHERE id = ?",
            arguments: [moment, reason, id]
        )
        try db.execute(
            sql: "UPDATE token SET revoked_at = COALESCE(revoked_at, ?) WHERE family_id = ?",
            arguments: [moment, id]
        )
    }

    static func family(_ db: Database, id: String) throws -> FamilyRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM family WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return FamilyRecord(
            id: row["id"], clientID: row["client_id"], sub: row["sub"], aud: row["aud"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            absoluteExpiry: Date(timeIntervalSince1970: row["absolute_expiry"]),
            revokedAt: (row["revoked_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }

    /// Test seam: run arbitrary SQL against the store.
    func withDatabase<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await db.write(body)
    }
}
