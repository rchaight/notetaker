import Foundation

public enum SnapshotError: Error, Equatable {
    case unsupportedSchema(found: Int)
}

public enum SnapshotCodec {
    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    public static func encode(_ snapshot: CalendarSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    /// Throws `SnapshotError.unsupportedSchema(found:)` when schemaVersion > supported.
    public static func decode(_ data: Data) throws -> CalendarSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let probe = try decoder.decode(VersionProbe.self, from: data)
        if probe.schemaVersion > CalendarSnapshot.schemaVersion {
            throw SnapshotError.unsupportedSchema(found: probe.schemaVersion)
        }
        return try decoder.decode(CalendarSnapshot.self, from: data)
    }
}
