import Foundation

/// One task as the scheduler sees it: day numbers are offsets from the
/// project's start (day 0). Derived entirely from parsed markdown.
public struct TaskNode: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let checked: Bool
    /// Explicit ISO-day-derived offsets when the line carried dates.
    public let startDay: Int?
    public let dueDay: Int?
    public let blockId: String?
    public let dependsOn: [String]

    public init(
        id: String, title: String, checked: Bool = false,
        startDay: Int? = nil, dueDay: Int? = nil,
        blockId: String? = nil, dependsOn: [String] = []
    ) {
        self.id = id
        self.title = title
        self.checked = checked
        self.startDay = startDay
        self.dueDay = dueDay
        self.blockId = blockId
        self.dependsOn = dependsOn
    }
}

/// A scheduled bar: computed start/end (inclusive), slack, critical flag.
public struct ScheduledTask: Equatable, Sendable, Identifiable {
    public let id: String
    public let node: TaskNode
    public let start: Int
    public let end: Int
    public let slack: Int
    public var isCritical: Bool { slack == 0 }
    public var duration: Int { end - start + 1 }
}

/// Critical-path-method scheduling over the dependency graph. Ungated —
/// slack and the critical path are core features, never paywalled.
public enum ProjectSchedule {
    /// Topological order by blockId-declared dependencies; nil on a cycle.
    /// Unknown references are ignored (a dangling `blockedby:` must not
    /// wedge the whole project).
    public static func topologicalOrder(_ nodes: [TaskNode]) -> [TaskNode]? {
        let byBlockId = Dictionary(
            nodes.compactMap { node in node.blockId.map { ($0, node.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        var incoming: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for node in nodes {
            incoming[node.id, default: 0] += 0
            for reference in node.dependsOn {
                guard let sourceId = byBlockId[reference] else { continue }
                incoming[node.id, default: 0] += 1
                dependents[sourceId, default: []].append(node.id)
            }
        }
        var queue = nodes.filter { incoming[$0.id] == 0 }.map(\.id)
        var order: [String] = []
        while let id = queue.first {
            queue.removeFirst()
            order.append(id)
            for dependent in dependents[id] ?? [] {
                incoming[dependent]! -= 1
                if incoming[dependent] == 0 { queue.append(dependent) }
            }
        }
        guard order.count == nodes.count else { return nil }
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return order.compactMap { byId[$0] }
    }

    /// CPM forward + backward pass. Explicit dates win over dependency
    /// pushes (a task never starts before its own start date); duration
    /// defaults to 1 day when the line has no date range.
    public static func schedule(_ nodes: [TaskNode]) -> [ScheduledTask]? {
        guard let ordered = topologicalOrder(nodes) else { return nil }
        let byBlockId = Dictionary(
            nodes.compactMap { node in node.blockId.map { ($0, node) } },
            uniquingKeysWith: { first, _ in first }
        )

        var start: [String: Int] = [:]
        var end: [String: Int] = [:]
        for node in ordered {
            let duration = max((node.dueDay ?? 0) - (node.startDay ?? node.dueDay ?? 0) + 1, 1)
            let dependencyFloor = node.dependsOn
                .compactMap { byBlockId[$0].flatMap { end[$0.id] } }
                .map { $0 + 1 }
                .max() ?? 0
            let begin = max(node.startDay ?? dependencyFloor, dependencyFloor)
            start[node.id] = begin
            end[node.id] = node.dueDay.map { max($0, begin + duration - 1) } ?? (begin + duration - 1)
        }

        let horizon = end.values.max() ?? 0
        var latestEnd: [String: Int] = [:]
        var dependents: [String: [TaskNode]] = [:]
        for node in nodes {
            for reference in node.dependsOn {
                if let source = byBlockId[reference] {
                    dependents[source.id, default: []].append(node)
                }
            }
        }
        for node in ordered.reversed() {
            let successors = dependents[node.id] ?? []
            let ceiling = successors
                .compactMap { successor in
                    latestEnd[successor.id].map { $0 - (end[successor.id]! - start[successor.id]!) - 1 }
                }
                .min() ?? horizon
            latestEnd[node.id] = min(ceiling, horizon)
        }

        return ordered.map { node in
            let begin = start[node.id]!
            let finish = end[node.id]!
            let slack = max((latestEnd[node.id] ?? finish) - finish, 0)
            return ScheduledTask(id: node.id, node: node, start: begin, end: finish, slack: slack)
        }
    }

    /// Day offset of an ISO day relative to a base ISO day (both
    /// "yyyy-MM-dd"); nil when either fails to parse.
    public static func dayOffset(_ isoDay: String, from base: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: isoDay), let start = formatter.date(from: base)
        else { return nil }
        return Int((day.timeIntervalSince(start) / 86400).rounded())
    }
}
