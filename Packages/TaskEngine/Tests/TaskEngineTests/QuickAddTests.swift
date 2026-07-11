import Foundation
@testable import TaskEngine
import Testing

struct QuickAddTests {
    @Test func explicitTokensPassThrough() {
        let result = QuickAddParser.parse("email dean >2026-07-20 !p1 #admin")
        #expect(result?.markdownLine == "- [ ] email dean #admin >2026-07-20 !p1")
        #expect(result?.metadata.dueDate == "2026-07-20")
        #expect(result?.metadata.priority == 1)
        #expect(result?.metadata.labels == ["admin"])
    }

    @Test func naturalTomorrowDetected() {
        let result = QuickAddParser.parse("call plumber tomorrow")
        #expect(result?.metadata.dueDate == SmartBuckets.isoDay(offsetFromToday: 1))
        #expect(result?.metadata.cleanText == "call plumber")
    }

    @Test func barePriorityDetected() {
        let result = QuickAddParser.parse("review grant p2")
        #expect(result?.metadata.priority == 2)
        #expect(result?.metadata.cleanText == "review grant")
        #expect(result?.markdownLine == "- [ ] review grant !p2")
    }

    @Test func recurrenceCarriedIntoLine() {
        let result = QuickAddParser.parse("water plants >2026-07-14 &every 3 days")
        #expect(result?.markdownLine == "- [ ] water plants >2026-07-14 &every 3 days")
    }

    @Test func plainTextStaysPlain() {
        let result = QuickAddParser.parse("just a thought")
        #expect(result?.markdownLine == "- [ ] just a thought")
        #expect(result?.metadata.dueDate == nil)
    }

    @Test func emptyAndWhitespaceRejected() {
        #expect(QuickAddParser.parse("") == nil)
        #expect(QuickAddParser.parse("   \n") == nil)
        #expect(QuickAddParser.parse(">tomorrow !p1") == nil, "metadata with no text is not a task")
    }
}
