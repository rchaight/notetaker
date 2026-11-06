import Foundation

/// The "[ ]" / "[x]" token of a task list item.
public struct TaskCheckboxToken: Equatable, Sendable {
    public let range: NSRange
    public let checked: Bool

    public init(range: NSRange, checked: Bool) {
        self.range = range
        self.checked = checked
    }
}

/// Locating checkbox tokens — the editor renders these as interactive checkboxes.
/// There is deliberately no bare "flip the bracket" helper here: a check-off must also stamp
/// or strip the completed day (and roll recurrences), so every surface goes through
/// `RecurrenceEngine.completeTaskLine` / `TaskLineToggler`.
public enum TaskCheckboxes {
    private static let tokenRegex = try? NSRegularExpression(pattern: #"\[( |x|X)\]"#)

    /// Token ranges for every task list item in the styled ranges.
    public static func tokens(in text: String, styled: [StyledRange]) -> [TaskCheckboxToken] {
        let ns = text as NSString
        guard let regex = tokenRegex else { return [] }
        var tokens: [TaskCheckboxToken] = []

        for item in styled {
            guard case let .taskCheckbox(checked) = item.kind,
                  NSMaxRange(item.range) <= ns.length
            else { continue }
            // The token sits just after the bullet — search the item's head.
            let search = NSRange(location: item.range.location, length: min(item.range.length, 24))
            guard let match = regex.firstMatch(in: text, range: search) else { continue }
            tokens.append(TaskCheckboxToken(range: match.range, checked: checked))
        }
        return tokens
    }
}
