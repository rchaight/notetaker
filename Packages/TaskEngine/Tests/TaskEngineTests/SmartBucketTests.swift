import Foundation
@testable import TaskEngine
import Testing

struct SmartBucketTests {
    private var noon: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 11; components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func bucketsByDate() {
        #expect(SmartBuckets.bucket(dueDate: "2026-07-10", today: noon, calendar: calendar) == .overdue)
        #expect(SmartBuckets.bucket(dueDate: "2026-07-11", today: noon, calendar: calendar) == .today)
        #expect(SmartBuckets.bucket(dueDate: "2026-07-12", today: noon, calendar: calendar) == .upcoming)
        #expect(SmartBuckets.bucket(dueDate: nil, today: noon, calendar: calendar) == .inbox)
    }

    @Test func longOverdueStaysOverdue() {
        #expect(SmartBuckets.bucket(dueDate: "2025-01-01", today: noon, calendar: calendar) == .overdue)
    }

    @Test func garbageDatesLandInInbox() {
        #expect(SmartBuckets.bucket(dueDate: "not-a-date", today: noon, calendar: calendar) == .inbox)
        #expect(SmartBuckets.bucket(dueDate: "", today: noon, calendar: calendar) == .inbox)
    }

    @Test func isoDayOffsets() {
        #expect(SmartBuckets.isoDay(offsetFromToday: 0, today: noon, calendar: calendar) == "2026-07-11")
        #expect(SmartBuckets.isoDay(offsetFromToday: 3, today: noon, calendar: calendar) == "2026-07-14")
        #expect(SmartBuckets.isoDay(offsetFromToday: -1, today: noon, calendar: calendar) == "2026-07-10")
    }
}
