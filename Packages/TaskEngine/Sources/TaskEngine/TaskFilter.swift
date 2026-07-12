import Foundation

/// A parsed task filter — whitespace-separated terms, ANDed:
/// `p1`/`priority:p2` · `due:today|overdue|week|none` · `#label` ·
/// `note:<substring>` · bare words match task text (case-insensitive).
public struct TaskFilter: Equatable, Sendable {
    public enum DueTerm: String, Sendable {
        case today, overdue, week, none
    }

    public enum Predicate: Equatable, Sendable {
        case priority(Int)
        case due(DueTerm)
        case label(String)
        case note(String)
        case textContains(String)
    }

    public let predicates: [Predicate]

    public var isEmpty: Bool {
        predicates.isEmpty
    }

    public init(predicates: [Predicate]) {
        self.predicates = predicates
    }

    public static func parse(_ query: String) -> TaskFilter {
        var predicates: [Predicate] = []
        for rawTerm in query.split(whereSeparator: \.isWhitespace) {
            let term = String(rawTerm)
            let lower = term.lowercased()

            if lower == "and" {
                continue
            }
            if let match = lower.wholeMatch(of: /p([1-4])/) ?? lower.wholeMatch(of: /priority:p?([1-4])/) {
                predicates.append(.priority(Int(match.1)!))
            } else if lower.hasPrefix("due:"), let due = DueTerm(rawValue: String(lower.dropFirst(4))) {
                predicates.append(.due(due))
            } else if term.hasPrefix("#"), term.count > 1 {
                predicates.append(.label(String(term.dropFirst()).lowercased()))
            } else if lower.hasPrefix("note:"), term.count > 5 {
                predicates.append(.note(String(term.dropFirst(5)).lowercased()))
            } else {
                predicates.append(.textContains(lower))
            }
        }
        return TaskFilter(predicates: predicates)
    }

    /// Evaluates against plain task fields (keeps this module storage-free).
    public func matches(
        text: String,
        noteId: String,
        dueDate: String?,
        priority: Int?,
        labels: [String],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        for predicate in predicates {
            switch predicate {
            case let .priority(wanted):
                if priority != wanted {
                    return false
                }
            case let .due(term):
                let bucket = SmartBuckets.bucket(dueDate: dueDate, today: today, calendar: calendar)
                switch term {
                case .today:
                    if bucket != .today {
                        return false
                    }
                case .overdue:
                    if bucket != .overdue {
                        return false
                    }
                case .none:
                    if dueDate != nil {
                        return false
                    }
                case .week:
                    guard let dueDate,
                          dueDate <= SmartBuckets.isoDay(offsetFromToday: 7, today: today, calendar: calendar),
                          bucket != .inbox
                    else { return false }
                }
            case let .label(wanted):
                if !labels.contains(where: { $0.lowercased() == wanted }) {
                    return false
                }
            case let .note(fragment):
                if !noteId.lowercased().contains(fragment) {
                    return false
                }
            case let .textContains(fragment):
                if !text.lowercased().contains(fragment) {
                    return false
                }
            }
        }
        return true
    }
}
