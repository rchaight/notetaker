import GRDB

/// IndexKit — derived, rebuildable task/note index over GRDB; fleshed out in M3.
public enum IndexKitInfo {
    public static let name = "IndexKit"

    /// Smoke-level proof that GRDB is linked: open an in-memory database
    /// and evaluate a trivial statement.
    public static func databaseWorks() throws -> Bool {
        let queue = try DatabaseQueue()
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1") == 1
        }
    }
}
