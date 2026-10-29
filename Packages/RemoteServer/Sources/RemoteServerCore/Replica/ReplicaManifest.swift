import Foundation
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// The wire shape of `manifest.json`. DUPLICATED from `VaultKit.ReplicaManifest`
/// on purpose (VaultKit is Darwin-only); `ManifestParityTests` pins the key set
/// against a JSON string copied from the exporter's output. Never add a required
/// key here that the exporter does not write.
public struct ReplicaManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let bytes: Int

        public init(path: String, sha256: String, bytes: Int) {
            self.path = path
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let policyVersion: Int
    public let disabled: Bool
    public let noteCount: Int
    public let lockedExcludedCount: Int
    public let indexExcludedCount: Int
    public let otherExcludedCount: Int
    public let notDownloadedCount: Int
    public let calendarIncluded: Bool
    public let files: [Entry]
    public let filesDigest: String
    public let appVersion: String?

    public init(
        schemaVersion: Int = ReplicaManifest.supportedSchemaVersion,
        generatedAt: Date,
        policyVersion: Int = 1,
        disabled: Bool = false,
        noteCount: Int? = nil,
        lockedExcludedCount: Int = 0,
        indexExcludedCount: Int = 0,
        otherExcludedCount: Int = 0,
        notDownloadedCount: Int = 0,
        calendarIncluded: Bool = false,
        files: [Entry],
        filesDigest: String? = nil,
        appVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.policyVersion = policyVersion
        self.disabled = disabled
        self.noteCount = noteCount ?? files.count
        self.lockedExcludedCount = lockedExcludedCount
        self.indexExcludedCount = indexExcludedCount
        self.otherExcludedCount = otherExcludedCount
        self.notDownloadedCount = notDownloadedCount
        self.calendarIncluded = calendarIncluded
        self.files = files
        self.filesDigest = filesDigest ?? Self.digest(of: files)
        self.appVersion = appVersion
    }

    /// sha256 over `"\(path)\n\(sha256)\n"` concatenated in listed order.
    public static func digest(of files: [Entry]) -> String {
        var data = Data()
        for entry in files {
            data.append(Data("\(entry.path)\n\(entry.sha256)\n".utf8))
        }
        return Hashing.sha256Hex(data)
    }

    // MARK: - Coding

    /// ISO 8601 as the exporter writes it (`.iso8601`), tolerating fractional seconds.
    public static func decode(_ data: Data) throws -> ReplicaManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = DateParsing.iso8601(text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad ISO 8601 date")
        }
        return try decoder.decode(ReplicaManifest.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

enum DateParsing {
    static func iso8601(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

enum Hashing {
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
