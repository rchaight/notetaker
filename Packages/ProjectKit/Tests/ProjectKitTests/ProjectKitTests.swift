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
