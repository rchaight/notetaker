import CloudKit
import Foundation

/// Per-tag metadata (descriptions) in the private CloudKit database.
/// Record name = "tag:<name>". Same posture as task extras: the vault
/// files never depend on these; losing them loses only descriptions.
@MainActor
@Observable
final class TagExtrasStore {
    private(set) var unavailable: String?
    private let database = CKContainer(
        identifier: "iCloud.com.rchaight.notetaker"
    ).privateCloudDatabase
    private static let recordType = "TagExtras"
    private var cache: [String: String] = [:]

    func description(for tag: String) async -> String {
        if let cached = cache[tag] {
            return cached
        }
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: "tag:" + tag))
            let text = record["tagDescription"] as? String ?? ""
            cache[tag] = text
            unavailable = nil
            return text
        } catch let error as CKError where error.code == .unknownItem {
            return ""
        } catch {
            unavailable = "iCloud unavailable — descriptions won't sync right now."
            return cache[tag] ?? ""
        }
    }

    @discardableResult
    func saveDescription(_ text: String, for tag: String) async -> Bool {
        do {
            let recordID = CKRecord.ID(recordName: "tag:" + tag)
            let record: CKRecord
            do {
                record = try await database.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: Self.recordType, recordID: recordID)
            }
            record["tagDescription"] = text
            _ = try await database.save(record)
            cache[tag] = text
            unavailable = nil
            return true
        } catch {
            unavailable = "iCloud unavailable — description not saved."
            return false
        }
    }

    /// Renames carry the description to the new tag key.
    func move(from oldTag: String, to newTag: String) async {
        let text = await description(for: oldTag)
        guard !text.isEmpty else { return }
        if await saveDescription(text, for: newTag) {
            cache[oldTag] = nil
            _ = try? await database.deleteRecord(
                withID: CKRecord.ID(recordName: "tag:" + oldTag)
            )
        }
    }
}
