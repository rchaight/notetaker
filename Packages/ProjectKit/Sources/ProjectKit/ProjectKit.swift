import Foundation

/// Project metadata parsed from a note's frontmatter. A note IS a project
/// when its frontmatter says `project: true`; status/start/due are optional
/// refinements. PM stays a view over notes + todos — never a second store.
public struct ProjectMetadata: Equatable, Sendable {
    public enum Status: String, CaseIterable, Sendable {
        case planned
        case active
        case onHold = "on-hold"
        case done
    }

    public let status: Status?
    /// Frontmatter's literal status string when it isn't a known case.
    public let rawStatus: String?
    /// ISO days ("yyyy-MM-dd"), matching the task grammar's date format.
    public let startDay: String?
    public let dueDay: String?

    /// nil unless the frontmatter marks the note as a project.
    public static func parse(_ values: [String: String]) -> ProjectMetadata? {
        guard values["project"] == "true" else { return nil }
        let raw = values["status"]?.trimmingCharacters(in: .whitespaces).lowercased()
        return ProjectMetadata(
            status: raw.flatMap(Status.init(rawValue:)),
            rawStatus: raw,
            startDay: validDay(values["start"]),
            dueDay: validDay(values["due"])
        )
    }

    static func validDay(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value) != nil ? value : nil
    }
}

/// Auto-percent-complete from a project's checked/total inline todos
/// (Linear-style: never hand-entered).
public enum ProjectProgress {
    public static func fraction(done: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }
}
