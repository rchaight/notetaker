import CloudKit
import Foundation

/// Extended task data in the user's PRIVATE CloudKit database, keyed by the
/// task's durable ^id. The markdown line stays the source of truth for the
/// task itself (text, dates, priority, labels); these records only carry
/// what a one-line grammar can't — long descriptions, links — and losing
/// them never loses a task.
@MainActor
@Observable
final class TaskExtrasStore {
    struct Extras: Equatable {
        var description: String = ""
        var url: String = ""
        var updatedAt: Date?
    }

    enum State: Equatable {
        case idle
        case loading
        case ready
        case unavailable(String)
    }

    private(set) var state: State = .idle
    private let database = CKContainer(
        identifier: "iCloud.com.rchaight.notetaker"
    ).privateCloudDatabase
    private static let recordType = "TaskExtras"

    /// In-memory cache so reopening a detail window is instant.
    private var cache: [String: Extras] = [:]

    func extras(for taskKey: String) async -> Extras {
        if let cached = cache[taskKey] {
            return cached
        }
        state = .loading
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: taskKey))
            let extras = Extras(
                description: record["taskDescription"] as? String ?? "",
                url: record["url"] as? String ?? "",
                updatedAt: record.modificationDate
            )
            cache[taskKey] = extras
            state = .ready
            return extras
        } catch let error as CKError where error.code == .unknownItem {
            // No extras yet — normal for a fresh task.
            state = .ready
            return Extras()
        } catch {
            state = .unavailable(Self.friendlyMessage(error))
            return cache[taskKey] ?? Extras()
        }
    }

    @discardableResult
    func save(_ extras: Extras, for taskKey: String) async -> Bool {
        state = .loading
        do {
            let recordID = CKRecord.ID(recordName: taskKey)
            let record: CKRecord
            do {
                record = try await database.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: Self.recordType, recordID: recordID)
            }
            record["taskDescription"] = extras.description
            record["url"] = extras.url
            _ = try await database.save(record)
            var stamped = extras
            stamped.updatedAt = Date()
            cache[taskKey] = stamped
            state = .ready
            return true
        } catch {
            state = .unavailable(Self.friendlyMessage(error))
            return false
        }
    }

    func delete(taskKey: String) async {
        cache[taskKey] = nil
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: taskKey))
    }

    private static func friendlyMessage(_ error: Error) -> String {
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated: return "Sign in to iCloud to sync task details."
            case .networkUnavailable, .networkFailure: return "Offline — details will load when connected."
            default: break
            }
        }
        return "iCloud unavailable: \(error.localizedDescription)"
    }
}
