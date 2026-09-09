import Foundation
import Testing
@testable import AssignmentApp2

struct TimetableGeometryTests {
    private func meeting(_ id: Int64, _ start: String, _ end: String, day: Int = 1) -> CourseMeeting {
        CourseMeeting(id: id, uuid: UUID(), courseID: 1, weekday: day,
                      startTimeLocal: start, endTimeLocal: end, location: "Room",
                      teacherOverride: nil, timezoneID: "America/Los_Angeles",
                      effectiveStartDate: "2026-09-01", effectiveEndDate: nil, sortOrder: 0,
                      createdAt: .distantPast, updatedAt: .distantPast, deletedAt: nil)
    }
    @Test func positionAndHeightShareTheTickScale() throws {
        let grid = TimetableGeometry(meetings: [meeting(1, "08:30:00", "09:50:00")])
        let item = try #require(grid.placements.first)
        #expect(grid.y(item.start) == 42)
        #expect(abs(grid.height(item) - 112) < 0.00001)
        #expect(grid.y(540) == 84)
        #expect(grid.ticks.contains(510))
    }
    @Test func rangeIncludesEarlyLateAndSeconds() throws {
        let grid = TimetableGeometry(meetings: [meeting(1, "00:10:30", "00:11:30"),
                                               meeting(2, "23:00:00", "23:59:59")])
        #expect(grid.startMinute == 0)
        #expect(grid.endMinute == 1440)
        let short = try #require(grid.placements.first)
        #expect(abs(grid.height(short) - 1.4) < 0.00001)
        #expect(short.start == 10.5)
    }
    @Test func overlapsOccupyDifferentStableLanes() {
        let meetings = [meeting(3, "11:00:00", "12:00:00"), meeting(2, "09:30:00", "10:30:00"),
                        meeting(1, "09:00:00", "10:00:00")]
        let a = TimetableGeometry(meetings: meetings).placements
        let b = TimetableGeometry(meetings: meetings.reversed()).placements
        #expect(a.map(\.id) == b.map(\.id))
        #expect(a.map(\.lane) == [0, 1, 0])
        #expect(a.map(\.laneCount) == [2, 2, 1])
    }
    @Test func shortHitAreasDoNotHideAdjacentCoursesOrInflateVisualDuration() {
        let grid = TimetableGeometry(meetings: [meeting(1, "09:00:00", "09:05:00"),
                                               meeting(2, "09:05:00", "09:10:00")])
        #expect(grid.placements.map(\.lane) == [0, 1])
        #expect(grid.placements.allSatisfy { abs(grid.height($0) - 7) < 0.00001 })
    }
    @Test func deletedMeetingsAreExcludedWithoutChangingTimezoneOrDates() {
        var removed = meeting(1, "06:00:00", "07:00:00"); removed.deletedAt = Date()
        let active = meeting(2, "08:00:00", "09:00:00", day: 3)
        let grid = TimetableGeometry(meetings: [removed, active])
        #expect(grid.placements.map(\.meeting) == [active])
        #expect(grid.startMinute == 480)
    }
}
