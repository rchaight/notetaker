import Foundation
@testable import ProjectKit
import Testing

struct ProjectMetadataTests {
    @Test func requiresProjectFlag() {
        #expect(ProjectMetadata.parse(["status": "active"]) == nil)
        #expect(ProjectMetadata.parse(["project": "true"]) != nil)
    }

    @Test func parsesStatusAndDates() {
        let meta = ProjectMetadata.parse([
            "project": "true", "status": "Active",
            "start": "2026-07-01", "due": "2026-09-30",
        ])
        #expect(meta?.status == .active)
        #expect(meta?.startDay == "2026-07-01")
        #expect(meta?.dueDay == "2026-09-30")
    }

    @Test func unknownStatusAndBadDatesDegrade() {
        let meta = ProjectMetadata.parse([
            "project": "true", "status": "cooking", "due": "soon",
        ])
        #expect(meta?.status == nil)
        #expect(meta?.rawStatus == "cooking")
        #expect(meta?.dueDay == nil)
    }

    @Test func progressFraction() {
        #expect(ProjectProgress.fraction(done: 3, total: 4) == 0.75)
        #expect(ProjectProgress.fraction(done: 0, total: 0) == 0)
    }
}

struct ProjectScheduleTests {
    private let chain = [
        TaskNode(id: "a", title: "design", dueDay: 2, blockId: "design"),
        TaskNode(id: "b", title: "build", blockId: "build", dependsOn: ["design"]),
        TaskNode(id: "c", title: "ship", dependsOn: ["build"]),
        TaskNode(id: "d", title: "docs", dependsOn: ["design"]),
    ]

    @Test func topologicalOrderRespectsDependencies() throws {
        let order = try #require(ProjectSchedule.topologicalOrder(chain)).map(\.id)
        #expect(try #require(order.firstIndex(of: "a")) < order.firstIndex(of: "b")!)
        #expect(try #require(order.firstIndex(of: "b")) < order.firstIndex(of: "c")!)
        #expect(try #require(order.firstIndex(of: "a")) < order.firstIndex(of: "d")!)
    }

    @Test func cycleReturnsNil() {
        let cyclic = [
            TaskNode(id: "a", title: "a", blockId: "a", dependsOn: ["b"]),
            TaskNode(id: "b", title: "b", blockId: "b", dependsOn: ["a"]),
        ]
        #expect(ProjectSchedule.topologicalOrder(cyclic) == nil)
        #expect(ProjectSchedule.schedule(cyclic) == nil)
    }

    @Test func scheduleCascadesAndFindsCriticalPath() throws {
        let scheduled = try #require(ProjectSchedule.schedule(chain))
        let byId = Dictionary(uniqueKeysWithValues: scheduled.map { ($0.id, $0) })
        #expect(byId["a"]?.start == 0 && byId["a"]!.end == 2)
        #expect(byId["b"]?.start == 3)
        #expect(byId["c"]?.start == byId["b"]!.end + 1)
        // a → b → c is the longest chain: all critical; docs has slack.
        #expect(try #require(byId["a"]?.isCritical) && byId["b"]!.isCritical && byId["c"]!.isCritical)
        #expect(try #require(byId["d"]?.slack) > 0)
    }

    @Test func explicitStartDateWinsOverDependencyFloor() throws {
        let nodes = [
            TaskNode(id: "a", title: "a", dueDay: 1, blockId: "a"),
            TaskNode(id: "b", title: "b", startDay: 10, dueDay: 12, dependsOn: ["a"]),
        ]
        let byId = try Dictionary(
            uniqueKeysWithValues: #require(ProjectSchedule.schedule(nodes)).map { ($0.id, $0) }
        )
        #expect(byId["b"]?.start == 10)
        #expect(byId["b"]?.end == 12)
    }

    @Test func danglingReferenceIgnored() throws {
        let nodes = [TaskNode(id: "a", title: "a", dependsOn: ["ghost"])]
        let scheduled = try #require(ProjectSchedule.schedule(nodes))
        #expect(scheduled[0].start == 0)
    }

    @Test func dayOffsetMath() {
        #expect(ProjectSchedule.dayOffset("2026-07-15", from: "2026-07-12") == 3)
        #expect(ProjectSchedule.dayOffset("2026-07-10", from: "2026-07-12") == -2)
        #expect(ProjectSchedule.dayOffset("garbage", from: "2026-07-12") == nil)
    }
}
